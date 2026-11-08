import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: LocalizedError {
    case noScreenRecording
    case noDisplay
    case windowGone
    case emptySelection
    case cropFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noScreenRecording:  return "缺少「屏幕录制」权限"
        case .noDisplay:          return "找不到可用的显示器（显示器可能已休眠或已断开）"
        case .windowGone:         return "目标窗口已关闭"
        case .emptySelection:     return "选区太小，已取消"
        case .cropFailed:         return "截图裁剪失败"
        case .writeFailed(let m): return "写入文件失败：\(m)"
        }
    }

    /// 失败之后**还能为用户做的一件事**。
    ///
    /// 只报"截图失败 + 一句系统错误"的对话框，等于把问题原样丢回给用户。
    /// 能一键去解决的就给按钮；解决不了的，至少说清下一步该做什么。
    enum Recovery {
        case openPermissionSettings
        case openSettings
        case retry
    }

    var recovery: Recovery? {
        switch self {
        case .noScreenRecording:  return .openPermissionSettings
        case .noDisplay:          return .retry
        case .writeFailed:        return .openSettings
        case .windowGone, .cropFailed, .emptySelection: return nil
        }
    }

    /// 按钮标题。`recovery` 非空时必须有 —— 弹出一个没名字的按钮比不弹更糟。
    var recoveryTitle: String? {
        switch recovery {
        case .openPermissionSettings: return "去开启权限"
        case .openSettings:           return "换个保存位置"
        case .retry:                  return "再试一次"
        case .none:                   return nil
        }
    }

    /// 跟在错误后面那句"接下来怎么办"。
    var recoveryHint: String? {
        switch self {
        case .noScreenRecording:
            return "在「屏幕录制」列表里勾上 Grabi，勾完必须重启一次 app 才生效。"
        case .noDisplay:
            return "动一下鼠标或按一下电源键唤醒显示器，再按一次截图热键。"
        case .windowGone:
            return "窗口在你按下热键之后就关掉了，重新截一张即可。"
        case .cropFailed:
            return "通常是显示器分辨率在截图途中变了，再截一次一般就好。"
        case .writeFailed:
            return "多半是保存目录被删掉、挪走或磁盘满了。换个位置，或把原目录建回来。"
        case .emptySelection:
            return nil
        }
    }
}

/// 截图引擎。
///
/// 用 ScreenCaptureKit（走 GPU 合成管线），比老的 `CGWindowListCreateImage`
/// 更快、色彩更准，也是 macOS 15+ 上仍被完整支持的方式。
final class CaptureEngine {

    private func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    // MARK: - 尺寸换算（Retina 的关键）

    /// 显示器的**像素**尺寸。
    ///
    /// 这里是之前截图"不够清晰"的根因：`SCDisplay.width/height` 返回的是
    /// **逻辑点**（例如 1440×900），而屏幕的物理像素是它的 `backingScaleFactor`
    /// 倍（Retina 上是 2880×1800）。直接把它填进 `SCStreamConfiguration.width`
    /// 等于主动降采样，拿到的是非 Retina 的模糊图。
    ///
    /// 这里按缩放倍数换算成真实像素；同时做了防御——万一某个系统版本返回的
    /// 已经是像素值，就不要再乘一次。
    private func pixelSize(of display: SCDisplay, on screen: NSScreen) -> (width: Int, height: Int) {
        let scale = screen.backingScaleFactor
        let reportedLooksLikePoints = CGFloat(display.width) <= screen.frame.width * 1.2

        let width  = reportedLooksLikePoints ? (CGFloat(display.width) * scale) : CGFloat(display.width)
        let height = reportedLooksLikePoints ? (CGFloat(display.height) * scale) : CGFloat(display.height)

        return (Int(width.rounded()), Int(height.rounded()))
    }

    // MARK: - 显示器匹配

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func scDisplay(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        guard let id = displayID(of: screen) else { return nil }
        return content.displays.first { $0.displayID == id }
    }

    // MARK: - 整屏 / 区域

    /// 抓取整块显示器，输出为显示器原生像素尺寸（Retina 上是 2x）。
    ///
    /// - Parameter excludingWindowIDs: 要从画面里**排除**的窗口。
    ///   重新截取时必须把 Grabi 自己的窗口（预览面板、工具栏、压暗层）
    ///   排除掉——否则会被拍进去。排除而不是"先藏再抓"的原因很实际：
    ///   藏了就得等系统合成完再抓，那 200ms 里用户眼前是空的，会闪一下。
    func captureDisplay(containing screen: NSScreen,
                        excludingWindowIDs: [CGWindowID] = []) async throws -> CGImage {
        guard Permissions.hasScreenRecording else { throw CaptureError.noScreenRecording }

        let content = try await shareableContent()
        guard let display = scDisplay(for: screen, in: content) else { throw CaptureError.noDisplay }

        let size = pixelSize(of: display, on: screen)

        // SCContentFilter 只认 SCWindow 对象，按 windowID 反查
        let excluded = excludingWindowIDs.compactMap { id in
            content.windows.first { $0.windowID == CGWindowID(id) }
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.showsCursor = SettingsStore.shared.showCursor
        config.captureResolution = .best
        config.scalesToFit = false
        // 不做色彩空间转换，避免额外的重采样
        config.colorSpaceName = CGColorSpace.sRGB

        let timer = Stopwatch("captureDisplay")
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                              configuration: config)
        timer.stop(Log.capture)
        Log.capture.info("整屏 \(image.width)×\(image.height) px（屏幕逻辑尺寸 \(Int(screen.frame.width))×\(Int(screen.frame.height)) pt @\(screen.backingScaleFactor)x）")
        return image
    }

