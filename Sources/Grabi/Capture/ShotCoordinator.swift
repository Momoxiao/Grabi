import AppKit
import ScreenCaptureKit
import CoreGraphics

/// 截图流水线：选择 → 抓图 → 就地预览（识别 / 复制 / 保存 / 丢弃）。
///
/// **落盘时机**：默认既不落盘也不进剪贴板。用户在预览面板上按「保存」才写文件，
/// 按「复制图片 / 复制文字」才进剪贴板；复制成功保留面板，保存成功关闭面板。
///
/// 注意 OCR 不再是独立快捷键：截图完成后由就地预览面板上的「识别文字」进入，
/// 这样用户先看到截了什么，再决定要不要识别。
final class ShotCoordinator {

    static let shared = ShotCoordinator()

    private let settings = SettingsStore.shared
    private let engine = CaptureEngine()
    private let overlay = ShotOverlayController()
    /// 截图后的就地预览面板（位置与选区重合，含工具栏与原位文字层）。
    private let inlinePreview = InlinePreviewController()

    private var isBusy = false
    /// 失败对话框里的「再试一次」不能在 `presentError` 的模态循环里直接调
    /// `handleCapture()`：那一刻 `isBusy` 还是 true（外层 Task 要等这里返回才放），
    /// 重试会被入口闸门当成重复触发静默吞掉。先记下，等流水线收尾再拉起。
    private var retryAfterBusy = false

    /// 就地预览正在展示的那一张。`url` 是**已经落盘**的那份：新的默认流程里
    /// 它从 nil 开始，直到用户在面板上按「保存」（见 `saveOnKeep`）。
    /// `tag` 决定文件名模板里那一段（窗口 / 整屏 / 区域），落盘时才用得上。
    /// `source` 是截图那一刻的整屏原图：预览里拖边框改选区时从它裁，
    /// 不再回头抓一次屏。
    private struct PendingPreviewShot {
        var url: URL?
        var image: CGImage
        var source: ScreenCapture?
        var screen: NSScreen?
        var tag: String
    }

    private var pendingPreviewShot: PendingPreviewShot?

    /// 「保存」时顺带写出的 .txt 结果，交给关面板那一句角标说。
    private var keepNote: String?

    /// 需要在界面上闪一下状态栏图标。
    var onFlashStatusItem: (() -> Void)?
    /// 缺屏幕录制权限（不弹窗，交给菜单栏提示）。
    var onPermissionMissing: (() -> Void)?
    /// 失败对话框里「换个保存位置」走这里 —— 由 AppController 开设置窗口。
    var onOpenSettings: (() -> Void)?

    private init() {
        // 工具栏上不再放「调整范围」，所以这里没有 onAdjust。
        inlinePreview.onSave = { [weak self] image, sourceRect, ocrText in
            self?.saveOnKeep(image: image, sourceRect: sourceRect, ocrText: ocrText)
        }
        // 「丢弃」只在**已经保存过**时才走到这里：那张文件真的存在，得挪进废纸篓。
        // 顺手把 `pendingPreviewShot.url` 也清掉 —— 不清的话面板关闭时角标会照着
        // 那个路径说「已保存」，而文件刚被自己挪走。
        inlinePreview.onDiscard = { [weak self] url in
            do {
                try ImageWriter.discard(url)
                SettingsStore.shared.forgetShot(url.path)
                self?.pendingPreviewShot?.url = nil
                return true
            } catch {
                // 移不进去就别让界面演「已丢弃」。返回 false，面板留在原地，
                // 这里把原因和"文件还在哪儿"说清楚，并把「在访达中显示」做成默认按钮。
                Log.capture.error("丢弃失败: \(error.localizedDescription, privacy: .public)")
                self?.presentDiscardFailure(url: url, reason: error.localizedDescription)
                return false
            }
        }
        inlinePreview.onClosed = { [weak self] reason in
            guard let self else { return }
            let shot = self.pendingPreviewShot
            let note = self.keepNote
            self.pendingPreviewShot = nil
            self.keepNote = nil
            // 只有「保存成功」才该弹文件角标。复制、点外部、换下一张都不是保存。
            guard Self.showsSavedToast(for: reason) else { return }
            guard let shot, let url = shot.url else { return }
            self.presentToast(for: url, image: shot.image, screen: shot.screen,
                              prefix: "已保存", note: note)
        }
    }

    /// 面板关闭的原因里，**只有「保存成功」**该弹那条带文件名的角标。
    ///
    /// 单独摊成一个纯函数（而不是把判断埋在那个闭包里）：这条规则以前用一条
    /// `suppressFileToast` 布尔表达，结果"复制完点一下别处"和"保存成功"两条
    /// 路撞在一起 —— 用户复制后随便点一下，屏幕上却冒出「已保存」，而那张图
    /// 可能压根没落盘。现在原因是有名字的几种，这条函数是它们到"要不要报"
    /// 的唯一映射，自检直接读它。
    static func showsSavedToast(for reason: InlinePreviewController.DismissReason) -> Bool {
        if case .saved = reason { return true }
        return false
    }

    var isOverlayActive: Bool { overlay.isActive }

    /// 截图完成后是否立刻落盘。现在恒为 false：所有截图先进入就地预览，
    /// 只有用户在面板上按「保存」才写文件。保留这个查询是给自检守旧分支不要复活。
    static func savesImmediately() -> Bool { false }

    /// 截图完成到预览面板出现之间留给菜单栏反馈的时间。
    ///
    /// 预览面板一出现就会吸走全部注意力；先让菜单栏完成态呼吸一下，用户才能把
    /// “拍到了”和“接下来可以处理这张图”分成两件事看见。这个值必须短于
    /// `StatusBarController.flashDuration`，否则图标已经复位、预览才出现。
    static let previewDelayAfterFeedback: TimeInterval = 0.30

    // MARK: - 入口

    func handleCapture() {
        guard !isBusy, !overlay.isActive else {
            Log.capture.debug("已有截图流程在进行，忽略本次触发")
            return
        }

        // 刻意不弹权限对话框：截一次图弹一次窗是最劝退的设计。
        guard Permissions.hasScreenRecording else {
            Log.capture.notice("缺少屏幕录制权限，已提示但不打断用户")
            onPermissionMissing?()
            return
        }

        inlinePreview.dismissIfVisible()
        pendingPreviewShot = nil
        // 上一张的角标还挂着的话会压在新一轮的遮罩上面（角标层级更高），
        // 开始新截图时先收掉。
        ToastHUDController.shared.hide()
        isBusy = true

        overlay.begin { [weak self] outcome in
            guard let self else { return }
            // isBusy 一直握到整条流水线（延迟 + 抓图 + 落盘）跑完再放，
            // 否则这段窗口里再按一次热键会启动第二条流程，把上一张还没决定
            // 保存 / 丢弃的预览直接顶掉。
            Task {
                await self.process(outcome)
                self.isBusy = false
                if self.retryAfterBusy {
                    self.retryAfterBusy = false
                    self.handleCapture()
                }
            }
        }
    }

    /// 取消当前覆盖层（如果还开着）。
    func cancelAll() {
        if overlay.isActive { overlay.cancel() }
        inlinePreview.dismissIfVisible()
    }

    // MARK: - 处理

    private func process(_ outcome: SelectionOutcome) async {
        guard case .cancelled = outcome else {
            // 覆盖层要留到抓图结束；先把它的窗口号取出来，抓图时排除掉，
            // 这样屏幕上一直有压暗，不会先亮出实时桌面。
            let exclusions = await MainActor.run { self.overlay.windowIDs }
            await capture(outcome, excluding: exclusions)
            return
        }
        Log.capture.debug("用户取消了截图")
    }