    /// 抓取 `screen` 上的一块区域（输入是 NSScreen 坐标系，原点左下）。
    ///
    /// 做法是整屏抓取后本地裁剪，而不是用 `SCStreamConfiguration.sourceRect`：
    /// sourceRect 的坐标系语义在不同版本上不一致（点 / 像素），整屏抓 + 裁
    /// 在任何缩放组合下都稳定正确，代价只是一次临时内存占用。
    func captureRegion(_ rectInScreen: CGRect,
                       on screen: NSScreen,
                       excludingWindowIDs: [CGWindowID] = []) async throws -> CGImage {
        guard rectInScreen.width >= 1, rectInScreen.height >= 1 else {
            throw CaptureError.emptySelection
        }

        let full = try await captureDisplay(containing: screen,
                                            excludingWindowIDs: excludingWindowIDs)
        let scale = CGFloat(full.width) / max(screen.frame.width, 1)

        let pixelRect = Self.pixelRect(of: rectInScreen, in: screen.frame, scale: scale)

        let bounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
        let clamped = pixelRect.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else {
            throw CaptureError.emptySelection
        }

        guard let cropped = full.cropping(to: clamped) else { throw CaptureError.cropFailed }
        Log.capture.info("区域 \(cropped.width)×\(cropped.height) px")
        return cropped
    }