    /// 和矩形重叠面积最大的那块屏；窗口跨屏或正好卡在两屏之间时，
    /// 按"看得见的那部分最多"算，而不是按中心点猜。找不到就退回主屏。
    private static func screen(covering rect: CGRect) -> NSScreen? {
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area { best = (screen, area) }
        }
        return best?.screen ?? NSScreen.main
    }

    private func capture(_ outcome: SelectionOutcome, excluding: [CGWindowID]) async {
        do {
            let image: CGImage
            /// 截图那一刻的整屏原图。区域 / 窗口截图都从它裁出来；
            /// 预览里拖边框改选区时也只动它，不再抓屏。
            let source: ScreenCapture?
            let tag: String
            let selectionRect: CGRect

            switch outcome {
            case .window(_, let frame):
                tag = "window"
                // 窗口图也从整屏原图里裁，而不是另抓一张窗口图：
                // 预览里拖边框改大小时用的就是这张原图，初始图和它必须是同一帧，
                // 否则一拖手柄就会换成另一张（桌面、遮挡窗口都变了）。
                guard let screen = Self.screen(covering: frame) else {
                    throw CaptureError.noDisplay
                }
                let visible = frame.intersection(screen.frame)
                guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
                    throw CaptureError.emptySelection
                }
                let full = try await engine.captureDisplay(containing: screen,
                                                           excludingWindowIDs: excluding)
                let capture = ScreenCapture(image: full, screen: screen)
                guard let cropped = capture.crop(to: visible) else {
                    throw CaptureError.cropFailed
                }
                image = cropped
                source = capture
                selectionRect = visible
            case .display(let target):
                image = try await engine.captureDisplay(containing: target,
                                                        excludingWindowIDs: excluding)
                source = ScreenCapture(image: image, screen: target)
                tag = "display"
                selectionRect = target.frame
            case .region(let rect, let target):
                let capture = try await engine.captureRegion(rect, on: target,
                                                             excludingWindowIDs: excluding)
                image = capture.image
                source = capture.source
                tag = "region"
                selectionRect = rect
            case .cancelled:
                return
            }

            // 1) 刻意**不**自动进剪贴板：进剪贴板是用户在预览面板上按「复制」那一刻
            //    的事，不再由截图本身顺带做掉。以前这里无条件复制，于是"截完还在
            //    犹豫要不要留"的那几秒里，用户复制到一半的东西已经被这张图顶掉了。

            // 3) 先给完成反馈，再让就地预览进场。两件事分帧发生，菜单栏图标
            //    不会在预览出现的那一瞬间被吞掉。
            await MainActor.run {
                self.feedback()
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.previewDelayAfterFeedback * 1_000_000_000))
            await MainActor.run {
                let screen = Self.screen(covering: selectionRect)
                    ?? InlinePreviewController.screenUnderMouse()
                self.pendingPreviewShot = PendingPreviewShot(url: nil, image: image,
                                                             source: source,
                                                             screen: screen, tag: tag)
                // 预览和压暗先铺在覆盖层下面，再把覆盖层撤掉：两个状态在同一次
                // runloop 提交，中间不会露出实时桌面。
                self.inlinePreview.show(image: image,
                                        selectionRect: selectionRect,
                                        screen: screen,
                                        source: source)
                self.overlay.dismiss()
                self.inlinePreview.focus()
            }
        } catch let error as CaptureError {
            await MainActor.run { self.overlay.dismiss() }
            if case .emptySelection = error { return }   // 用户主动放弃，不打扰
            await MainActor.run { self.presentError(error) }
        } catch {
            await MainActor.run { self.overlay.dismiss() }
            await MainActor.run { self.presentError(error) }
        }
    }

    // MARK: - 反馈

    private func feedback() {
        if settings.playSound {
            NSSound(named: "Pop")?.play()
        }
        onFlashStatusItem?()
    }

    /// 「保存」：这张图**到这里才变成文件**。
    ///
    /// 返回 nil = 没写成。面板会因此留在原地（见 `InlinePreviewController.keep`），
    /// 图还在面板上（用户按过「复制图片」的话剪贴板里也还有）——
    /// 用户既没丢东西，也当场知道了为什么没存上。
    /// 文件名那一段模板要用回抓图时那个 `tag`（窗口 / 整屏 / 区域），
    /// 所以 tag 跟着 `pendingPreviewShot` 一起存着，而不是在这儿猜。
    private func saveOnKeep(image: CGImage, sourceRect: CGRect, ocrText: String?) -> URL? {
        let tag = pendingPreviewShot?.tag ?? "region"
        // 倍率必须取**抓图那一刻**那块屏的，而不是预览当前所在位置：
        // 用户把预览拖到另一块缩放比不同的屏再按保存时，`sourceRect` 已经是新屏的
        // 坐标，按它推断会把 1x 屏截的图写成 144dpi（插进文档凭空大一倍）。
        let captureScale = pendingPreviewShot?.source?.scale
            ?? pendingPreviewShot?.screen?.backingScaleFactor
        do {
            let url = try ImageWriter.write(image, type: tag, sourceRect: sourceRect,
                                            scale: captureScale)
            settings.rememberShot(url.path)
            // 面板可能在保存前拖过手柄；同步最终图，关闭时角标才不会拿旧缩略图。
            // `source` 保持原样：整屏原图不随裁剪结果变。
            if var shot = pendingPreviewShot {
                shot.url = url
                shot.image = image
                pendingPreviewShot = shot
            }
            keepNote = Self.writeSidecarIfNeeded(ocrText: ocrText, alongside: url)
            return url
        } catch {
            Log.capture.error("保存失败: \(error.localizedDescription, privacy: .public)")
            presentSaveFailure(error)
            return nil
        }
    }

    /// 勾了「识别结果同时存为同名 .txt」才写，且只在图已经落盘之后 ——
    /// "同名"要有个名可对。返回那句要拼进角标的说明，没写就返回 nil。
    static func writeSidecarIfNeeded(ocrText: String?, alongside url: URL) -> String? {
        guard SettingsStore.shared.saveOCRText,
              let ocrText, !ocrText.isEmpty else { return nil }
        let txtURL = ImageWriter.textURL(alongside: url)
        do {
            try ImageWriter.writeText(ocrText, alongside: url)
            return ImageWriter.ocrTextStatus(wrote: true, txtURL: txtURL, reason: nil)
        } catch {
            Log.ocr.error("写入 .txt 失败: \(error.localizedDescription, privacy: .public)")
            return ImageWriter.ocrTextStatus(wrote: false, txtURL: txtURL,
                                             reason: error.localizedDescription)
        }
    }

    /// 右下角的瞬时角标：告诉他文件叫什么、落在哪儿，点一下直接在访达里选中它。
    ///
    /// 只在用户按「保存」关掉预览之后出现 —— 预览还开着时再叠一层角标纯属重复。
    private func presentToast(for url: URL,
                              image: CGImage,
                              screen: NSScreen?,
                              prefix: String,
                              note: String? = nil) {
        let directory = NSString(string: settings.saveDirectory).abbreviatingWithTildeInPath
        // 不再断言"有没有进剪贴板"：截图本身不进，用户按没按「复制图片」是
        // 他自己刚做过、也刚看过回执的事，这里再念一遍只会是第二份真相。
        var detail = "\(prefix)　·　存到 \(directory)"
        // `ocrTextStatus` / `ocrTextPendingStatus` 自带「　·　」前缀；再补一个
        // 分隔符会变成「 · · 已存」，角标上看着像排版坏了。没有前缀的才补。
        if let note {
            detail += note.hasPrefix("　") ? note : "　·\(note)"
        }

        ToastHUDController.shared.show(title: url.lastPathComponent,
                                       detail: detail,
                                       thumbnail: image,
                                       screen: screen,
                                       duration: 3.8,
                                       onClick: { _ = SystemOpen.reveal(url) })
    }

    /// 图片写进剪贴板（TIFF + PNG 两份；已有文件时再带一份文件 URL），
    /// 返回**回读后**的成功与否。
    static func copyImageToPasteboard(_ image: CGImage, fileURL: URL? = nil) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        return PasteboardWrite.writeImage(tiff: rep.tiffRepresentation,
                                          png: rep.representation(using: .png, properties: [:]),
                                          fileURL: fileURL)
    }

    /// 丢弃失败的对话框。这里**不撤预览面板**（`onDiscard` 返回 false），
    /// 所以对话框只负责说清"没丢掉、还在哪儿、怎么自己删"；
    /// 用户关掉对话框后仍可以按「保存」正常收尾。
    private func presentDiscardFailure(url: URL, reason: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "没能移到废纸篓"
        alert.informativeText = ImageWriter.discardFailureText(url: url, reason: reason)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "在访达中显示")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            // 没打开时 `reveal` 自己会出那句角标，这里不用再报一遍。
            _ = SystemOpen.reveal(url)
        }
    }

    /// 「保存」失败。和截图失败不是一回事：图已经在手，只是没能变成文件。
    /// 所以那句"现在怎么办"必须带上"东西没丢" —— 用户听到"保存失败"时
    /// 第一个要确定的是这张图还在不在。
    private func presentSaveFailure(_ error: Error) {
        presentError(error,
                     title: "没能保存",
                     footnote: "这张图还在面板上，面板也还开着　·　换个位置再按一次「保存」就行")
    }

    private func presentError(_ error: Error,
                              title: String = "截图失败",
                              footnote: String? = nil) {
        let failure = error as? CaptureError
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Log.capture.error("\(title, privacy: .public): \(message, privacy: .public)")

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        // 错误本身只说"发生了什么"，后面那两句才是用户要的"那我现在做什么"。
        alert.informativeText = [message, failure?.recoveryHint, footnote]
            .compactMap { $0 }
            .joined(separator: "\n")
        alert.alertStyle = .warning
        // 有出路时把出路当**默认按钮**（回车就是它），"好"退到第二位；
        // 没出路时"好"自然还是默认。
        if let title = failure?.recoveryTitle {
            alert.addButton(withTitle: title)
        }
        alert.addButton(withTitle: "好")

        guard failure?.recovery != nil, alert.runModal() == .alertFirstButtonReturn else { return }
        switch failure?.recovery {
        case .openPermissionSettings: Permissions.openScreenRecordingSettings()
        case .openSettings:           onOpenSettings?()
        case .retry:
            // 见 `retryAfterBusy`：模态框里直接重入会被 isBusy 闸门吞掉。
            if isBusy { retryAfterBusy = true } else { handleCapture() }
        case .none:                   break
        }
    }
}