    /// 全局屏幕坐标（原点主屏左下）→ 该显示器图像里的像素矩形（原点该屏左上）。
    ///
    /// 单独抽出来只为一件事：这段换算是整个 app 最容易错、又最难验的地方 ——
    /// 既要减掉该屏在全局里的原点（副屏 `frame.origin ≠ 0`，少减一步就会整体偏移
    /// 一个屏宽：要么裁到图像外，要么静默裁到**另一块内容**上），又要翻 Y，
    /// 还要乘 Retina 倍率。而它原先长在 `captureRegion` 里，
    /// 没有显示器 + 没有录屏权限就一行都验不了。
    static func pixelRect(of rect: CGRect, in screenFrame: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: (rect.minX - screenFrame.minX) * scale,
               y: (screenFrame.maxY - rect.maxY) * scale,
               width: rect.width * scale,
               height: rect.height * scale).integral
    }

    /// 从一张已捕获的图里裁出局部（部分识别走这条路）。
    ///
    /// `normalizedRect` 的原点在**左下**（和 Vision 的归一化坐标一致），
    /// 而 `CGImage` 的像素原点在**左上**，所以纵坐标必须翻一次。漏掉这一步的
    /// 后果是：框选上面一块，裁出来的是下面那一块（上下颠倒），局部识别因此
    /// 识别到完全不相干的文字。
    func crop(_ image: CGImage, to normalizedRect: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        let rect = CGRect(x: normalizedRect.minX * width,
                          y: (1 - normalizedRect.maxY) * height,
                          width: normalizedRect.width * width,
                          height: normalizedRect.height * height).integral
        let clamped = rect.intersection(CGRect(x: 0, y: 0,
                                               width: image.width, height: image.height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return image.cropping(to: clamped)
    }

    // MARK: - 窗口

    struct WindowCandidate {
        let window: SCWindow
        /// NSScreen 坐标系（原点主屏左下）中的窗口矩形。
        let frameInScreenCoords: CGRect
    }

    /// 窗口几何信息。`SCWindow` 不能只靠测试构造，所以 Chrome 全屏辅助条的
    /// 判断只依赖这份普通值类型；真实路径再把结果映射回 `SCWindow`。
    struct WindowGeometry: Equatable {
        let windowID: CGWindowID
        let processID: pid_t
        let frame: CGRect
    }

    /// 当前可截图的所有普通窗口（按层级从前往后）。
    func windowCandidates() async throws -> [WindowCandidate] {
        guard Permissions.hasScreenRecording else { throw CaptureError.noScreenRecording }

        let content = try await shareableContent()
        return Self.windowCandidates(from: content.windows,
                                     screens: NSScreen.screens,
                                     excludingPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// 把 `SCShareableContent.windows` 收成可点击的候选。
    ///
    /// Chrome 全屏时会同时报告一条接近屏幕宽度、但只有工具栏高度的辅助层
    /// （实机上见过 4096×298）。它满足 `windowLayer == 0`，又排在主窗口前面，
    /// 旧逻辑取"第一个包含鼠标点的窗口"就会截到这条，而不是浏览器正文。
    ///
    /// 这里按**同应用、同屏幕**做一次主窗口优选：如果命中的窗口形状像辅助条，
    /// 且该应用另有更大的正常窗口，就让更大的那个胜出。不按标题猜，
    /// 也不跨应用替换，避免把别的软件窗口顶掉。
    static func windowCandidates(from windows: [SCWindow],
                                 screens: [NSScreen],
                                 excludingPID: pid_t) -> [WindowCandidate] {
        let screenFrames = screens.map(\.frame)
        let primaryHeight = screenFrames.first?.maxY ?? 0
        let candidates = windows.compactMap { win -> WindowCandidate? in
            guard win.isOnScreen,
                  win.windowLayer == 0,
                  win.frame.width >= 60,
                  win.frame.height >= 60,
                  let app = win.owningApplication,
                  app.processID != excludingPID
            else { return nil }

            // CG 坐标（左上原点，y 向下）→ NSScreen 坐标（左下原点，y 向上）
            let ns = CGRect(x: win.frame.minX,
                            y: primaryHeight - win.frame.maxY,
                            width: win.frame.width,
                            height: win.frame.height)
            return WindowCandidate(window: win, frameInScreenCoords: ns)
        }

        let geometries = candidates.compactMap { candidate -> WindowGeometry? in
            guard let app = candidate.window.owningApplication else { return nil }
            return WindowGeometry(windowID: candidate.window.windowID,
                                  processID: app.processID,
                                  frame: candidate.window.frame)
        }
        let kept = Set(Self.filterAuxiliaryWindows(geometries,
                                                   screenFrames: screenFrames,
                                                   primaryHeight: primaryHeight)
            .map(\.windowID))
        return candidates.filter { kept.contains($0.window.windowID) }
    }

    /// 丢掉 Chrome 全屏时那条“横跨屏幕但只有工具栏高”的辅助窗口。
    ///
    /// 只处理同一进程、同一屏幕的情况：应用 A 的辅助条绝不会因为应用 B
    /// 有一个大窗口而被丢掉。没有同应用主窗口时保留它，总比让用户只能截全屏强。
    static func filterAuxiliaryWindows(_ windows: [WindowGeometry],
                                       screenFrames: [CGRect],
                                       primaryHeight: CGFloat) -> [WindowGeometry] {
        windows.filter { candidate in
            let candidateFrame = frameInScreenCoords(candidate.frame,
                                                     primaryHeight: primaryHeight)
            guard let screen = screenFrames.first(where: {
                $0.contains(CGPoint(x: candidateFrame.midX, y: candidateFrame.midY))
            }) else { return true }

            let looksLikeFullscreenBar =
                candidate.frame.width >= screen.width * 0.90
                && candidate.frame.height <= 360
            guard looksLikeFullscreenBar else { return true }

            let sameAppMain = windows.contains { other in
                guard other.windowID != candidate.windowID,
                      other.processID == candidate.processID
                else { return false }

                let otherFrame = frameInScreenCoords(other.frame,
                                                     primaryHeight: primaryHeight)
                guard screen.contains(CGPoint(x: otherFrame.midX, y: otherFrame.midY))
                else { return false }

                return other.frame.width >= screen.width * 0.90
                    && other.frame.height > candidate.frame.height
                    && other.frame.height >= screen.height * 0.50
            }
            return !sameAppMain
        }
    }

    private static func frameInScreenCoords(_ frame: CGRect,
                                            primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX,
               y: primaryHeight - frame.maxY,
               width: frame.width,
               height: frame.height)
    }

    func capture(window: SCWindow) async throws -> CGImage {
        guard Permissions.hasScreenRecording else { throw CaptureError.noScreenRecording }

        let scale = scaleFactor(for: window)
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        // 窗口的 frame 是逻辑点，同样要乘缩放倍数才能拿到清晰的原生像素
        config.width = max(Int((window.frame.width * scale).rounded()), 1)
        config.height = max(Int((window.frame.height * scale).rounded()), 1)
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.colorSpaceName = CGColorSpace.sRGB

        let timer = Stopwatch("captureWindow")
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                              configuration: config)
        timer.stop(Log.capture)
        Log.capture.info("窗口 \(image.width)×\(image.height) px @\(scale)x")
        return image
    }

    private func scaleFactor(for window: SCWindow) -> CGFloat {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let center = CGPoint(x: window.frame.midX, y: primaryHeight - window.frame.midY)
        for screen in NSScreen.screens where screen.frame.contains(center) {
            return screen.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }
}
