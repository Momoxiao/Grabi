import AppKit
import ScreenCaptureKit
import Vision
import VisionKit

/// 命令行自检模式，方便在不启动界面的情况下验证链路。
///
/// 完整清单跑 `Grabi --help` —— 这里**不再抄一份**：手抄的清单已经两次和真实
/// 参数分家（热键那两行抄错、自检项改名后没跟上）。留一个指针，不留第二份真相。
enum Diagnostics {

    static func runDiagnose() {
        let settings = SettingsStore.shared

        print("Grabi 自检")
        print("──────────────────────────────────────────")
        print("macOS          : \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("架构           : \(architecture())")
        print("Bundle ID      : \(Bundle.main.bundleIdentifier ?? "（未打包，直接跑二进制）")")
        print("可执行文件      : \(Bundle.main.executableURL?.path ?? "-")")
        print("屏幕录制权限    : \(Permissions.hasScreenRecording ? "已授权 ✓" : "未授权 ✗")")
        if let last = Permissions.lastLaunchState {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm:ss"
            print("上次 GUI 启动    : \(formatter.string(from: last.at))　权限=\(last.hadPermission ? "有 ✓" : "无 ✗")")
            print("                  ↑ 这一行才是以 .app 启动时的真实状态；")
            print("                    从终端跑本命令时判定会继承终端的授权，仅作参考")
        }
        print("──────────────────────────────────────────")
        print("显示器")
        for line in displayReport() {
            print("  " + line)
        }
        print("──────────────────────────────────────────")
        print("保存")
        print("保存目录        : \(settings.saveDirectory)")
        print("目录可写        : \(settings.ensureSaveDirectory() ? "是 ✓" : "否 ✗")")
        print("图片格式        : \(settings.imageFormat.rawValue)　质量 \(Int(settings.jpegQuality * 100))%")
        print("文件名模板      : \(settings.fileNamePattern)")
        print("──────────────────────────────────────────")
        print("其他")
        print("OCR 可用语言    : \(OCRLanguage.common.map(\.code).filter { OCRRecognizer.supportedLanguages.contains($0) }.joined(separator: ", "))")
        print("OCR 语言设置    : \(settings.ocrLanguages.joined(separator: ", "))")
        print("隐藏菜单栏图标  : \(settings.hideStatusBarIcon ? "是" : "否")")
        print("开机自启        : \(settings.launchAtLogin ? "开" : "关")")
        print("崩溃保活        : \(settings.keepAlive ? "开" : "关")")
        print("自启动机制      : \(AutoStartManager.shared.activeMechanism.rawValue)")
        print("自启动状态      : \(AutoStartManager.shared.statusDescription)")
        print("标准应用目录    : \(AutoStartManager.shared.isInStandardLocation ? "是 ✓" : "否 ✗（后台启动会被系统拒绝）")")
        print("──────────────────────────────────────────")
        print("快捷键")
        print("  截图      \(settings.hotKeyCapture.displayString)")
        print("──────────────────────────────────────────")
        // 这一句以前写的是「热键占用检测 / 可用 ✓」—— 那个 ✓ 是假的：
        // 实测运行中的 Grabi 正持有 ⇧⌘X 与 ⌃⌥S，另起进程重复注册仍然返回
        // noErr，跨进程占用根本报不上来。所以这里只能说"注册得成"，不能说"没人用"。
        print("热键注册检测（⚠ 系统不报跨进程冲突：「可注册」不等于「没人占用」）")
        for (title, spec) in [("截图", settings.hotKeyCapture)] {
            let padded = title.padding(toLength: 12, withPad: " ", startingAt: 0)
            let key = spec.displayString.padding(toLength: 10, withPad: " ", startingAt: 0)
            guard !spec.isDisabled else {
                print("  \(padded)\(key)未启用")
                continue
            }
            let verdict = probeHotKey(spec) ? "可注册 ✓（仍可能被别的 app 抢着）"
                                           : "注册被拒 ✗（多半是组合键本身不合用）"
            print("  \(padded)\(key)\(verdict)")
            if spec.modifierCount < 2 {
                print("  \(padded)\(String(repeating: " ", count: 10))⚠ 只有 \(spec.modifierCount) 个修饰键：这条会抢走其他 app 的同名快捷键")
            }
            if spec.conflictsWithSystemScreenshot {
                print("  \(padded)\(String(repeating: " ", count: 10))⚠ macOS 自带截图也在用这条，按下去哪边响应不一定")
            }
        }
        exit(0)
    }

    // MARK: - 界面自检（真的把界面画出来看一眼）

    /// 把就地预览、工具栏、压暗层和结果角标画到屏幕上，再自己拍一张全屏存盘。
    ///
    /// 存在的理由：这些全是交互层的东西，"编译通过"和"看着对"是两回事，
    /// 而在没有显示器的终端里跑单元测试又完全测不到它。所以让 app 自己
    /// 把界面摆出来、自己截下来交给外部看。
    ///
    /// 必须用 `open` 启动才有屏幕录制权限（走 app 自己的签名身份）：
    ///
    ///     open -n /Applications/Grabi.app --args --ui-preview /tmp/preview.png
    static func runUIPreview(to output: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // 控制器必须有个强引用活着，否则面板会在无人预期的情况下被释放
        uiPreviewHolder = InlinePreviewController()
        guard let preview = uiPreviewHolder else { exit(1) }

        DispatchQueue.main.async {
            guard let screen = NSScreen.main, let image = uiPreviewImage() else {
                print("无法准备演示图")
                exit(1)
            }
            NSApp.activate(ignoringOtherApps: true)

            let width = min(screen.frame.width * 0.42, 680)
            let rect = CGRect(x: screen.frame.midX - width / 2,
                              y: screen.frame.midY - width * 0.33,
                              width: width, height: width * 0.66)
            // 演示走的是真实那条路径：不带 url —— 这一刻本来就没有文件。
            // 以前这里为了让 `show` 收下一个 url 而先写一张演示图进截图目录、
            // 拍完屏再挪进废纸篓，等于自检在用户的保存目录里进出垃圾。
            preview.show(image: image, selectionRect: rect, screen: screen)
            ToastHUDController.shared.show(title: "就地预览演示",
                                           detail: "「保留」存盘　·　「复制图片」进剪贴板",
                                           thumbnail: image,
                                           screen: screen,
                                           duration: 30)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                Task {
                    do {
                        let shot = try await CaptureEngine().captureDisplay(containing: screen)
                        let png = NSBitmapImageRep(cgImage: shot)
                            .representation(using: .png, properties: [:])!
                        try png.write(to: URL(fileURLWithPath: output))
                        print("已写出 \(output)（\(shot.width)×\(shot.height)）")
                    } catch {
                        print("拍屏失败: \(error.localizedDescription)")
                    }
                    preview.dismiss(reason: .replaced)
                    exit(0)
                }
            }
        }
        app.run()
    }

    private static var uiPreviewHolder: InlinePreviewController?

    /// 一张"像真截图"的演示图：有标题栏、有正文、有中英混排，
    /// 这样预览里的观感（描边、投影、圆角、工具栏比例）才接近真实情况。
    private static func uiPreviewImage() -> CGImage? {
        let width = 1360, height = 900
        let W = CGFloat(width), H = CGFloat(height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                                         pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: W, height: H).fill()

            NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: H - 76, width: W, height: 76).fill()

            let body = [
                "Grabi — 就地预览自检",
                "截图完成后，预览面板直接浮在你刚框选的位置上。",
                "识别文字后可以按住拖动划选，⌘C 复制；空白处拖动能挪面板。",
                "The quick brown fox jumps over the lazy dog.",
                "边框上的圆点手柄可以重新框选，会按新范围重新截一次。"
            ]
            var y = H - 150
            for (index, line) in body.enumerated() {
                let font = index == 0 ? NSFont.systemFont(ofSize: 46, weight: .bold)
                                      : NSFont.systemFont(ofSize: 34, weight: .regular)
                (line as NSString).draw(at: NSPoint(x: 64, y: y),
                                        withAttributes: [.font: font,
                                                         .foregroundColor: NSColor.black])
                y -= index == 0 ? 96 : 74
            }
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// 显示器信息 —— 用来验证截图分辨率是否取到了原生像素。
    private static func displayReport() -> [String] {
        var lines: [String] = []
        for screen in NSScreen.screens {
            lines.append("NSScreen \(Int(screen.frame.width))×\(Int(screen.frame.height)) pt @\(screen.backingScaleFactor)x  → 预期截图 \(Int(screen.frame.width * screen.backingScaleFactor))×\(Int(screen.frame.height * screen.backingScaleFactor)) px")
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                for display in content.displays {
                    lines.append("SCDisplay id=\(display.displayID) 报告 \(display.width)×\(display.height)")
                }
            } catch {
                lines.append("（无法读取 ScreenCaptureKit 信息：\(error.localizedDescription)）")
            }
        }
        semaphore.wait()
        return lines
    }

    private static func probeHotKey(_ spec: HotKeySpec) -> Bool {
        let center = HotKeyCenter()
        let ok = center.register(spec) {}
        center.unregisterAll()
        return ok
    }

    static func runOCR(path: String) {
        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("无法读取图片: \(path)")
            exit(1)
        }

        print("识别 \(path)（\(cgImage.width)×\(cgImage.height)）…")
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            do {
                let start = Date()
                let text = try await OCRRecognizer().recognize(cgImage,
                                                              languages: SettingsStore.shared.ocrLanguages)
                let elapsed = Date().timeIntervalSince(start) * 1000
                print(String(format: "耗时 %.0f ms", elapsed))
                print("──────────────────────────────────────────")
                print(text.isEmpty ? "（没有识别到文字）" : text)
            } catch {
                print("识别失败: \(error.localizedDescription)")
            }
        }
        semaphore.wait()
        exit(0)
    }

    /// OCR 冷启动 / 预热基准。
    ///
    /// 用来回答"为什么第一次点识别要等很久"。顺序刻意是**先预热再测**：
    /// 预热那一段就是 app 启动 2.5 秒后在后台静默跑掉的那一趟，用户看不见；
    /// 第二行才是用户点「识别文字」真正会等到的时间。
    static func runOCRBench() {
        print("OCR 冷启动基准（语言：\(SettingsStore.shared.ocrLanguages.joined(separator: ", "))）")
        print("──────────────────────────────────────────")

        guard let probe = benchImage() else {
            print("无法创建离屏画布")
            exit(1)
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }

            let warmStart = Date()
            OCRRecognizer.warmUp(force: true)
            let warmDeadline = Date().addingTimeInterval(120)
            while !OCRRecognizer.isWarm && Date() < warmDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            print(String(format: "  预热（后台） %8.0f ms  isWarm=%@",
                         Date().timeIntervalSince(warmStart) * 1000,
                         OCRRecognizer.isWarm ? "true" : "false"))

            print(String(format: "  预热后识别   %8.0f ms   ← 用户实际等的是这个",
                         await timeRecognize(probe)))
            print(String(format: "  再识别一次   %8.0f ms", await timeRecognize(probe)))
        }
        semaphore.wait()
        print("──────────────────────────────────────────")
        print("第一行是模型加载，一次性的，被预热提前吃掉；")
        print("第二行才是用户点「识别文字」会等到的时间。")
        print("")
        print("注意：命令行下预热可能静默失败（Vision 需要完整 app 上下文），")
        print("      看上面的 isWarm：false 的话第二行就还是冷启动数字。")
        exit(0)
    }

    // MARK: - OCR 质量基准

    /// 一个测试场景：自带图片和标准答案。
    private struct OCRCase {
        let name: String
        let image: CGImage
        let expected: String
    }

    /// OCR 质量 / 速度基准。
    ///
    /// 存在的理由：原来的 `--ocr-selftest` 用**字符集合**比对（去重、无序），
    /// 顺序错了、字重复了照样 100%，根本没有刻度。这里换成
    /// 「去空白后的编辑距离相似度」——顺序敏感、数量敏感。
    ///
    /// ⚠️ 一定**先预热再测**。这台机器冷启动那一次要 2–30 秒，而且冷完之后
    /// 后续调用还会集体报错；预热把这份代价提前付掉，后面的每轮测量才可比。
    static func runOCRQuality() {
        let arguments = CommandLine.arguments
        var rounds = 2
        if let index = arguments.firstIndex(of: "--rounds"),
           arguments.indices.contains(index + 1),
           let parsed = Int(arguments[index + 1]) {
            rounds = max(1, parsed)
        }
        let ab = arguments.contains("--ab")

        let cases = buildOCRCases()
        guard !cases.isEmpty else { print("造图失败"); exit(1) }

        let configs: [(label: String, tuning: OCRRecognizer.Tuning)] = ab
            ? [("新引擎 revision3", .init()),
               ("旧引擎 VNRequest", .init(engine: .legacy)),
               ("不缩图",           .init(maxSide: 0)),
               ("压到 1280",        .init(maxSide: 1280)),
               ("最小字高 0.02",    .init(minimumTextHeight: 0.02))]
            : [("当前配置", .init())]

        print("OCR 质量基准（轮数 \(rounds)，先预热再测）")
        print("──────────────────────────────────────────")

        // ⚠️ 测量必须放在**真正 run 起来**的 NSApplication 里。
        // 只建 NSApplication.shared 不够：那样预热要么秒完成、要么拖 30 秒，
        // 之后每次识别都抛 CRImageReaderError 1，测出来的全是假数字。
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            let warmStart = Date()
            OCRRecognizer.warmUp(force: true)
            // 等预热真正跑完。之前这里写成 `spun < 3000` 而每轮加 20_000_000，
            // 一轮就退出了——只等 20ms 就开始测，于是"预热 71ms"是假象，
            // 冷启动成本全落到第一次测量上，后面还跟着一串报错。
            let warmDeadline = Date().addingTimeInterval(120)
            while !OCRRecognizer.isWarm && Date() < warmDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            print(String(format: "预热 %.0f ms（isWarm=%@，之后所有测量都在热态）\n",
                         Date().timeIntervalSince(warmStart) * 1000,
                         OCRRecognizer.isWarm ? "true" : "false"))

            var anySucceeded = false
            for config in configs {
                OCRRecognizer.tuning = config.tuning
                var totalSimilarity = 0.0
                var totalMS = 0.0

                for ocrCase in cases {
                    var rates: [Double] = []
                    var times: [Double] = []
                    // 留最后一次实际输出，相似度不满时打出来看错在哪
                    var lastGot = ""

                    for _ in 0..<rounds {
                        let start = Date()
                        do {
                            let lines = try await OCRRecognizer().recognizeLines(
                                ocrCase.image, languages: SettingsStore.shared.ocrLanguages)
                            let got = lines.map(\.text).joined(separator: "\n")
                            lastGot = got
                            rates.append(similarity(ocrCase.expected, got))
                            times.append(Date().timeIntervalSince(start) * 1000)
                            anySucceeded = true
                        } catch {
                            rates.append(0)
                            times.append(Date().timeIntervalSince(start) * 1000)
                        }
                    }

                    let rate = median(rates)
                    let ms = median(times)
                    totalSimilarity += rate
                    totalMS += ms
                    let flag = rate >= 0.98 ? "✓" : (rate >= 0.9 ? "~" : "✗")
                    print(String(format: "    %-14@ 相似度 %5.1f%% %@   %6.0f ms",
                                 ocrCase.name, rate * 100, flag, ms))
                    if rate < 0.995, !lastGot.isEmpty {
                        print("        期望：\(Self.flatten(ocrCase.expected))")
                        print("        实际：\(Self.flatten(lastGot))")
                    }
                }

                // 一个场景都没认出来，说明 Vision 在抛错，
                // 剩下的配置只会得到同样的 0，别白跑
                if !anySucceeded { break }

                let avg = totalSimilarity / Double(cases.count)
                print(String(format: "  ▸ %-18@ 平均相似度 %5.1f%%   合计 %6.0f ms\n",
                             config.label, avg * 100, totalMS))
            }

            OCRRecognizer.tuning = OCRRecognizer.Tuning()
            if !anySucceeded {
                print("")
                print("⚠️ 这一轮 Vision 一直是病态的：预热之后每次识别都抛错")
                print("   （CRImageReaderError 1），上面的数字不可用。")
                print("   这不是 Grabi 的问题——机器上偶发，等一会儿重跑就好。")
            }
            print("──────────────────────────────────────────")
            print("相似度 = 去掉空白后按字符算的编辑距离相似度（顺序敏感、字数敏感）。")
            exit(0)
        }
        app.run()
    }

    /// 造几张覆盖不同场景的测试图。
    private static func buildOCRCases() -> [OCRCase] {
        func draw(width: Int, height: Int, lines: [String], size: CGFloat, mono: Bool = false) -> CGImage? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = context
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: width, height: height).fill()
                NSColor.black.setFill()
                let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                                : NSFont.systemFont(ofSize: size)
                let step = size * 1.6
                var y = CGFloat(height) - step - 20
                for line in lines {
                    (line as NSString).draw(at: NSPoint(x: 24, y: y),
                                            withAttributes: [.font: font,
                                                             .foregroundColor: NSColor.black])
                    y -= step
                }
                context.flushGraphics()
            }
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage
        }

        var cases: [OCRCase] = []

        let chinese = ["截屏之后就地浮出预览面板", "点一下就能复制画面里的字", "识别全程在本机完成不联网"]
        if let image = draw(width: 900, height: 260, lines: chinese, size: 30) {
            cases.append(OCRCase(name: "中文正文", image: image,
                                 expected: chinese.joined(separator: "\n")))
        }

        let mixed = ["Grabi 是一款 macOS 轻量截图工具",
                     "Screen capture with on-device OCR",
                     "支持简体中文与 English 混排识别"]
        if let image = draw(width: 1000, height: 260, lines: mixed, size: 26) {
            cases.append(OCRCase(name: "中英混排", image: image,
                                 expected: mixed.joined(separator: "\n")))
        }

        let small = ["文件 编辑 视图 窗口 帮助", "共 128 个项目，已选中 3 个", "Cancel OK Apply"]
        if let image = draw(width: 700, height: 160, lines: small, size: 13) {
            cases.append(OCRCase(name: "小字 13pt", image: image,
                                 expected: small.joined(separator: "\n")))
        }

        let code = ["func recognize(_ image: CGImage) async throws -> [Line] {",
                    "    let request = VNRecognizeTextRequest()",
                    "    request.recognitionLevel = .accurate"]
        if let image = draw(width: 1100, height: 200, lines: code, size: 18, mono: true) {
            cases.append(OCRCase(name: "代码等宽", image: image,
                                 expected: code.joined(separator: "\n")))
        }

        // 大图专门用来量「缩图」到底是帮忙还是帮倒忙
        let bigText = ["这是一张模拟 Retina 全屏的大图", "用来验证缩图对识别质量的影响"]
        if let image = draw(width: 3200, height: 1800, lines: bigText, size: 70) {
            cases.append(OCRCase(name: "大图 3200×1800", image: image,
                                 expected: bigText.joined(separator: "\n")))
        }

        return cases
    }

    /// 压成一行便于对比（相似度本来就是去空白算的，这里也去掉空白）。
    private static func flatten(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    /// 去掉全部空白后的编辑距离相似度（1.0 = 完全一致）。
    private static func similarity(_ expected: String, _ actual: String) -> Double {
        let a = Array(expected.filter { !$0.isWhitespace })
        let b = Array(actual.filter { !$0.isWhitespace })
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }

        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = Array(repeating: 0, count: b.count + 1)
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static func timeRecognize(_ image: CGImage) async -> Double {
        let start = Date()
        _ = try? await OCRRecognizer().recognizeLines(image, languages: SettingsStore.shared.ocrLanguages)
        return Date().timeIntervalSince(start) * 1000
    }

    /// 基准用的中英文混排小图。
    private static func benchImage() -> CGImage? {
        let width = 900, height = 200
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            ("Grabi 是一款 macOS 轻量截图工具" as NSString)
                .draw(in: NSRect(x: 30, y: 110, width: width - 60, height: 50),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 30),
                                       .foregroundColor: NSColor.black])
            ("Screen capture with on-device OCR" as NSString)
                .draw(in: NSRect(x: 30, y: 40, width: width - 60, height: 50),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 30),
                                       .foregroundColor: NSColor.black])
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// 端到端 OCR 自检：程序自己画一张中英文混排的图，再识别回来。
    /// Live Text 的能力探测。
    ///
    /// 只探测"系统支不支持、支持哪些语言"，**不真的跑分析**。
    /// 原因是实测下来 `ImageAnalyzer.analyze` 在纯命令行上下文里不可靠：
    /// 同样的代码有时返回空结果、有时直接挂住不返回（它需要完整的 GUI 上下文）。
    /// 拿它当自检只会误导，所以这里保持克制。
    static func runLiveTextSelfTest() {
        print("Live Text 环境探测")
        print("──────────────────────────────────────────")
        print("macOS          : \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("系统支持       : \(ImageAnalyzer.isSupported ? "是 ✓" : "否 ✗")")

        let languages = ImageAnalyzer.supportedTextRecognitionLanguages
        print("支持识别语言   : \(languages.isEmpty ? "（读不到）" : languages.joined(separator: ", "))")
        print("──────────────────────────────────────────")
        print("注意：真正的识别请在 app 里点「识别文字」验证。")
        print("      analyze 需要 GUI 上下文，命令行下不会给出可靠结果。")
        exit(0)
    }

    static func runOCRSelfTest() {
        let width = 960
        let height = 380
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            print("无法创建离屏画布")
            exit(1)
        }

        let groundTruth = """
        Grabi 是一款 macOS 轻量截图工具
        Screen capture with on-device OCR
        支持简体中文与英文混排识别
        数字 1234567890 符号 #@%&
        """

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            (groundTruth as NSString).draw(in: NSRect(x: 40, y: 40, width: width - 80, height: height - 80),
                                           withAttributes: [
                                            .font: NSFont.systemFont(ofSize: 30),
                                            .foregroundColor: NSColor.black
                                           ])
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = rep.cgImage else {
            print("离屏画布无法导出 CGImage")
            exit(1)
        }

        print("自检画布 \(cgImage.width)×\(cgImage.height)，开始识别…")
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            do {
                let start = Date()
                let text = try await OCRRecognizer().recognize(cgImage, languages: ["zh-Hans", "en-US"])
                let elapsed = Date().timeIntervalSince(start) * 1000

                print(String(format: "耗时 %.0f ms", elapsed))
                print("────────── 预期 ──────────")
                print(groundTruth)
                print("────────── 实际 ──────────")
                print(text.isEmpty ? "（没有识别到文字）" : text)

                // ⚠️ 这里原来用**字符集合**比对（Set），去重且无序——
                // 顺序错了、字重复了照样 100%，等于没有刻度。
                // 换成去空白后的编辑距离相似度：顺序敏感、字数敏感。
                let rate = similarity(groundTruth, text)
                print("──────────────────────────")
                print(String(format: "相似度 %.1f%%", rate * 100))
                print(rate >= 0.9 ? "结果：通过 ✓" : "结果：偏低，请检查 Vision 语言包 ✗")
            } catch {
                print("识别失败: \(error.localizedDescription)")
            }
        }
        semaphore.wait()
        exit(0)
    }

    /// 坐标换算 + 裁剪自检：**不需要显示器、不需要录屏权限**。
    ///
    /// 为什么值得单独跑：区域截图是这软件的核心动作，而它全押在一次换算上 ——
    /// 「全局屏幕坐标 → 该屏像素坐标」要同时做三件事：减掉本屏在全局里的原点、
    /// 翻 Y（AppKit 原点在左下，CGImage 在左上）、乘 Retina 倍率。
    /// 任何一步错，用户拿到的都是"框的上半屏、截回下半屏"这种致命又静默的结果，
    /// 而界面渲染自检那些图**完全看不出来**。
    /// 纯逻辑自检：不依赖显示器、不依赖权限，把最容易算错的几段纯逻辑对着手算表验一遍。
    /// 分组标题 → 结论里用的短名：摘掉「── 」和括号里那段解释。
    /// 括号**外**的尾巴（「+ 最近截图清账」那种）留着，那是组名的一部分；
    /// 摘掉一段之后补回一个空格，不然会粘成「系统打开+ 最近截图清账」。
    /// 「模板：没看懂的占位符要说出来…」这种拿冒号起头的，只留冒号前那截 ——
    /// 结论是索引，不是把整条标题再念一遍。
    static func shortGroupName(_ title: String) -> String {
        var out = ""
        var depth = 0
        for ch in title {
            switch ch {
            case "─": continue
            case "（": depth += 1
            case "）":
                if depth > 0 { depth -= 1 }
                if depth == 0, !out.isEmpty, !out.hasSuffix(" ") { out.append(" ") }
            default: if depth == 0 { out.append(ch) }
            }
        }
        let head = out.split(separator: "：", maxSplits: 1).first.map(String.init) ?? out
        return head.trimmingCharacters(in: .whitespaces)
    }

    static func runLogicSelfTest() {
        _ = NSApplication.shared
        var failures = 0

        func expect(_ label: String, _ got: CGRect, _ want: CGRect) {
            let ok = got == want
            if !ok { failures += 1 }
            print(String(format: "  %@ %@\n      得到 (%.0f, %.0f, %.0f×%.0f)　期望 (%.0f, %.0f, %.0f×%.0f)",
                         ok ? "✓" : "✗", label as NSString,
                         got.minX, got.minY, got.width, got.height,
                         want.minX, want.minY, want.width, want.height))
        }

        // 分组标题在这里落一次，结尾那句结论就从这里读。
        // 以前那句是手抄的清单 —— 第二份真相，实测已经漂了：38 个组按名字只认得出 18 组，
        // 其余要么换了套词（「屏幕坐标 → 像素坐标」写成「坐标换算」），要么整组不见了
        // （设置窗的高度分配 / 图例的键名加粗 / 运行状态行的分色），
        // 而它们下面的检查全绿、结论照样打 ✓。
        var groupTitles: [String] = []
        func noteGroup(_ title: String) {
            groupTitles.append(title)
            print(title)
        }

        noteGroup("── 屏幕坐标 → 像素坐标")
        // 主屏 1440×900 @2x
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        expect("主屏·贴顶的一块（AppKit y 越大越靠上）",
               CaptureEngine.pixelRect(of: CGRect(x: 0, y: 700, width: 100, height: 100),
                                       in: primary, scale: 2),
               CGRect(x: 0, y: 200, width: 200, height: 200))
        expect("主屏·贴底的一块",
               CaptureEngine.pixelRect(of: CGRect(x: 0, y: 0, width: 100, height: 100),
                                       in: primary, scale: 2),
               CGRect(x: 0, y: 1600, width: 200, height: 200))
        expect("主屏·整屏",
               CaptureEngine.pixelRect(of: primary, in: primary, scale: 2),
               CGRect(x: 0, y: 0, width: 2880, height: 1800))
        // 右侧副屏：原点不是 0，少减一次屏原点就会裁到图像外
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        expect("右侧副屏·贴该屏左边缘",
               CaptureEngine.pixelRect(of: CGRect(x: 1440, y: 0, width: 200, height: 100),
                                       in: right, scale: 1),
               CGRect(x: 0, y: 980, width: 200, height: 100))
        // 上方副屏
        let above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        expect("上方副屏·该屏最底下一块",
               CaptureEngine.pixelRect(of: CGRect(x: 0, y: 900, width: 100, height: 100),
                                       in: above, scale: 2),
               CGRect(x: 0, y: 1600, width: 200, height: 200))

        noteGroup("── 裁剪翻轴（上半必须拿到上半的像素）")
        if let source = quadrantImage(side: 200) {
            let engine = CaptureEngine()
            // 归一化坐标原点在**左下**：minY = 0.5 那块是屏幕上半
            if let top = engine.crop(source, to: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)),
               let pixel = firstPixel(top) {
                let ok = pixel.0 > 200 && pixel.2 < 60
                if !ok { failures += 1 }
                print(String(format: "  %@ 屏幕上半 → 像素 R=%d G=%d B=%d（应为红）",
                             ok ? "✓" : "✗", pixel.0, pixel.1, pixel.2))
            }
            if let bottom = engine.crop(source, to: CGRect(x: 0, y: 0, width: 1, height: 0.5)),
               let pixel = firstPixel(bottom) {
                let ok = pixel.2 > 200 && pixel.0 < 60
                if !ok { failures += 1 }
                print(String(format: "  %@ 屏幕下半 → 像素 R=%d G=%d B=%d（应为蓝）",
                             ok ? "✓" : "✗", pixel.0, pixel.1, pixel.2))
            }
        } else {
            failures += 1
            print("  ✗ 合成图没造出来，翻轴这一节没验到")
        }

        noteGroup("── 窗口位置记忆（左上角锚定 + 拔掉副屏要能退回居中）")
        // 主屏可见区顶上留了菜单栏那 28pt；副屏在右边、原点不是 0。
        let mainVisible = NSRect(x: 0, y: 0, width: 1440, height: 872)
        let secondVisible = NSRect(x: 1440, y: 0, width: 1920, height: 1042)
        let both = [mainVisible, secondVisible]
        let settingsSize = NSSize(width: 620, height: 290)

        func expectOrigin(_ label: String, _ got: NSPoint?, _ want: NSPoint?) {
            let ok = got == want
            if !ok { failures += 1 }
            func fmt(_ p: NSPoint?) -> String {
                guard let p else { return "nil（居中）" }
                return String(format: "(%.0f, %.0f)", p.x, p.y)
            }
            print(String(format: "  %@ %@\n      得到 %@　期望 %@",
                         ok ? "✓" : "✗", label as NSString, fmt(got) as NSString, fmt(want) as NSString))
        }

        expectOrigin("主屏内：原样还原",
                     WindowFrameMemory.visibleOrigin(x: 200, top: 800, size: settingsSize, in: both),
                     NSPoint(x: 200, y: 510))
        expectOrigin("副屏还接着：还原到副屏上",
                     WindowFrameMemory.visibleOrigin(x: 1500, top: 1000, size: settingsSize, in: both),
                     NSPoint(x: 1500, y: 710))
        expectOrigin("拔掉副屏：那个位置已经不存在了，交给居中",
                     WindowFrameMemory.visibleOrigin(x: 1500, top: 1000, size: settingsSize, in: [mainVisible]),
                     nil)
        expectOrigin("顶边越过菜单栏：夹回屏内，而不是压到菜单底下",
                     WindowFrameMemory.visibleOrigin(x: 200, top: 890, size: settingsSize, in: [mainVisible]),
                     NSPoint(x: 200, y: 566))
        expectOrigin("窗口比屏幕还大：保标题栏可抓，宁可底下溢出",
                     WindowFrameMemory.visibleOrigin(x: 100, top: 880,
                                                     size: NSSize(width: 2000, height: 900),
                                                     in: [mainVisible]),
                     NSPoint(x: 16, y: -44))

        // 存 → 取 的往返：键名写错、或者错把左下原点当位置存了，只有走一遍真窗口才发现。
        let probeRect = NSRect(x: 0, y: 0, width: 300, height: 200)
        let saved = NSWindow(contentRect: probeRect, styleMask: [.titled], backing: .buffered, defer: false)
        saved.setFrameOrigin(NSPoint(x: 333, y: 222))
        WindowFrameMemory.save(saved, name: "selftest")
        let reopened = NSWindow(contentRect: probeRect, styleMask: [.titled], backing: .buffered, defer: false)
        let usedMemory = WindowFrameMemory.restore(reopened, name: "selftest", visibleFrames: both)
        UserDefaults.standard.removeObject(forKey: "windowOrigin.selftest")
        let ok = usedMemory && reopened.frame.origin == NSPoint(x: 333, y: 222)
        if !ok { failures += 1 }
        print(String(format: "  %@ 存过的位置开第二次能原样回来（用上记忆=%@，原点 (%.0f, %.0f)）",
                     ok ? "✓" : "✗", usedMemory ? "是" : "否",
                     reopened.frame.origin.x, reopened.frame.origin.y))

        noteGroup("── Chrome 全屏辅助条（同一应用只在有主窗口时才能丢掉横条）")
        let chromeScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        func geometry(_ id: UInt32, _ pid: pid_t, _ rect: CGRect) -> CaptureEngine.WindowGeometry {
            CaptureEngine.WindowGeometry(windowID: id, processID: pid, frame: rect)
        }
        func expectWindowIDs(_ label: String,
                             _ got: [CaptureEngine.WindowGeometry],
                             _ want: [CGWindowID]) {
            let ids = got.map(\.windowID)
            let ok = ids == want
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
            print("      得到 \(ids.map(String.init).joined(separator: "、"))"
                  + "　期望 \(want.map(String.init).joined(separator: "、"))")
        }

        let chromeBar = geometry(10, 501, CGRect(x: 0, y: 0, width: 1440, height: 149))
        let chromeMain = geometry(11, 501, CGRect(x: 0, y: 149, width: 1440, height: 751))
        expectWindowIDs(
            "Chrome 全屏：横条和主窗口同时存在，只留下主窗口",
            CaptureEngine.filterAuxiliaryWindows([chromeBar, chromeMain],
                                                 screenFrames: [chromeScreen],
                                                 primaryHeight: chromeScreen.maxY),
            [11]
        )
        expectWindowIDs(
            "只有一条横跨屏幕的矮窗口：保留它，不能把唯一候选也筛掉",
            CaptureEngine.filterAuxiliaryWindows([chromeBar],
                                                 screenFrames: [chromeScreen],
                                                 primaryHeight: chromeScreen.maxY),
            [10]
        )
        let normalA = geometry(20, 502, CGRect(x: 80, y: 120, width: 720, height: 620))
        let normalB = geometry(21, 502, CGRect(x: 760, y: 180, width: 620, height: 580))
        expectWindowIDs(
            "同应用两个普通窗口：两个都留",
            CaptureEngine.filterAuxiliaryWindows([normalA, normalB],
                                                 screenFrames: [chromeScreen],
                                                 primaryHeight: chromeScreen.maxY),
            [20, 21]
        )
        let otherAppMain = geometry(31, 999, chromeMain.frame)
        expectWindowIDs(
            "不同进程：另一个应用再大也不能替这个应用决定去留",
            CaptureEngine.filterAuxiliaryWindows([chromeBar, otherAppMain],
                                                 screenFrames: [chromeScreen],
                                                 primaryHeight: chromeScreen.maxY),
            [10, 31]
        )

        noteGroup("── 截图完成反馈（菜单栏先出现，预览随后进场）")
        let flashVisible = StatusBarController.flashDuration >= 0.5
        let previewWaits = ShotCoordinator.previewDelayAfterFeedback > 0
            && ShotCoordinator.previewDelayAfterFeedback < StatusBarController.flashDuration
        if !flashVisible { failures += 1 }
        if !previewWaits { failures += 1 }
        print("  \(flashVisible ? "✓" : "✗") 完成态至少停留 0.5 秒"
              + String(format: "（当前 %.2f 秒）", StatusBarController.flashDuration))
        print("  \(previewWaits ? "✓" : "✗") 预览延迟落在完成态之内"
              + String(format: "（延迟 %.2f 秒 < 完成态 %.2f 秒）",
                       ShotCoordinator.previewDelayAfterFeedback,
                       StatusBarController.flashDuration))

        noteGroup("── 文件名模板清洗（存出去的名字必须能用、能找着）")
        func expectName(_ label: String, _ got: String, _ want: String) {
            let ok = got == want
            if !ok { failures += 1 }
            print(String(format: "  %@ %@\n      得到「%@」　期望「%@」",
                         ok ? "✓" : "✗", label as NSString, got as NSString, want as NSString))
        }
        expectName("常规名字原样通过",
                   SettingsStore.sanitize("Grabi-20261005"), "Grabi-20261005")
        expectName("路径分隔符和冒号换成 -",
                   SettingsStore.sanitize("a/b\\c:d"), "a-b-c-d")
        expectName("前导点去掉（否则变成隐藏文件，用户只会以为没截到）",
                   SettingsStore.sanitize("..截图"), "截图")
        expectName("尾部的点去掉（否则加扩展名后是 名字..png）",
                   SettingsStore.sanitize("名字..."), "名字")
        expectName("整串都是非法字符时退回默认名",
                   SettingsStore.sanitize("   "), "Grabi")
        expectName("超长按 UTF-8 字节预算截断（200 个汉字 → 60 个 = 180 字节）",
                   SettingsStore.sanitize(String(repeating: "字", count: 200)),
                   String(repeating: "字", count: 60))
        expectName("截断不劈开 emoji（宁可少留一个字）",
                   SettingsStore.sanitize(String(repeating: "字", count: 59) + "👍"),
                   String(repeating: "字", count: 59))
        let rendered = SettingsStore.renderedName("{type}-{date}", type: "window")
        let expandedOK = rendered.hasPrefix("window-")
            && !rendered.contains("{")
            && rendered.dropFirst(7).count == 8
            && rendered.dropFirst(7).allSatisfy(\.isNumber)
        if !expandedOK { failures += 1 }
        print("  \(expandedOK ? "✓" : "✗") 占位符展开：{type}-{date} → 「\(rendered)」")

        noteGroup("── 模板：没看懂的占位符要说出来，动了哪几刀要只说真动过的")
        let unknownCases: [(String, [String])] = [
            ("{date}-{time}", []),
            ("Grabi-{datetime}-{type}", []),
            ("a-{datetme}-b", ["{datetme}"]),
            ("{foo}{bar}{foo}", ["{foo}", "{bar}"]),
            ("{}", ["{}"]),
            ("没有花括号", []),
            ("{没闭合", [])
        ]
        for (pattern, want) in unknownCases {
            let got = SettingsStore.unknownPlaceholders(in: pattern)
            let ok = got == want
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") 「\(pattern)」→ \(got.isEmpty ? "没有未知占位符" : got.joined(separator: "、"))"
                  + (ok ? "" : "　期望 \(want)"))
        }
        // 面板那行提示是从 knownPlaceholders 拼的；实现和表一旦分家这条就红
        let tableOK = SettingsStore.knownPlaceholders
            .allSatisfy { SettingsStore.unknownPlaceholders(in: $0).isEmpty }
        if !tableOK { failures += 1 }
        print("  \(tableOK ? "✓" : "✗") 认识的占位符不会被自己的检查报成未知")

        let issueCases: [(String, [String])] = [
            (String(repeating: "字", count: 200), ["超长已截断"]),
            ("a/b:c", ["非法字符已换成 -"]),
            (".隐藏", ["开头的点已去掉（否则成了隐藏文件）"]),
            ("尾巴.", ["末尾的点已去掉"]),
            ("Grabi-{date}", []),
            ("{datetme}-{date}", ["未知占位符 {datetme} 会原样写进文件名"])
        ]
        for (pattern, want) in issueCases {
            let got = SettingsStore.templateIssues(pattern: pattern, type: "region")
            let ok = got == want
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") 「\(pattern.prefix(12))」→ \(got.isEmpty ? "原样不动" : got.joined(separator: "，"))"
                  + (ok ? "" : "　期望 \(want)"))
        }

        noteGroup("── 失败反馈（每条错误都要给出下一步）")
        let failures0: [CaptureError] = [
            .noScreenRecording, .noDisplay, .windowGone, .emptySelection, .cropFailed,
            .writeFailed("磁盘已满")
        ]
        for error in failures0 {
            let description = error.errorDescription ?? ""
            let hint = error.recoveryHint
            let title = error.recoveryTitle
            var problems: [String] = []
            if case .emptySelection = error {
                // 用户自己放弃的，不该弹任何东西
                if hint != nil || title != nil { problems.append("主动放弃还给出恢复动作") }
            } else {
                if let hint {
                    if hint.isEmpty { problems.append("恢复说明是空的") }
                    if hint.count > 60 { problems.append("恢复说明 \(hint.count) 字，太长") }
                    if description.contains(hint) { problems.append("和错误本身说的是同一句") }
                } else {
                    problems.append("没有恢复说明")
                }
                if (error.recovery != nil) != (title != nil) {
                    problems.append("有动作却没按钮，或有按钮没动作")
                }
            }
            let ok = problems.isEmpty
            if !ok { failures += 1 }
            let action: String
            switch error.recovery {
            case .openPermissionSettings: action = "去系统设置"
            case .openSettings:           action = "开设置窗"
            case .retry:                  action = "重试"
            case .none:                   action = "无"
            }
            print("  \(ok ? "✓" : "✗") \(description)　·　动作 \(action)"
                  + "　按钮「\(title ?? "—")」"
                  + (ok ? "" : "　← \(problems.joined(separator: "，"))"))
        }
        let mappingOK: [Bool] = [
            CaptureError.noScreenRecording.recovery == .openPermissionSettings,
            CaptureError.noScreenRecording.recoveryTitle == "去开启权限",
            CaptureError.writeFailed("x").recovery == .openSettings,
            CaptureError.writeFailed("x").recoveryTitle == "换个保存位置",
            CaptureError.noDisplay.recovery == .retry,
            CaptureError.noDisplay.recoveryTitle == "再试一次"
        ]
        if !mappingOK.allSatisfy({ $0 }) { failures += 1 }
        print("  \(mappingOK.allSatisfy({ $0 }) ? "✓" : "✗") 动作与按钮一一对上（权限 / 保存位置 / 重试）")

        noteGroup("── 自启动不变式（保活 ⇒ 开机自启）+ 一条键管一对偏好")
        let table: [(keep: Bool, launch: Bool, want: Bool)] = [
            (false, false, false),
            (false, true,  true),
            (true,  false, true),   // 默认值恰好是这一行：保活开、自启没存过
            (true,  true,  true)
        ]
        var tableBad: [String] = []
        for row in table {
            let got = SettingsStore.impliedLaunchAtLogin(keepAlive: row.keep,
                                                         launchAtLogin: row.launch)
            if got != row.want {
                tableBad.append("保活=\(row.keep) 自启=\(row.launch) → \(got)，应为 \(row.want)")
            }
        }
        if !tableBad.isEmpty { failures += 1 }
        print("  \(tableBad.isEmpty ? "✓" : "✗") 真值表 4 行"
              + (tableBad.isEmpty ? "全部一致" : "：\(tableBad.joined(separator: "；"))"))

        // 界面上这两条并成了**一条**勾选框（菜单栏和设置窗各一条，两处同名同义）。
        // 并起来的风险从"两处各写一遍顺手改另一条"变成"写的那半漏了"，所以
        // 那份共用的判断单独查：按一次，两条必须一起动，一条都不许多。
        let pairChecks: [(String, Bool)] = [
            ("按下开关：两条一起开",
                SettingsStore.autoStartPair(turningOn: true) == (true, true)),
            ("再按一次：两条一起关",
                SettingsStore.autoStartPair(turningOn: false) == (false, false)),
            ("反向对照：不存在「开一条留一条」的第三种输出",
                [true, false].allSatisfy { on in
                    let got = SettingsStore.autoStartPair(turningOn: on)
                    return got.launchAtLogin == got.keepAlive
                }),
            ("菜单和设置窗共用同一份名字（名字里两条核心名都在）",
                ToggleTitles.autoStartPair.contains(ToggleTitles.launchAtLogin)
                    && ToggleTitles.autoStartPair.contains(ToggleTitles.keepAlive))
        ]
        for (label, ok) in pairChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        noteGroup("── 自启动状态行（想要自启却没生效，不许再写成一行灰色脚注）")
        typealias Advisory = AutoStartManager.RunStateAdvisory
        let off = AutoStartManager.Mechanism.none
        let agent = AutoStartManager.Mechanism.keepAliveAgent
        let stateRows: [(label: String, wanted: Bool, mechanism: AutoStartManager.Mechanism,
                         approval: Bool, location: String?, warning: Bool, action: Advisory.Action)] = [
            ("没要求自启 · 机制未启用", false, off, false, nil, false, .none),
            ("要求了 · 系统没登记", true, off, false, nil, true, .reRegister),
            ("要求了 · 等用户点确认", true, agent, true, nil, true, .openLoginItems),
            ("要求了 · app 不在标准目录", true, agent, false, "不在 /Applications。", true, .none),
            ("要求了 · 一切正常", true, agent, false, nil, false, .none)
        ]
        for row in stateRows {
            let got = AutoStartManager.advisory(wanted: row.wanted, mechanism: row.mechanism,
                                                statusText: "状态文字", needsApproval: row.approval,
                                                locationWarning: row.location)
            var bad: [String] = []
            if got.isWarning != row.warning {
                bad.append("醒目度 \(got.isWarning)，应为 \(row.warning)")
            }
            if got.action != row.action { bad.append("出路不对，得到 \(got.action)") }
            // 有出路就必须有标题：一个不写字的按钮比没有按钮更糟
            if got.action != .none, (got.actionTitle ?? "").isEmpty {
                bad.append("有出路却没按钮标题")
            }
            // 醒目必须带"所以怎么了"，不醒目不许吓唬人
            if got.isWarning != got.text.contains("⚠︎") {
                bad.append(got.isWarning ? "变橙却没写清楚后果" : "没事却挂了 ⚠︎")
            }
            if !bad.isEmpty { failures += 1 }
            print("  \(bad.isEmpty ? "✓" : "✗") \(row.label)　\(got.isWarning ? "橙" : "灰")"
                  + (got.actionTitle.map { "　按钮「\($0)」" } ?? "")
                  + (bad.isEmpty ? "" : "　← \(bad.joined(separator: "；"))"))
        }

        noteGroup("── 自启动登记决策（成功只能以系统回读为准，「没抛异常」不算）")
        final class FakeService {
            var armed = false
            var unregisterThrows = false
            var registerThrows = false
            var registerTakes = true      // false = 系统收下请求但没真挂上
            var unregisterCalls = 0
            var registerCalls = 0

            func run(force: Bool) -> AutoStartManager.RegistrationOutcome {
                AutoStartManager.register(
                    force: force,
                    armedBefore: armed,
                    unregister: { [self] in
                        unregisterCalls += 1
                        if unregisterThrows {
                            throw NSError(domain: NSCocoaErrorDomain, code: 513,
                                          userInfo: [NSLocalizedDescriptionKey: "没有权限"])
                        }
                        armed = false
                    },
                    register: { [self] in
                        registerCalls += 1
                        if registerThrows {
                            throw NSError(domain: NSCocoaErrorDomain, code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "被系统拒绝"])
                        }
                        if registerTakes { armed = true }
                    },
                    armedAfter: { [self] in armed })
            }
        }
        let registrationCases: [(String, Bool, Bool, Bool, Bool, Bool,
                                 AutoStartManager.RegistrationOutcome, Int, Int)] = [
            // 标题, 已挂着, 要求force, 注销抛错, 注册抛错, 注册落空, 期望结果, 期望注销次数, 期望注册次数
            ("没催 force · 系统已挂着", true, false, false, false, false, .alreadyArmed, 0, 0),
            ("没催 force · 还没登记", false, false, false, false, true, .registered, 0, 1),
            ("催了 force · 正常刷新", true, true, false, false, true, .refreshed, 1, 1),
            ("催了 force · 注销失败", true, true, true, false, false,
             .failed("没能注销旧的登记：没有权限"), 1, 0),
            ("注册直接被拒", false, false, false, true, false,
             .failed("注册失败：被系统拒绝"), 0, 1)
        ]
        for (label, armed, force, unregisterThrows, registerThrows, registerTakes,
             want, wantUnregister, wantRegister) in registrationCases {
            let fake = FakeService()
            fake.armed = armed
            fake.unregisterThrows = unregisterThrows
            fake.registerThrows = registerThrows
            fake.registerTakes = registerTakes
            let got = fake.run(force: force)
            var bad: [String] = []
            if got != want { bad.append("结果 \(got)，应为 \(want)") }
            if fake.unregisterCalls != wantUnregister {
                bad.append("注销调了 \(fake.unregisterCalls) 次，应为 \(wantUnregister)")
            }
            if fake.registerCalls != wantRegister {
                bad.append("注册调了 \(fake.registerCalls) 次，应为 \(wantRegister)")
            }
            if case .failed(let reason) = got {
                // 这句话会直接进对话框：不能空、不能换行（换行交给模板去拼）
                if reason.isEmpty || reason.contains("\n") { bad.append("失败原因不能给用户看") }
            }
            if !bad.isEmpty { failures += 1 }
            print("  \(bad.isEmpty ? "✓" : "✗") \(label)"
                  + (bad.isEmpty ? "" : "　← \(bad.joined(separator: "；"))"))
        }
        // 单独钉一条：注册"成功"但系统没留下记录时，绝不能回报成功
        let swallowed = FakeService()
        swallowed.registerTakes = false
        let swallowedOutcome = swallowed.run(force: false)
        var readbackOK = false
        if case .failed = swallowedOutcome { readbackOK = true }
        if !readbackOK { failures += 1 }
        print("  \(readbackOK ? "✓" : "✗") 注册请求被系统吞掉 → 回读没挂着就是失败"
              + (readbackOK ? "" : "　← 得到了 \(swallowedOutcome)"))

        noteGroup("── 键盘那一轨（⏎ 采用候选 / 空格 整屏 / Esc 取消）")
        // 覆盖层以前只认 Esc 和空格：用空格切到整屏候选之后，**还得去碰鼠标**才截得下去。
        // 现在 ⏎ 采用当前候选。方向键微调这一轨做过又拆掉了 —— 调好的一格会被下一次
        // 鼠标移动吞掉，而鼠标几乎一定在动；一个"按了会被撤销"的键比没有它更让人以为坏了。
        // 这里查的是「按下什么键 = 做什么事」这张表本身（纯函数）；
        // 「键进不进得来这个视图」在 --ui-render 里用真投递查（要一个真的窗口）。
        let kbdChecks: [(String, Bool)] = [
            ("⏎ 两个键码（主键盘 36 / 小键盘 76）都是采用候选",
             OverlayView.key(forKeyCode: 36) == .adopt
                 && OverlayView.key(forKeyCode: 76) == .adopt),
            ("Esc 取消、空格整屏",
             OverlayView.key(forKeyCode: 53) == .cancel
                 && OverlayView.key(forKeyCode: 49) == .fullscreen),
            ("反向对照：四个方向键已经不是覆盖层的键了（全部交回系统，不留半套）",
             OverlayView.key(forKeyCode: 123) == .other
                 && OverlayView.key(forKeyCode: 124) == .other
                 && OverlayView.key(forKeyCode: 125) == .other
                 && OverlayView.key(forKeyCode: 126) == .other),
            ("表上没登记的键一律 .other（按 A、按 Z 都不该被覆盖层吞掉）",
             OverlayView.key(forKeyCode: 0) == .other
                 && OverlayView.key(forKeyCode: 6) == .other),
            ("静止提示条说得出「怎么选、怎么定、怎么退」（⏎ / Esc / 拖动都在）",
             OverlayView.hintText.contains("⏎") && OverlayView.hintText.contains("Esc")
                 && OverlayView.hintText.contains("拖动")),
            ("拖拽那一组说得出 ⇧ 与 ，而且两个都写明是「按住」",
             OverlayView.dragHintText.contains("⇧") && OverlayView.dragHintText.contains("⌥")
                 && OverlayView.dragHintText.filter { $0 == "按" }.count == 2),
            ("反向对照：拆掉的键不许留在文案里（两处都不许再提方向键）",
             !OverlayView.hintText.contains("方向键")
                 && !OverlayView.dragHintText.contains("方向键")),
            ("反向对照：瘦身不是把字搬家 —— 静止那条里不许再出现修饰键",
             !OverlayView.hintText.contains("⇧") && !OverlayView.hintText.contains("⌥")),
            ("两条加起来仍然短于原来那一条 116 字（真的少说了话）",
             OverlayView.hintText.count + OverlayView.dragHintText.count < 116),
        ]
        for (label, ok) in kbdChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        noteGroup("── 浮层层级顺序（以前只写在注释里，注释不会失败）")
        let levels = ShotLevels.orderedBottomToTop
        var stackBad: [String] = []
        for index in 1..<levels.count where levels[index - 1].1.rawValue >= levels[index].1.rawValue {
            stackBad.append("\(levels[index - 1].0) 没有低于 \(levels[index].0)")
        }
        if !stackBad.isEmpty { failures += 1 }
        print("  \(stackBad.isEmpty ? "✓" : "✗") 从低到高："
              + levels.map(\.0).joined(separator: " < ")
              + (stackBad.isEmpty ? "" : "　← \(stackBad.joined(separator: "；"))"))

        noteGroup("── 工具栏落位（预览贴边、小屏、副屏原点不为 0 都必须留在可见区里）")
        let placementScreen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let placements: [(String, NSRect, NSSize, NSRect)] = [
            ("预览居中", NSRect(x: 400, y: 300, width: 500, height: 400),
             NSSize(width: 460, height: 42), placementScreen),
            ("预览贴屏底·下方放不下", NSRect(x: 400, y: 60, width: 500, height: 400),
             NSSize(width: 460, height: 42), placementScreen),
            ("预览贴屏顶·上下都放不下", NSRect(x: 400, y: 433, width: 500, height: 442),
             NSSize(width: 460, height: 42), placementScreen),
            ("小屏 800×500", NSRect(x: 120, y: 60, width: 560, height: 380),
             NSSize(width: 620, height: 42), NSRect(x: 0, y: 0, width: 800, height: 500)),
            ("工具栏比屏还宽（窄副屏 / Sidecar）", NSRect(x: 100, y: 100, width: 500, height: 300),
             NSSize(width: 900, height: 42), NSRect(x: 0, y: 0, width: 800, height: 500)),
            ("工具栏比屏还高", NSRect(x: 100, y: 100, width: 500, height: 300),
             NSSize(width: 460, height: 620), NSRect(x: 0, y: 0, width: 1440, height: 400)),
            ("右侧副屏（原点 1440）", NSRect(x: 1600, y: 200, width: 500, height: 400),
             NSSize(width: 460, height: 42), NSRect(x: 1440, y: 0, width: 1920, height: 1042))
        ]
        for (label, current, size, visible) in placements {
            let origin = InlinePreviewController.toolbarOrigin(current: current, size: size,
                                                               visible: visible, gap: 10)
            let rect = NSRect(origin: origin, size: size)
            // 落点必须在可见区内（保证抓得到），而且不许从左边/下边漏出去。
            // 右边和上边只在工具栏比屏还宽时允许溢出 —— 那种情况无处可放。
            let ok = visible.contains(origin) && rect.minX >= visible.minX && rect.minY >= visible.minY
            if !ok { failures += 1 }
            print(String(format: "  %@ %-24@ 落点 (%4.0f, %4.0f)　工具栏 %.0f×%.0f　可见区原点 %.0f　宽 %.0f",
                         ok ? "✓" : "✗", label as NSString, origin.x, origin.y,
                         size.width, size.height, visible.minX, visible.width))
        }

        noteGroup("── 倍率解析（文件里的 DPI 该跟「被截的那块屏」走，不是当前有键盘焦点的那块）")
        let retina = ScreenGeometry.Display(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                            scale: 2)
        // 两块屏之间留空档是系统允许的真实摆法（高度不同、顶部对齐就会出现）：
        // 跨过去拉的选区中心谁也不落在里面，只能按重叠面积判。
        let external = ScreenGeometry.Display(frame: NSRect(x: 1500, y: 0, width: 1920, height: 1080),
                                             scale: 1)
        let pair = [retina, external]
        let scaleCases: [(String, NSRect, [ScreenGeometry.Display], CGFloat)] = [
            ("主屏上的选区", NSRect(x: 100, y: 100, width: 300, height: 200), pair, 2),
            ("外接 1x 屏上的选区", NSRect(x: 1600, y: 300, width: 300, height: 200), pair, 1),
            ("跨屏·中心落空档，外接占大头", NSRect(x: 1400, y: 300, width: 160, height: 200), pair, 1),
            ("跨屏·中心落空档，主屏占大头", NSRect(x: 1390, y: 300, width: 140, height: 200), pair, 2),
            ("显示器都拔了", NSRect(x: 500, y: 500, width: 100, height: 100), [], 2)
        ]
        for (label, rect, displays, want) in scaleCases {
            let got = ScreenGeometry.scale(of: rect, among: displays)
            if got != want { failures += 1 }
            print("  \(got == want ? "✓" : "✗") \(label) → @\(got)x　写进文件的 DPI \(ScreenGeometry.dpi(scale: got))（期望 @\(want)x）")
        }
        let dpiRounding = [ScreenGeometry.dpi(scale: 2), ScreenGeometry.dpi(scale: 1),
                           ScreenGeometry.dpi(scale: 1.5)]
        if dpiRounding != [144, 72, 108] { failures += 1 }
        print("  \(dpiRounding == [144, 72, 108] ? "✓" : "✗") DPI 换算 2x/1x/1.5x → \(dpiRounding.map(String.init).joined(separator: "/"))")

        noteGroup("── DPI 往返（裁剪、改选区重截都走覆盖写，元数据不能在那一步丢掉）")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Grabi-dpi-\(UUID().uuidString)")
        let shot = scratch.appendingPathComponent("shot.png")
        var dpiBefore = 0, dpiAfter = 0
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            // 造一张标注 144dpi 的图，模拟「刚从 retina 屏截下来、已经落盘」的状态
            if let dest = CGImageDestinationCreateWithURL(shot as CFURL, "public.png" as CFString, 1, nil),
               let picture = quadrantImage(side: 64) {
                let head: [CFString: Any] = [kCGImagePropertyDPIWidth: 144,
                                             kCGImagePropertyDPIHeight: 144]
                CGImageDestinationAddImage(dest, picture, head as CFDictionary)
                if CGImageDestinationFinalize(dest) {
                    dpiBefore = Int(ImageWriter.dpiWidthForSelfTest(of: shot) ?? 0)
                }
            }
            // 覆盖一次，等价于就地预览调整选区后重新截图并保存
            if let crop = quadrantImage(side: 32) {
                try ImageWriter.overwrite(crop, at: shot)
                dpiAfter = Int(ImageWriter.dpiWidthForSelfTest(of: shot) ?? 0)
            }
            try? FileManager.default.removeItem(at: scratch)
        } catch {
            print("  ✗ 临时目录写不了：\(error.localizedDescription)")
            failures += 1
        }
        // 两头都要卡住：写进去得是 144（证明读的路子真的通），覆盖后还得是 144
        // （改之前这里是 72 —— 裁一刀图就凭空大一倍）。
        if dpiBefore == 144 && dpiAfter == 144 {
            print("  ✓ 覆盖写前 144dpi → 覆盖写后 144dpi")
        } else {
            failures += 1
            print("  ✗ 覆盖写前 \(dpiBefore)　覆盖写后 \(dpiAfter)（两头都该是 144）")
        }

        noteGroup("── 标注（画在屏幕上的那一笔，必须就是存进文件的那一笔）")
        let inkBox = NSRect(x: 0, y: 0, width: 200, height: 100)
        func shapePath(_ shape: Ink.Shape, _ from: CGPoint, _ to: CGPoint) -> NSBezierPath? {
            Ink.path(for: Ink.Stroke(tool: .shape(shape), points: [from, to],
                                     color: .systemRed, width: 0.015), in: inkBox)
        }
        var inkChecks: [(String, Bool)] = []

        // 往任意方向拖都该得到同一个矩形：按下点是一个角、当前点是对角，谁在左上无关。
        let forward = shapePath(.rectangle, CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.3))?.bounds
        let backward = shapePath(.rectangle, CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.8))?.bounds
        let wantRect = NSRect(x: 40, y: 30, width: 120, height: 50)
        inkChecks.append(("反向拖拽翻正成同一个矩形　得到 "
                          + "\(forward.map(NSStringFromRect) ?? "nil") / "
                          + "\(backward.map(NSStringFromRect) ?? "nil")　期望 "
                          + NSStringFromRect(wantRect),
                          forward == wantRect && backward == wantRect))

        let ellipse = shapePath(.ellipse, CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9))?.bounds
        // 椭圆的 bounds 是贝塞尔控制点算出来的（κ = 0.5522847…），末位差 1e-14 是它的
        // 本来面目，不是 bug —— 这里按相等判会红一条永远修不掉的。
        let wantEllipse = NSRect(x: 20, y: 10, width: 160, height: 80)
        let ellipseOK = ellipse.map {
            abs($0.minX - wantEllipse.minX) < 0.001 && abs($0.minY - wantEllipse.minY) < 0.001
                && abs($0.maxX - wantEllipse.maxX) < 0.001 && abs($0.maxY - wantEllipse.maxY) < 0.001
        } ?? false
        inkChecks.append(("椭圆铺满那两个角确定的矩形　得到 "
                          + (ellipse.map(NSStringFromRect) ?? "nil")
                          + "　期望 " + NSStringFromRect(wantEllipse) + "（±0.001）", ellipseOK))

        // 箭头的两条须不许甩出图外：甩出去那截在合成图里会被裁掉，
        // 用户看到的就是"箭头怎么缺个头"。
        let arrow = shapePath(.arrow, CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.95, y: 0.95))
        let arrowBounds = arrow?.bounds ?? .null
        inkChecks.append(("箭头连须都留在图内　得到 \(NSStringFromRect(arrowBounds))"
                          + "（框 \(NSStringFromRect(inkBox))）",
                          arrowBounds.minX >= -0.01 && arrowBounds.minY >= -0.01
                              && arrowBounds.maxX <= inkBox.maxX + 0.01
                              && arrowBounds.maxY <= inkBox.maxY + 0.01))

        let onePointPen = Ink.path(for: Ink.Stroke(tool: .pen, points: [CGPoint(x: 0.5, y: 0.5)],
                                                  color: .systemRed, width: 0.015), in: inkBox)
        inkChecks.append(("画笔只点一下、形状两角重合、零宽矩形：三种都别收进历史",
                          onePointPen == nil
                              && shapePath(.rectangle, CGPoint(x: 0.5, y: 0.5),
                                           CGPoint(x: 0.5, y: 0.5)) == nil
                              && shapePath(.rectangle, CGPoint(x: 0.5, y: 0.2),
                                           CGPoint(x: 0.5, y: 0.8)) == nil))

        // 线宽那条链：屏幕上 3pt → 归一化 → 存进 2× 的图是几 px。
        let onFile = Ink.normalizedWidth(viewWidth: 520) * 1040
        inkChecks.append(("屏幕上 \(Ink.onScreenWidth)pt 的笔存进 2× 图是 "
                          + String(format: "%.0f", onFile) + "px　·　宽度只有一个出处",
                          abs(onFile - Ink.onScreenWidth * 2) < 0.001))

        // 四种形状**全部摆在工具栏上**，一颗按钮一种。
        //
        // 以前是一颗按钮循环切：第一下点下去得到的是"下一种"，不是眼睛看到的那一种，
        // 想画第四种要点三下。现在点哪颗就是哪颗，所以这条断言从"循环转得回来"
        // 改成"四颗各自独立、顺序就是按钮顺序"—— 循环这个概念在这儿已经不存在了，
        // 再留一条查循环的断言就是查一份没人用的东西。
        let shapes = Ink.Shape.allCases
        let listedOK = shapes == [.rectangle, .ellipse, .arrow, .line]
            && Set(shapes.map(\.name)).count == 4 && Set(shapes.map(\.symbol)).count == 4
        inkChecks.append(("形状四种各占一颗：名字、图标都不重，顺序就是按钮从左到右", listedOK))

        // ⇧ 上规矩。判的是**视觉空间**里的正方形 / 45°，不是归一化空间里的 ——
        // 拿归一化坐标比相等的话，一张 16:9 的图上按 ⇧ 会"看起来没生效"而断言照样绿。
        let wide = 16.0 / 9.0
        let square = Ink.constrained(first: .zero, to: CGPoint(x: 0.2, y: 0.6),
                                     tool: .shape(.rectangle), shift: true, aspect: wide)
        let diag = Ink.constrained(first: .zero, to: CGPoint(x: 0.4, y: 0.35),
                                   tool: .shape(.arrow), shift: true, aspect: wide)
        let near: (CGFloat, CGFloat) -> Bool = { abs($0 - $1) < 0.001 }
        let shiftChecks: [(String, Bool)] = [
            ("⇧ 拖出来的是**视觉上**的正方形（宽 px == 高 px，16:9 的图）",
                near(square.x * wide, square.y)),
            ("⇧ 之后往哪边拖还在哪边（符号没被「取大的那个」吃掉）",
                square.x > 0 && square.y > 0),
            ("⇧ 把箭头吸到 45° 的整数倍（视觉角度）",
                near(atan2(diag.y, diag.x * wide), Double.pi / 4)),
            ("没按 ⇧ 一个数都不许动（约束只在按着的时候存在）",
                Ink.constrained(first: .zero, to: CGPoint(x: 0.3, y: 0.1),
                                tool: .shape(.rectangle), shift: false, aspect: wide)
                    == CGPoint(x: 0.3, y: 0.1)),
            ("画笔不吃 ⇧：自由圈画没有规矩可锁",
                Ink.constrained(first: .zero, to: CGPoint(x: 0.3, y: 0.1),
                                tool: .pen, shift: true, aspect: wide)
                    == CGPoint(x: 0.3, y: 0.1)),
            ("反向对照：不按 ⇧ 的那个 0.2×0.6 确实不是正方形（上一条不是恒等）",
                !near(0.2 * wide, 0.6))
        ]
        inkChecks.append(contentsOf: shiftChecks)

        let names = InlinePreviewController.inkColors.map(\.name)
        inkChecks.append(("颜色 " + String(names.count) + " 档且互不重名　读到 "
                          + names.joined(separator: "、"),
                          names.count == 6 && Set(names).count == 6))

        // 「清空」得能整批还回来：一笔一笔撤到第十笔不是撤销，是体力活。
        // 而一个没有退路的清除，和这个仓库里被拆掉的那些"不可逆动作"是同一类。
        let layer = InkLayer(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        func dot(_ x: CGFloat, _ y: CGFloat) -> Ink.Stroke {
            Ink.Stroke(tool: .pen, points: [CGPoint(x: x, y: y), CGPoint(x: x + 0.1, y: y + 0.1)],
                       color: .systemRed, width: 0.01)
        }
        var layerBad: [String] = []
        for index in 0..<3 { layer.addStrokeForSelfTest(dot(0.1 * CGFloat(index), 0.2)) }
        if layer.strokes.count != 3 || !layer.canClear { layerBad.append("三笔没进去") }
        layer.clearAll()
        // 清空之后「撤销」不许变灰 —— 那正是"还有东西可以还"的信号。
        if !layer.strokes.isEmpty || !layer.canUndo { layerBad.append("清空后把可撤说成没了") }
        layer.undo()
        if layer.strokes.count != 3 { layerBad.append("一次撤销没把整批还回来（读到 \(layer.strokes.count)）") }
        layer.undo()
        if layer.strokes.count != 2 { layerBad.append("还完一批之后该回到一笔一笔撤（读到 \(layer.strokes.count)）") }
        // 清空之后又画了一笔：那一批的还账机会到此为止，不然 ⌘Z 会"复活"
        // 一张用户已经明确说不要的图。
        layer.clearAll()
        layer.addStrokeForSelfTest(dot(0.9, 0.9))
        layer.undo()
        if !layer.strokes.isEmpty { layerBad.append("新画的一笔没盖掉清空那批的还账机会") }
        // 线宽那一档走的是同一个换算：粗 = 5pt，存进 2× 的图就是 10px。
        let thick = Ink.normalizedWidth(viewWidth: 200, screenWidth: 5) * 400
        if abs(thick - 10) > 0.001 { layerBad.append("5pt 存进 2× 图读到 \(thick)px") }
        if !layerBad.isEmpty { failures += 1 }
        print("  \(layerBad.isEmpty ? "✓" : "✗") 清空 = 整批可还（撤一次全回来、再撤回到一笔一笔、"
              + "画新的一笔就翻篇）　·　线宽 5pt 存进 2× 图 = 10px"
              + (layerBad.isEmpty ? "" : "　← \(layerBad.joined(separator: "；"))"))


        // tooltip 上那句键必须真按得出去，而且不许抢系统的 ⌘P / ⌘S / ⌘W。
        let hintOK = InkAction.shortcuts.allSatisfy { row in
            InkAction.action(for: row.key, shift: row.shift) == row.action
                && row.action.keyHint.contains(row.key.uppercased())
                && row.action.keyHint.contains("⌘")
        }
        inkChecks.append(("三条标注键：表里写的按得出去、tooltip 念得出同一个键", hintOK))
        inkChecks.append(("反向对照：没按 ⇧ 的 ⌘P / ⌘S / ⌘W 一条都没抢（那是打印、保存、关窗）",
                          InkAction.action(for: "p", shift: false) == nil
                              && InkAction.action(for: "s", shift: false) == nil
                              && InkAction.action(for: "w", shift: false) == nil))

        for (label, ok) in inkChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        noteGroup("── 落盘时机（默认不落盘也不进剪贴板，按「保存」写文件、按「复制图片」进剪贴板）")
        // 现在只有一条路径：截图先进入就地预览，只有用户明确按「保存」才写文件。
        // 静默截图和“不显示就地预览”两个旧分支已经移除，不能再从代码里复活。
        let timingChecks: [(String, Bool)] = [
            ("截图后不会自动落盘（唯一入口是预览面板上的「保存」）",
             !ShotCoordinator.savesImmediately()),
            // 设置面板那两行说的必须就是这张表。话和事分家是骗人，
            // 而它偏偏写在用户最信的地方（"保存"那一栏）。
            ("设置里那两行说得出「剪贴板」和「保存」",
             SettingsWindowController.saveTimingLines.joined()
                 .contains("剪贴板") && SettingsWindowController.saveTimingLines.joined()
                 .contains("保存")),
            // 「保留 / 丢弃」那一对的两句 tooltip：没落盘时不许提废纸篓（磁盘上
            // 根本没有东西），落盘之后必须提（那才是可恢复的）。
            ("没保存时「丢弃」不承诺废纸篓",
             !InlinePreviewController.keepDiscardTitles(saved: false).discardTip
                 .contains("废纸篓")),
            ("保存后「丢弃」说的是移到废纸篓，不是永久删除",
             InlinePreviewController.keepDiscardTitles(saved: true).discardTip
                 .contains("废纸篓")),
            ("两种状态下「保存」那颗按钮的字不一样（已保存 = 禁用态）",
             InlinePreviewController.keepDiscardTitles(saved: false).keep
                 != InlinePreviewController.keepDiscardTitles(saved: true).keep),
            ("图没落盘时 .txt 只预告、不谎称已存",
             !ImageWriter.ocrTextPendingStatus.contains("已存")
                 && ImageWriter.ocrTextPendingStatus.contains("保存")),
            // 命令行那份说明书是这条规则的第三个出口（设置面板、tooltip、--help）。
            // 分家最爱发生在"顺手写的一句说明"里 —— 所以让它也上一次账。
            ("--help 说的和这张表一致（面板上手动保存 / 复制）",
             usageText().contains("保存") && usageText().contains("复制图片")
                 && !usageText().contains("静默截图"))
        ]
        for (label, ok) in timingChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        // 关面板的原因 → 要不要弹「已保存」。这条规则以前是一条布尔 `suppressFileToast`，
        // 复制、点外部、换下一张全挤在同一个桶里，于是"复制后点一下别处"会弹
        // 「已保存」—— 用户以为自己存了，磁盘上却什么都没有。四种原因各钉一遍。
        let reasonChecks: [(String, Bool)] = [
            ("只有「保存成功」才弹带文件名的角标",
             ShotCoordinator.showsSavedToast(for: .saved)),
            ("复制后关面板不报「已保存」（那是复制，不是保存）",
             !ShotCoordinator.showsSavedToast(for: .copied)),
            ("点面板外 / Esc / 丢弃关面板不报「已保存」",
             !ShotCoordinator.showsSavedToast(for: .cancelled)),
            ("换下一张截图顶掉上一张时不报「已保存」",
             !ShotCoordinator.showsSavedToast(for: .replaced))
        ]
        for (label, ok) in reasonChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        noteGroup("── 钉在屏幕上的预览（拖走之后点别处不许收走，只能滚轮调大小）")
        // 这一组守两件互相拉扯的事：
        // ① 刚截完那一瞬，点别处收走最顺手（用户多半要立刻去粘贴）；
        // ② 拖走 / 缩放过之后，这张变成"我正在看的东西"，点任何地方都不该让它消失。
        // 门槛一旦写反（比如钉住之后还照旧收走），用户就会遇到"一动鼠标图就没了"。
        let pinnedChecks: [(String, Bool)] = [
            ("刚浮出时不算钉住（点别处收走这条路还在）",
             !InlinePreviewController.startsPinned),
            ("拖走 / 滚轮缩放之后算钉住（点别处不再收走）",
             InlinePreviewController.closesOnClickAway(isPinned: false)
                 && !InlinePreviewController.closesOnClickAway(isPinned: true)),
            // 边框手柄只服务未拖走那一段；固定态必须关掉，避免改面板 frame
            // 后图片区域和窗口尺寸脱节，露出黑边。滚轮缩放是固定态唯一入口。
            ("未拖走时允许拖边框手柄重新框选",
             InlinePreviewController.allowsSelectionResize(isPinned: false)),
            ("拖走固定后禁止边框手柄，只保留滚轮缩放",
             !InlinePreviewController.allowsSelectionResize(isPinned: true))
        ]
        for (label, ok) in pinnedChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        // 拖动换算：**鼠标走多远，窗口就该走多远**，和观看倍率无关。
        //
        // 窗口是绕着选区中心摆的（`previewFrame`），所以"挪选区一个点 = 挪窗口一个点"。
        // 以前 `movePreview` 把鼠标位移除以 `previewZoom`，放大到 4× 时鼠标走 40pt、
        // 窗口只走 10pt（用户报的"拖不动 / 越拖越偏"），缩到 0.25× 时又窜出 160pt。
        // 这里直接量最终 frame 的位移，不复制那份换算 —— 算式抄一份，改了原处这条照样绿。
        let baseRect = CGRect(x: 300, y: 240, width: 420, height: 260)
        let mouseDelta = CGSize(width: 40, height: 30)
        var dragChecks: [(String, Bool)] = []
        for zoom in [CGFloat(0.25), 0.5, 1, 2, 4] {
            let before = InlinePreviewController.previewFrame(for: baseRect, zoom: zoom)
            let after = InlinePreviewController.previewFrame(
                for: baseRect.offsetBy(dx: mouseDelta.width, dy: mouseDelta.height), zoom: zoom)
            let moved = CGSize(width: after.origin.x - before.origin.x,
                               height: after.origin.y - before.origin.y)
            let ok = abs(moved.width - mouseDelta.width) < 0.001
                && abs(moved.height - mouseDelta.height) < 0.001
            dragChecks.append((String(format: "%.2g× 时鼠标走 40pt、窗口也走 40pt（读到 %.1f）",
                                      Double(zoom), Double(moved.width)), ok))
        }
        // 反向对照：把位移除以倍率（旧写法）必须被这条抓住。
        // 挑一个倍率 ≠ 1 的档来算，否则 1× 下两种写法给出同一个数，对照就是空的。
        let zoomForContrast: CGFloat = 2
        let buggyAfter = InlinePreviewController.previewFrame(
            for: baseRect.offsetBy(dx: mouseDelta.width / zoomForContrast,
                                   dy: mouseDelta.height / zoomForContrast),
            zoom: zoomForContrast)
        let buggyBefore = InlinePreviewController.previewFrame(for: baseRect, zoom: zoomForContrast)
        let buggyMoved = buggyAfter.origin.x - buggyBefore.origin.x
        dragChecks.append(("反向对照：除以倍率的旧写法确实对不上（读到 "
                            + String(format: "%.1f", Double(buggyMoved)) + "≠ 40）",
                            abs(buggyMoved - mouseDelta.width) > 0.001))
        for (label, ok) in dragChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        // 「按「保留」才写 .txt」这一格是真跑过的：拿临时目录把两个开关状态各走一遍。
        // 光看代码里那个 `if saveOCRText` 不算数 —— 这条链子在 W2 里换过一次位置
        // （从"识别完就写"挪到"保留时才写"），挪空了照样编译得过。
        let sidecarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Grabi-timing-\(UUID().uuidString)")
        var sidecarChecks: [(String, Bool)] = []
        do {
            try FileManager.default.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
            let png = sidecarDir.appendingPathComponent("shot.png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
            let txt = ImageWriter.textURL(alongside: png)
            let store = SettingsStore.shared
            let wasOn = store.saveOCRText
            defer {
                store.saveOCRText = wasOn
                try? FileManager.default.removeItem(at: sidecarDir)
            }
            store.saveOCRText = false
            let offNote = ShotCoordinator.writeSidecarIfNeeded(ocrText: "第一行", alongside: png)
            sidecarChecks.append(("开关没勾：不写字，也不谎称写了",
                                  offNote == nil
                                      && !FileManager.default.fileExists(atPath: txt.path)))
            store.saveOCRText = true
            let onNote = ShotCoordinator.writeSidecarIfNeeded(ocrText: "第一行", alongside: png)
            let content = try? String(contentsOf: txt, encoding: .utf8)
            sidecarChecks.append(("勾了之后 .txt 真落盘，内容一字不差", content == "第一行"))
            let named = onNote.map { $0.contains("已存") && $0.contains("shot.txt") } ?? false
            sidecarChecks.append(("那句带上「已存」和文件名　读到 = \(onNote ?? "nil")", named))
            sidecarChecks.append(("没识别出文字就不写空 .txt",
                                  ShotCoordinator.writeSidecarIfNeeded(ocrText: nil,
                                                                       alongside: png) == nil))
        } catch {
            sidecarChecks.append(("临时目录准备不了：\(error.localizedDescription)", false))
        }
        for (label, ok) in sidecarChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        noteGroup("── 丢弃（已经保留过的那一份，挪不进废纸篓就得承认）")
        // 只断言「丢不掉」和「本来就没了」两头，不跑「成功移进废纸篓」那条：那会往用户的
        // 废纸篓里塞一个自检文件，为了一个本来就没变过的分支留下不好解释的垃圾。
        let trashScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Grabi-discard-\(UUID().uuidString)")
        let trashDir = trashScratch.appendingPathComponent("sub")
        let trashFile = trashDir.appendingPathComponent("shot.png")
        var refused = false, stillThere = false, idempotent = false
        do {
            try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: trashFile)
            // 只许读不许写的目录：trashItem 在这里真会报 NSCocoaErrorDomain 513
            //（外置盘、网络盘、被 chmod 过的目录都是这一类）。
            try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                                  ofItemAtPath: trashDir.path)
            defer {
                // 无论断言成不成，权限都得还回来，否则临时目录删不掉
                try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: trashDir.path)
                try? FileManager.default.removeItem(at: trashScratch)
            }
            do {
                try ImageWriter.discard(trashFile)
            } catch {
                refused = true
            }
            stillThere = FileManager.default.fileExists(atPath: trashFile.path)
            // 已经不在这儿了不该算失败：那样面板会卡在"丢弃失败"上，
            // 而实际上没有任何东西需要用户处理。
            do {
                try ImageWriter.discard(trashScratch.appendingPathComponent("没有这个.png"))
                idempotent = true
            } catch {
                idempotent = false
            }
        } catch {
            print("  ✗ 临时目录准备不了：\(error.localizedDescription)")
            failures += 1
        }
        for (label, ok, hint) in [
            ("丢不掉时抛错", refused, "这里退回 try? 就是在谎报成功"),
            ("抛错的同时文件确实还在原处", stillThere, "「承认失败」和「留在原地」必须同时成立"),
            ("已经不在了不再报失败", idempotent, "没东西可丢不该弹「没能移到废纸篓」")
        ] {
            if !ok {
                failures += 1
                print("  ✗ \(label)　← \(hint)")
            } else {
                print("  ✓ \(label)")
            }
        }
        let wording = ImageWriter.discardFailureText(url: URL(fileURLWithPath: "/a/b/shot.png"),
                                                    reason: "没有权限")
        let wordingOK = wording.contains("没有权限") && wording.contains("/a/b/shot.png")
        if !wordingOK { failures += 1 }
        print("  \(wordingOK ? "✓" : "✗") 说明里带上原因和完整路径（只说「没权限」还得自己找文件）")

        noteGroup("── 识别文本 .txt（勾了「保存识别文本」就得如实说写没写成）")
        let txtScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Grabi-txt-\(UUID().uuidString)")
        let txtDir = txtScratch.appendingPathComponent("sub")
        let shotImage = txtDir.appendingPathComponent("shot.png")
        let shotText = ImageWriter.textURL(alongside: shotImage)
        var threw = false, landed = false, wroteOK = false
        do {
            try FileManager.default.createDirectory(at: txtDir, withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: shotImage)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: txtDir.path)
                try? FileManager.default.removeItem(at: txtScratch)
            }
            // 只读目录：写旁车 .txt 必须抛出来，而且不许留下半个文件
            try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                                  ofItemAtPath: txtDir.path)
            do {
                _ = try ImageWriter.writeText("识别结果", alongside: shotImage)
            } catch {
                threw = true
            }
            landed = FileManager.default.fileExists(atPath: shotText.path)
            // 反过来，能写的时候必须真的写进去 —— 否则"成功"那半句也是假的
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: txtDir.path)
            let written = try ImageWriter.writeText("识别结果 第二行", alongside: shotImage)
            wroteOK = FileManager.default.contents(atPath: written.path).flatMap {
                String(data: $0, encoding: .utf8)
            }?.contains("第二行") == true
        } catch {
            print("  ✗ 临时目录准备不了：\(error.localizedDescription)")
            failures += 1
        }
        for (label, ok) in [
            ("写不进时抛错，且不留下半个 .txt", threw && !landed),
            ("能写时真的落盘（读回来对得上）", wroteOK)
        ] {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }
        let txtName = shotText.lastPathComponent
        let okText = ImageWriter.ocrTextStatus(wrote: true, txtURL: shotText, reason: nil)
        let badText = ImageWriter.ocrTextStatus(wrote: false, txtURL: shotText, reason: "没有权限")
        let wordingChecks: [(String, Bool)] = [
            ("成功那半句写明「已存」并带文件名", okText.contains("已存") && okText.contains(txtName)),
            ("失败那半句带文件名和原因", badText.contains(txtName) && badText.contains("没有权限")),
            ("失败那半句绝不出现「已存」", !badText.contains("已存")),
            ("两句都是单行（要塞进状态行 / 角标）",
             !okText.contains("\n") && !badText.contains("\n"))
        ]
        for (label, ok) in wordingChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        print()
        noteGroup("── 系统打开（点了没反应也要说话）+ 最近截图清账")
        // 这一组盯的是"点了没反应"那一整类：六个 NSWorkspace 调用点原先全都不看返回值。
        let fileGone = SystemOpen.failureText(url: shotImage, subject: .file, exists: false)
        let fileStuck = SystemOpen.failureText(url: shotImage, subject: .file, exists: true)
        let dirGone = SystemOpen.failureText(url: txtDir, subject: .folder, exists: false)
        let pane = SystemOpen.settingsPaneText(page: "登录项")
        let name = shotImage.lastPathComponent
        let openChecks: [(String, Bool)] = [
            ("不在了 / 在但打不开，两句话不一样", fileGone.detail != fileStuck.detail),
            ("两句都点出文件名", fileGone.title.contains(name) && fileStuck.title.contains(name)),
            ("两句都带上所在目录（只有文件名不知道是哪一份）",
             fileGone.detail.contains(txtDir.path) && fileStuck.detail.contains(txtDir.path)),
            ("失败话术里绝不出现「已打开」「成功」（标题和说明都查）",
             [fileGone, fileStuck, dirGone, pane].allSatisfy { pair in
                 [pair.title, pair.detail].allSatisfy {
                     !$0.contains("已打开") && !$0.contains("成功") && !$0.contains("已保存")
                 }
             }),
            ("文件夹不叫「这张图」", dirGone.detail.contains("文件夹") && !dirGone.detail.contains("这张图")),
            ("系统设置那一页给出手动路径", pane.detail.contains("系统设置") && pane.detail.contains("登录项"))
        ]
        for (label, ok) in openChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        // 故意用"插入顺序 ≠ 字典序"的清单：不然 sorted() 和原顺序给的结果一样，
        // 保序那条永远分不出对错。
        let all = ["/x/c.jpg", "/x/a.jpg", "/x/b.jpg"]
        let existsEven: (String) -> Bool = {["/x/c.jpg", "/x/a.jpg"].contains($0)}
        let keptLive = SettingsStore.liveRecentShots(all, exists: existsEven)
        let pruneChecks: [(String, Bool)] = [
            ("死链摘掉、活链保序（不是按名字排）", keptLive == ["/x/c.jpg", "/x/a.jpg"]),
            ("全活时结果与输入逐条相等（这就是「不写偏好」的判据）",
             SettingsStore.liveRecentShots(all, exists: { _ in true }) == all),
            ("全死时清空", SettingsStore.liveRecentShots(all, exists: { _ in false }).isEmpty),
            ("空清单不炸", SettingsStore.liveRecentShots([], exists: { _ in true }).isEmpty)
        ]
        for (label, ok) in pruneChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        noteGroup("── 热键录制（不收那种会抢走别人快捷键的组合）")
        // 实测：RegisterEventHotKey 对 ⌘C、⇧⌘4 一律返回 noErr，也不报跨进程占用。
        // 也就是说"注册成功"这条路根本拦不住事故 —— 只能在接受之前自己判断。
        let mk = HotKeySpec.make
        let single: [(String, HotKeySpec)] = [
            ("⌘C", mk(HotKeySpec.Key.c, HotKeySpec.Mod.cmd)),
            ("⌃A", mk(HotKeySpec.Key.a, HotKeySpec.Mod.ctrl)),
            ("⌥3", mk(HotKeySpec.Key.three, HotKeySpec.Mod.opt)),
            ("⌘4", mk(HotKeySpec.Key.four, HotKeySpec.Mod.cmd))
        ]
        let hotKeyChecks: [(String, Bool)] = [
            ("单修饰键全部拦下（\(single.map(\.0).joined(separator: "、"))）",
                single.allSatisfy { $0.1.modifierRejection != nil }),
            ("拦的时候给出话说（不是静默吞掉按键）",
                single.allSatisfy { !($0.1.modifierRejection ?? "").isEmpty }),
            ("Grabi 默认的 ⌃⌥A / ⌃⌥S 不受影响（不然自检第一天就该红）",
                mk(HotKeySpec.Key.a, HotKeySpec.Mod.ctrl | HotKeySpec.Mod.opt).modifierRejection == nil
                    && mk(HotKeySpec.Key.s, HotKeySpec.Mod.ctrl | HotKeySpec.Mod.opt).modifierRejection == nil),
            ("两个修饰键就放行（不该逼用户按四个）",
                mk(HotKeySpec.Key.a, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift).modifierRejection == nil),
            ("修饰键数得是真的数（⌃⌥⇧⌘ = 4）",
                mk(HotKeySpec.Key.a, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift
                   | HotKeySpec.Mod.ctrl | HotKeySpec.Mod.opt).modifierCount == 4),
            ("认出 macOS 自带截图那四条 ⇧⌘3 / 4 / 5 / 6",
                [HotKeySpec.Key.three, HotKeySpec.Key.four, HotKeySpec.Key.five, HotKeySpec.Key.six]
                    .allSatisfy { mk($0, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift).conflictsWithSystemScreenshot }),
            ("加 ⌃ 的「存到剪贴板」变体也算系统的",
                mk(HotKeySpec.Key.four, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift | HotKeySpec.Mod.ctrl)
                    .conflictsWithSystemScreenshot),
            ("差一个修饰键就不算（⌃⌥⇧4 是 Grabi 自己的地盘，别误拦）",
                !mk(HotKeySpec.Key.four, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift | HotKeySpec.Mod.opt)
                     .conflictsWithSystemScreenshot
                    && !mk(HotKeySpec.Key.four, HotKeySpec.Mod.ctrl | HotKeySpec.Mod.opt)
                     .conflictsWithSystemScreenshot),
            ("数字键以外的 ⇧⌘ 不算（⇧⌘A 没人拦）",
                !mk(HotKeySpec.Key.a, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift).conflictsWithSystemScreenshot),
            ("未启用不算撞系统（.none 是一切的默认值）",
                !HotKeySpec.none.conflictsWithSystemScreenshot)
        ]
        for (label, ok) in hotKeyChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        let takeover = HotKeySpec.make(HotKeySpec.Key.four, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift)
        let sysComboSpelling = [HotKeySpec.Key.three, HotKeySpec.Key.four,
                                HotKeySpec.Key.five, HotKeySpec.Key.six]
            .map { mk($0, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift).displayString }
        let plan = SettingsWindowController.systemScreenshotPrompt(takeover)
        let decisionChecks: [(String, Bool)] = [
            ("界面写法按 Apple 的修饰键顺序（⌃⌥⇧⌘，所以是 ⇧⌘4 而不是 ⌘⇧4）",
                takeover.displayString == "⇧⌘4"),
            ("问句标题用的就是那个写法",
                plan.title.hasPrefix(takeover.displayString)),
            ("给出系统那边去哪儿关（键盘快捷键 › 屏幕快照）",
                plan.detail.contains("屏幕快照") && plan.detail.contains("键盘快捷键")),
            ("安全选项和「仍要用」是两个不同按钮，且安全那个不含「仍要」",
                plan.swapTitle != plan.keepTitle && !plan.swapTitle.contains("仍要")),
            ("用户坚持的那条按钮回显的是界面同款写法",
                plan.keepTitle.contains(takeover.displayString)),
            ("问句不提前报喜（不出现「已接管」「成功」「已关闭」）",
                [plan.title, plan.detail, plan.swapTitle, plan.keepTitle].allSatisfy {
                    !$0.contains("已接管") && !$0.contains("成功") && !$0.contains("已关闭")
                }),
            ("没撞自己、但撞了系统 → 先问一句",
                SettingsWindowController.commitDecision(for: "capture", newValue: takeover,
                                                       capture: .make(HotKeySpec.Key.a,
                                                                      HotKeySpec.Mod.ctrl | HotKeySpec.Mod.opt))
                    == .asksAboutSystemScreenshot),
            ("普通组合直接接受（默认值就该是这条路）",
                SettingsWindowController.commitDecision(for: "capture",
                                                       newValue: .make(HotKeySpec.Key.a, HotKeySpec.Mod.ctrl | HotKeySpec.Mod.opt),
                                                       capture: .make(HotKeySpec.Key.a, HotKeySpec.Mod.ctrl | HotKeySpec.Mod.opt))
                    == .accept),
            ("和自己原来的值比不算撞车（不然改另一条都改不了）",
                SettingsWindowController.commitDecision(for: "capture", newValue: takeover,
                                                       capture: takeover)
                    != .takenByOtherField("截图")),
            ("停用不参与撞车判断",
                SettingsWindowController.commitDecision(for: "capture", newValue: .none,
                                                       capture: .none) == .accept),
            ("面板说明里那四条系统组合和框里的写法一字不差",
                sysComboSpelling.allSatisfy { SettingsWindowController.hotKeyHelpText.contains($0) }),
            // 原先这里是一条 `!contains("⌘⇧")`：只认 cmd 写在 shift 前面那一种反法。
            // 下面那组「说明文案的修饰键顺序」把 ⌃⌥⇧⌘ 的 12 种反法全量了，还顺手
            // 覆盖了这一栏的邻居，所以留一条尺子就够了。
            ("说明讲清了为什么要两个修饰键，不是只立规矩",
                SettingsWindowController.hotKeyHelpText.contains("两个修饰键")
                    && SettingsWindowController.hotKeyHelpText.contains("⌘C")
                    && SettingsWindowController.hotKeyHelpText.contains("⌃A"))
        ]
        for (label, ok) in decisionChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        noteGroup("── 设置窗的高度分配（放不下的是窗口，不该顺带变成看不见的内容）")
        // 以前这个决定是 `showPane` 里一行 `min(max(desired, 240), ceiling)`：
        // 压完窗口没人再问"被压掉的那一截去哪了"，而它其实是**裁没了**（看不见也滚不到）。
        // 现在溢出量原样报出来，接住它的是滚动视图 —— 两件事各自有断言。
        let whTall = SettingsWindowController.windowHeight(desired: 640, screenVisibleHeight: 900)
        let whShort = SettingsWindowController.windowHeight(desired: 640, screenVisibleHeight: 720)
        let whTiny = SettingsWindowController.windowHeight(desired: 640, screenVisibleHeight: 400)
        let whSmall = SettingsWindowController.windowHeight(desired: 180, screenVisibleHeight: 900)
        let whChecks: [(String, Bool)] = [
            ("屏够高就长到内容高，一像素都不裁", whTall.height == 640 && whTall.overflow == 0),
            ("720 的屏：窗口压到 560，而压掉的 80 被报成溢出（有人接才允许压）",
                whShort.height == 560 && whShort.overflow == 80),
            ("反向对照：压窗口不再等于丢内容 —— 溢出必须是非 0 且被说出来的",
                whShort.overflow > 0),
            ("极矮屏也不开成一条缝：窗口下限 320", whTiny.height == 320 && whTiny.overflow == 320),
            ("内容比下限还矮时按下限给，且不算溢出", whSmall.height == 240 && whSmall.overflow == 0)
        ]
        for (whLabel, ok) in whChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(whLabel)")
        }

        noteGroup("── 图例的键名加粗（那 12 行说明要能顺着左边走）")
        // 排版从「一整段文字」改成「一行一个标签 + 键名加粗」，
        // 而"文案必须真贴在窗上"那条断言现在比的是拼接后的整段文字 ——
        // 也就是说拆行本身没人管了，这里补上：键名必须真的被加粗，
        // 而超过 8 个字符的前缀（那多半是一句被冒号断开的说明）必须不被加粗。
        let legendBold = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let legendPlain = NSFont.systemFont(ofSize: 11)
        func fontAt(_ index: Int, in line: String) -> NSFont? {
            SettingsWindowController.legendLine(line)
                .attribute(.font, at: index, effectiveRange: nil) as? NSFont
        }
        let legendChecks: [(String, Bool)] = [
            ("键名那一截是加粗的", fontAt(2, in: "· 空格：强制切到整屏候选") == legendBold),
            ("冒号之后的说明是常规字重", fontAt(6, in: "· 空格：强制切到整屏候选") == legendPlain),
            ("没有冒号的行一个字都不加粗", fontAt(0, in: "按 Delete 清空该热键。") == legendPlain),
            ("反向对照：11 个字符的前缀不算键名",
                fontAt(0, in: "这一整句都很长很长很长：剩下的说明") == legendPlain),
            ("加粗不吞字：排版之后原文一字不差",
                SettingsWindowController.legendLine("· Esc：取消").string == "· Esc：取消")
        ]
        for (legendLabel, ok) in legendChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(legendLabel)")
        }

        noteGroup("── 运行状态行的分色（陈述句不许跟着喊）")
        // 这一栏整段刷橙时，三行里真正要用户动手的那一行反而被埋了。
        // 颜色本身没法比（动态色实例不保证相等），所以比的是"哪一行被判成问题"
        // 和"分色有没有吞掉原文"—— 这两条才是真会错的地方。
        let wall = "当前机制：未启用　·　系统未找到记录\n⚠︎ 不在标准目录\n⚠︎ 请拖到「应用程序」"
        let painted = SettingsWindowController.advisoryAttributed(wall, warning: true)
        let calmText = "当前机制：系统登录项（SMAppService.mainApp）　·　已登记"
        let calm = SettingsWindowController.advisoryAttributed(calmText, warning: false)
        let advisoryChecks: [(String, Bool)] = [
            ("分色不吞字：三行原文一字不差", painted.string == wall),
            ("首行是陈述句，不该跟着喊",
                !SettingsWindowController.isProblemLine("当前机制：未启用　·　系统未找到记录",
                                                        warning: true)),
            ("⚠ 开头的行才是要处理的",
                SettingsWindowController.isProblemLine("⚠︎ 不在标准目录", warning: true)),
            ("没警告时一行都不该涂成问题",
                !SettingsWindowController.isProblemLine("⚠︎ 顺带提到", warning: false)),
            ("反向对照：句中夹一个 ⚠ 不算问题行",
                !SettingsWindowController.isProblemLine("机制 ⚠ 未启用", warning: true)),
            ("一切正常时也是原文", calm.string == calmText)
        ]
        for (advisoryLabel, ok) in advisoryChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(advisoryLabel)")
        }

        noteGroup("── 剪贴板（说「已复制」之前得回读一遍）")
        // 三处「已复制」以前只看设置开没开；现在写完要回读。机制部分跑在**自己的
        // 命名剪贴板**上：自检不该把用户刚复制的东西顶掉。
        let probe = NSPasteboard(name: NSPasteboard.Name("com.momoxiao.grabi.selftest"))
        probe.clearContents()
        let sample = "自检写的一段字：⌘V 粘的不是用户的剪贴板"
        let pbWrote = PasteboardWrite.write(text: sample, to: probe)
        let pbReadsBack = probe.string(forType: .string) == sample
        let pbMoved = probe.changeCount != 0
        let pngBytes = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0).flatMap { rep -> Data? in
            rep.size = NSSize(width: 4, height: 4)
            return rep.representation(using: .png, properties: [:])
        }
        let pbImageOK = PasteboardWrite.writeImage(tiff: nil, png: pngBytes, to: probe)
        let pbImageReadsBack = probe.availableType(from: [.png]) == .png
        // 「没有图可写」这条真正要保护的是：别把用户剪贴板上原有的东西擦掉。
        // 只查返回值是查不出来的（clearContents 之后类型自然读不到，回读那半就会
        // 顺手判 false），所以这里回读内容本身。
        PasteboardWrite.write(text: sample, to: probe)
        let pbEmptyImage = PasteboardWrite.writeImage(tiff: nil, png: nil, to: probe)
        let pbKeptOldContent = probe.string(forType: .string) == sample
        // 下面三条各钉住回读的一半：内容没了 / 内容不对 / changeCount 没动
        probe.clearContents()
        let pbCleared = PasteboardWrite.verifyText(sample, on: probe, changedFrom: 0)
        PasteboardWrite.write(text: sample, to: probe)
        let pbMismatch = PasteboardWrite.verifyText(sample + "？", on: probe,
                                                    changedFrom: probe.changeCount - 1)
        let pbCountStillOld = PasteboardWrite.verifyText(sample, on: probe,
                                                         changedFrom: probe.changeCount)
        let pbChecks: [(String, Bool)] = [
            ("往自己的命名剪贴板写一段字，回读说成功且真的读得回来",
                pbWrote && pbReadsBack && pbMoved),
            ("图片：只给 PNG 也算写进去，且类型读得到", pbImageOK && pbImageReadsBack),
            ("没有图可写时不动用户原来的内容（别为了报失败先把剪贴板擦了）",
                !pbEmptyImage && pbKeptOldContent),
            ("内容被清掉之后回读必须改口（回读不是装的）", !pbCleared),
            ("内容差一个字算失败（是真比对，不是「有东西就算」）", !pbMismatch),
            ("changeCount 没动就算失败（内容对得上也不行）", !pbCountStillOld)
        ]
        for (label, ok) in pbChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        // 已保存的那一份：复制图片时要**连文件 URL 一起**写进剪贴板。
        // 只写位图的话，Finder / 聊天工具里粘出来还是一张"无名的图"；
        // 而声明一个不存在的路径更糟 —— 粘出去的是一个坏链接。
        // 两头各碰一次：有文件时 `.fileURL` 读得回，没文件时绝不凭空声明一份。
        let savedImageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Grabi-clip-\(UUID().uuidString).png")
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: savedImageURL)
        defer { try? FileManager.default.removeItem(at: savedImageURL) }
        probe.clearContents()
        let withURLOK = PasteboardWrite.writeImage(tiff: nil, png: pngBytes,
                                                   fileURL: savedImageURL, to: probe)
        let urlReadsBack = probe.string(forType: .fileURL).map {
            URL(string: $0)?.standardizedFileURL == savedImageURL.standardizedFileURL
        } ?? false
        let stillHasImage = probe.availableType(from: [.png]) == .png
        probe.clearContents()
        let withoutURL = PasteboardWrite.writeImage(tiff: nil, png: pngBytes, to: probe)
        let noBogusURL = probe.string(forType: .fileURL) == nil
        let fileURLChecks: [(String, Bool)] = [
            ("有文件时复制图片：位图和文件 URL 都进剪贴板（Finder 里粘得出文件）",
             withURLOK && stillHasImage && urlReadsBack),
            ("没文件时不声明 .fileURL（不粘出一个坏链接）", withoutURL && noBogusURL)
        ]
        for (label, ok) in fileURLChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }
        probe.clearContents()

        let failStatus = PasteboardWrite.textStatus(ok: false, characters: 120)
        let okStatus = PasteboardWrite.textStatus(ok: true, characters: 120)
        let wordChecks: [(String, Bool)] = [
            ("失败那句不出现「已复制」三个字",
                !failStatus.contains("已复制") && okStatus.contains("已复制")),
            ("失败那句点名了到底没写进去多少字", failStatus.contains("120")),
            ("失败那句给了下一步（再按一次）", failStatus.contains("再按一次")),
            ("角标标题和详情拆成两行，标题短到不会被裁",
                PasteboardWrite.textFailureTitle.count <= 6
                    && PasteboardWrite.textFailureDetail(characters: 120).contains("120")),
            ("图片那半句：失败时说「没进剪贴板」，不是沉默",
                PasteboardWrite.imageClipboardSuffix(ok: false).contains("没进剪贴板")
                    && !PasteboardWrite.imageClipboardSuffix(ok: false).contains("已复制")
                    && PasteboardWrite.imageClipboardSuffix(ok: true) == "　·　已复制"),
            // 就地预览那三处复制图片走的是角标，措辞和文字版共用同一个标题。
            ("图片版角标：失败那句报得出尺寸、也给下一步",
                PasteboardWrite.imageFailureDetail(dimensions: "2880 × 1800 px").contains("2880")
                    && PasteboardWrite.imageFailureDetail(dimensions: "1 × 1 px").contains("再按一次")
                    && !PasteboardWrite.imageFailureDetail(dimensions: "1 × 1 px").contains("已复制")),
            ("图片和文字共用「复制没成功」那一个标题（同一件坏事不该有两个名字）",
                PasteboardWrite.textFailureTitle == "复制没成功"
                    && PasteboardWrite.imageStatus(ok: false, dimensions: "1 × 1 px")
                        .hasPrefix(PasteboardWrite.textFailureTitle)
                    && PasteboardWrite.textStatus(ok: false, characters: 1)
                        .hasPrefix(PasteboardWrite.textFailureTitle))
        ]
        for (label, ok) in wordChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }
        probe.clearContents()

        noteGroup("── 截图不再自动进剪贴板（进剪贴板是「复制图片」那一下的事）")
        // 这一组守的是那件最容易被"顺手"破坏的事：截图时替用户写剪贴板。
        // 自动复制那一版会在用户还没决定要不要留的时候，就把他刚复制的东西顶掉，
        // 而且不报错、不留痕。判据钉在**纯数据**上（这一档该不该立刻落盘、
        // 那两句 tooltip 说的是什么），因为这些不需要造一个真面板就能查死。
        let noAutoClipboardChecks: [(String, Bool)] = [
            // 「面板开着」那一格不落盘，也不该有任何"自动进剪贴板"的旁路 ——
            // 这条断言把"复制的唯一入口是用户那一下"钉住。
            ("面板开着时不落盘（复制与保存都得等用户点）",
             !ShotCoordinator.savesImmediately()),
            // 没保留过的「丢弃」只关面板：截图没自动进剪贴板，这条也不许去碰
            // 用户刚复制好的内容（文字或别处的东西）。
            ("没保留时「丢弃」说清它不碰剪贴板，不是「截图自动进去的那份」",
             InlinePreviewController.keepDiscardTitles(saved: false).discardTip.contains("剪贴板")),
            ("「保存」那颗说的是保存，不再暗示剪贴板是默认去处",
             !InlinePreviewController.keepDiscardTitles(saved: false).keepTip.contains("剪贴板")),
            // 设置里那两行是用户最信的一份说明，必须说得出"两个动作各管一头"。
            ("设置里那两行同时说得出「保存」和「复制图片」",
             SettingsWindowController.saveTimingLines.joined().contains("保存")
                 && SettingsWindowController.saveTimingLines.joined().contains("复制图片")),
            ("设置里那两行不再说剪贴板是默认去处（那个默认没了）",
             !SettingsWindowController.saveTimingLines.joined().contains("默认只进剪贴板")
                 && !SettingsWindowController.saveTimingLines.joined().contains("默认进剪贴板")),
            // 复制不是"完成这一张图"的出口：用户可能要接着复制另一种结果或继续标注。
            ("复制完成后面板保持打开",
             SettingsWindowController.saveTimingLines.joined().contains("保持打开")),
            // 「丢弃」只负责关面板，不许顺手清掉用户刚复制的文字或别处内容。
            ("未保留时「丢弃」的路径里没有清剪贴板那一步",
             !InlinePreviewController.keepDiscardTitles(saved: false).discardTip
                 .contains("清掉")),
        ]
        for (label, ok) in noAutoClipboardChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }


        noteGroup("── 菜单里的组合键（显示出来的快捷键必须按得出去）")
        // 类型先落地成具名值：OptionSet 的字面量在元组比较里推不出上下文，
        // 而自检里最不该出现的就是"编译不过的断言"和强解包。
        func menuKey(_ code: UInt32, _ mods: UInt32) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
            HotKeySpec.make(code, mods).menuKeyEquivalent
        }
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
        let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]
        let cmdOnly: NSEvent.ModifierFlags = [.command]
        let menuChecks: [(String, Bool)] = [
            ("⌃⌥A 写成 keyEquivalent 是小写 a + ⌃⌥",
                menuKey(HotKeySpec.Key.a, HotKeySpec.Mod.ctrl | HotKeySpec.Mod.opt)
                    .map { $0.key == "a" && $0.modifiers == ctrlOpt } == true),
            ("⇧⌘4 的字符是 4（AppKit 比对的是不带修饰的字符，不是 $）",
                menuKey(HotKeySpec.Key.four, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift)
                    .map { $0.key == "4" && $0.modifiers == cmdShift } == true),
            ("空格键写成 \" \"，不是 \"Space\"",
                menuKey(HotKeySpec.Key.space, HotKeySpec.Mod.cmd)
                    .map { $0.key == " " && $0.modifiers == cmdOnly } == true),
            ("↩ / 方向键给不出字符 → 给 nil（宁可菜单上不显示，也别挂个按不动的假快捷键）",
                menuKey(HotKeySpec.Key.ret, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift) == nil
                    && menuKey(HotKeySpec.Key.left, HotKeySpec.Mod.cmd) == nil),
            ("未启用那条热键也给 nil（「未设置」不是快捷键）",
                HotKeySpec.none.menuKeyEquivalent == nil)
        ]
        for (label, ok) in menuChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        noteGroup("── 恢复默认快捷键（会丢掉用户自己选的组合，所以先问一句）")
        let RS = SettingsWindowController.self
        typealias Chg = SettingsWindowController.HotKeyChange
        let rsUserCapture = mk(HotKeySpec.Key.x, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift)
        let rsOne = RS.resetDecision(capture: rsUserCapture)
        let rsNone = RS.resetDecision(capture: .defaultCapture)
        // 每个场景各用自己的计数器：早先两个场景共用一个 `rsWrites`，
        // 「取消时一个字节都不写」那行读到的是**确认场景**写的那一次，
        // 于是一行绿得毫无意义。分场景计数之后，红绿才各自代表一件事。
        let rsChanges: [Chg]
        if case let .restore(c) = rsOne { rsChanges = c } else { rsChanges = [] }

        func drive(capture: HotKeySpec, answer: Bool)
            -> (outcome: SettingsWindowController.HotKeyResetOutcome, asks: Int, writes: Int) {
            var asks = 0, writes = 0
            let out = RS.runReset(capture: capture,
                                  write: { writes += 1 }) { _ in asks += 1; return answer }
            return (out, asks, writes)
        }
        let rsCancel = drive(capture: rsUserCapture, answer: false)
        let rsOK = drive(capture: rsUserCapture, answer: true)
        let rsSkip = drive(capture: .defaultCapture, answer: true)
        let rsDetail = RS.resetPrompt(rsChanges).detail
        let rsStatus = RS.resetStatus(rsOK.outcome)
        let rsCancelStatus = RS.resetStatus(.cancelled)
        let rsSkipStatus = RS.resetStatus(.nothingToRestore)
        let rsAlert = RS.resetAlert(rsChanges)
        // 给用户读的几行合起来当一个面查（问句 + 已恢复 + 没改任何东西）
        let rsWordingSurface = RS.resetDetail(rsChanges) + "\n" + RS.resetPrompt(rsChanges).detail
            + "\n" + rsStatus + "\n" + rsSkipStatus
        let rsChecks: [(String, Bool)] = [
            ("两条都还是默认 → 判成「没东西可恢复」", rsNone == .nothingToRestore),
            ("不是默认 → 只列截图那一条（\(rsChanges.count) 条）", rsChanges.count == 1),
            ("列出来的就是截图那条，旧值用界面同款写法",
                rsChanges.first?.name == "截图"
                && rsChanges.first?.from == rsUserCapture.displayString
                && rsChanges.first?.to == HotKeySpec.defaultCapture.displayString),
            ("按「取消」时问了一次、一个字节都不写（写 \(rsCancel.writes) 次）",
                rsCancel.outcome == .cancelled && rsCancel.asks == 1 && rsCancel.writes == 0),
            ("确认之后正好写一次盘（写 \(rsOK.writes) 次、问 \(rsOK.asks) 次）",
                rsOK.writes == 1 && rsOK.asks == 1),
            ("本来就是默认时连问都不问、也不写盘（问 \(rsSkip.asks) 次、写 \(rsSkip.writes) 次）",
                rsSkip.outcome == .nothingToRestore && rsSkip.asks == 0 && rsSkip.writes == 0),
            ("问句把旧值和新值都摆出来，不是空问一句",
                rsDetail.contains(rsChanges[0].from) && rsDetail.contains(rsChanges[0].to)
                    && rsDetail.contains("截图")),
            ("问句讲清「按取消不改动任何设置」", rsDetail.contains("取消」不会改动任何设置")),
            ("默认按钮是「取消」（回车误碰一次不该丢掉用户的键）",
                rsAlert.buttons.first?.title == RS.resetCancelTitle
                    && rsAlert.buttons.last?.title == RS.resetRestoreTitle),
            ("「已恢复」只报真被改动的那条",
                rsStatus.contains(HotKeySpec.defaultCapture.displayString)
                    && !rsStatus.contains("静默")),
            ("按了取消的那句不许出现「已恢复」", !rsCancelStatus.contains("已恢复")),
            ("本来就默认的那句说「没改任何东西」并给出现在的组合",
                rsSkipStatus.contains("没改任何东西")
                    && rsSkipStatus.contains(HotKeySpec.defaultCapture.displayString)),
            ("「恢复默认」恢复的就是读不到时的回退",
                HotKeySpec.defaultCapture == mk(HotKeySpec.Key.a, HotKeySpec.Mod.ctrl | HotKeySpec.Mod.opt))
        ]
        for (label, ok) in rsChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }
        print("  问句原文：\(rsDetail.replacingOccurrences(of: "\n", with: " ⏎ "))")

        noteGroup("── 说明文案里的修饰键顺序（⌃⌥⇧⌘ 之外就是另一条键）")
        // 界面框里的写法是 `displayString` 拼出来的，只有一种顺序；说明文字却是手打的。
        // 同一件事在两个地方各写一遍，写反了谁都不报错，但用户看到的是两条不同的键
        // （原先的守卫只查 `hotKeyHelpText` 一个常量，隔壁那几栏照样没人看）。
        let ordProper = mk(HotKeySpec.Key.four, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift).displayString
        let ordFlipped = String(ordProper.dropLast().reversed()) + String(ordProper.last ?? "4")
        let ordViolation = HotKeySpec.modifierOrderViolation(in: ordFlipped)
        let ordPlan = SettingsWindowController.systemScreenshotPrompt(
            mk(HotKeySpec.Key.four, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift))
        let ordSurfaces: [(String, String)] = [
            ("设置 › 快捷键说明", SettingsWindowController.hotKeyHelpText)
        ] + SettingsWindowController.captureHelpTexts.enumerated().map {
            ("设置 › 截图时的说明 \($0.offset + 1)", $0.element)
        } + [
            ("--help 清单", usageText()),
            ("撞系统截图的问句", ordPlan.title + "\n" + ordPlan.detail
                + "\n" + ordPlan.swapTitle + "\n" + ordPlan.keepTitle),
            ("录制框里的显示文案", HotKeyRecorderView.boxText(
                recording: false,
                spec: mk(HotKeySpec.Key.a, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift | HotKeySpec.Mod.ctrl),
                rejectHint: nil)),
            ("单修饰键的拒绝理由", mk(HotKeySpec.Key.c, HotKeySpec.Mod.cmd).modifierRejection ?? ""),
            ("恢复默认快捷键的问句与结果行", rsWordingSurface)
        ]
        let ordChecker: [(String, Bool)] = [
            ("界面上那个真实写法（\(ordProper)）查不出问题",
                HotKeySpec.modifierOrderViolation(in: ordProper) == nil),
            ("把它倒过来写（\(ordFlipped)）确实会被查出来 →「\(ordViolation ?? "没查出来")」",
                ordViolation == "⌘⇧"),
            ("四个排齐的 ⌃⌥⇧⌘ 算干净",
                HotKeySpec.modifierOrderViolation(in: "⌃⌥⇧⌘K") == nil),
            ("重复的 ⌘⌘ 不算写对",
                HotKeySpec.modifierOrderViolation(in: "⌘⌘C") == "⌘⌘"),
            ("隔开的单修饰键不误伤（「⇧ 锁正方形，⌥ 从中心向外扩」）",
                HotKeySpec.modifierOrderViolation(in: "⇧ 锁正方形，⌥ 从中心向外扩") == nil),
            ("单修饰键本来就不归这里管（⌘C / ⌘1）",
                HotKeySpec.modifierOrderViolation(in: "· ⌘C：复制　这一排面板：⌘1 – ⌘4") == nil)
        ]
        for (label, ok) in ordChecker {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }
        var ordMulti = 0
        for (name, text) in ordSurfaces {
            let bad = HotKeySpec.modifierOrderViolation(in: text)
            let two = zip(text, text.dropFirst()).contains {
                HotKeySpec.modifierGlyphs.contains($0.0) && HotKeySpec.modifierGlyphs.contains($0.1)
            }
            if two { ordMulti += 1 }
            // 「读到了东西」和「顺序都对」是两件事：空串、或者一栏把快捷键全删了的
            // 文案，都能让顺序检查全绿。这一栏的存在意义就是教快捷键，所以至少要
            // 见到一个修饰键；带两个连着的另算（下面那行总数门）。
            let mentionsAny = text.contains { HotKeySpec.modifierGlyphs.contains($0) }
            if !mentionsAny && bad == nil {
                failures += 1
                print("  ✗ \(name)：读到的文案里一个修饰键都没有，这条查等于没查")
            } else {
                let verdict = bad.map { "\($0) 写反了" } ?? "顺序对"
                print("  \(bad == nil ? "✓" : "✗") \(name)：\(verdict)")
                if bad != nil { failures += 1 }
            }
        }
        // 这一行自己也必须是会红的：写死成 ✓ 就等于给整组发了一张免检通行证。
        let ordGate = ordMulti >= 2 && ordSurfaces.count >= 7
        if !ordGate { failures += 1 }
        print("  \(ordGate ? "✓" : "✗") 一共查了 \(ordSurfaces.count) 处文案，其中 \(ordMulti) 处"
              + "带多修饰键组合（少于 7 处或有文案被改回内联硬编码，这行就红）")

        noteGroup("── 浮条配色（工具栏那条底永远是深色，字色不许跟着系统外观走）")
        // 就地预览的工具栏浮在刚截下来的图上，底是固定的深色浮条。
        // 它以前直接用 `controlAccentColor` / `systemRed`：系统切到浅色模式时
        // 这些动态色会解成**更深**的一档，压在黑底上实测只有 3.3:1。
        // `barInk` 的职责就是把它们钉在深色那一档 —— 下面两条一起判：
        // 只判"两遍一致"的话，写成"永远按浅色解算"照样绿。
        guard let aqua = NSAppearance(named: .aqua), let darkAqua = NSAppearance(named: .darkAqua)
        else {
            failures += 1
            print("  ✗ 拿不到两套外观，这一组没跑成")
            print("结论：有 \(failures + 1) 项不对　·　退出码 1")
            exit(1)
        }
        func resolveIn(_ color: NSColor, _ appearance: NSAppearance) -> [Int] {
            var out = [-1, -1, -1]
            appearance.performAsCurrentDrawingAppearance {
                guard let rgb = color.usingColorSpace(.sRGB) else { return }
                out = [Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()),
                       Int((rgb.blueComponent * 255).rounded())]
            }
            return out
        }
        func hex(_ c: [Int]) -> String {
            c.count == 3 ? String(format: "%02X%02X%02X", c[0], c[1], c[2]) : "读不出来"
        }
        let barColors: [(String, NSColor)] = [
            ("强调色（识别文字 / 复制 / 再试一次）", .controlAccentColor),
            ("丢弃（红）", .systemRed),
            ("失败提示（橙）", .systemOrange)
        ]
        var inkBad = 0
        for (label, color) in barColors {
            let pinned = InlinePreviewController.barInk(color)
            let inLight = resolveIn(pinned, aqua), inDark = resolveIn(pinned, darkAqua)
            let wantsDark = resolveIn(color, darkAqua)
            let stable = inLight == inDark && inLight.count == 3
            // 契约是"按深色解算 + 再提亮一档"（深底 + 中亮度色本来到不了 4.5:1），
            // 所以这里判的是"不比深色那档暗，也没洗成白"，而不是"等于深色那档"。
            func luma(_ c: [Int]) -> Double {
                c.count == 3 ? 0.2126 * Double(c[0]) + 0.7152 * Double(c[1]) + 0.0722 * Double(c[2]) : -1
            }
            let followsBar = luma(inLight) >= luma(wantsDark) && luma(inLight) < 720
            if !stable || !followsBar { inkBad += 1 }
            // 有些色（比如默认强调色）在两套外观下本来就同值 —— 那一条对它只是不红，
            // 说清楚，免得以后有人以为它一直在守着这个色。
            let varies = resolveIn(color, aqua) != wantsDark
            print("  \(stable && followsBar ? "✓" : "✗") \(label)：深浅两遍都是 #\(hex(inLight))"
                  + "（深色那档是 #\(hex(wantsDark))，钉住时再提亮一档）"
                  + (varies ? "；不钉住的话浅色那遍会解成 #\(hex(resolveIn(color, aqua)))"
                            : "；这个色两套外观本来同值，稳定性那条对它只是不红"))
        }
        failures += inkBad
        // 这一组自己也必须是会红的：颜色清单被改空，"0 处不对"看着最干净。
        if barColors.count < 3 {
            failures += 1
            print("  ✗ 只查了 \(barColors.count) 种浮条色（少于 3 种等于没查）")
        } else {
            print("  ✓ 查了 \(barColors.count) 种浮条色")
        }

        noteGroup("── 无头开关（自检不许在用户屏幕上留东西）")
        // 用户反馈：自检一遍几十张图，弹窗一次次盖到人家的工作上。
        // 渲染那侧还有一条"跑完没有任何窗口在屏上"的实测；这里守的是闸门本身：
        // `Headless.onScreen` 在无头时真的不执行，在正常模式真的执行。
        let savedHeadless = Headless.active
        var ranWhenHeaded = false, ranWhenHeadless = false
        Headless.active = true
        Headless.onScreen { ranWhenHeadless = true }
        Headless.active = false
        Headless.onScreen { ranWhenHeaded = true }
        Headless.active = savedHeadless
        let headlessChecks: [(String, Bool)] = [
            ("无头时上屏动作被跳过", !ranWhenHeadless),
            ("正常时上屏动作照常执行（开关不是永远沉默）", ranWhenHeaded),
            ("跑完把开关还原了（自检不该改全局状态）", Headless.active == savedHeadless)
        ]
        for (label, ok) in headlessChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        noteGroup("── 出厂快捷键（分发出去的说明书只能问代码要）")
        // package.sh 把这两个值写进 DMG 里的「使用说明.txt」。从前那两行是手抄在脚本里的
        // —— 改了出厂默认，发出去的说明书就教错键位。
        let capDefault = HotKeySpec.defaultCapture
        let capText = capDefault.displayString
        let macScreenshot: Set<String> = ["\u{21E7}\u{2318}3", "\u{21E7}\u{2318}4",
                                          "\u{21E7}\u{2318}5", "\u{21E7}\u{2318}6"]
        // 打包脚本吃的是 CLI 那条，不是这个常量 —— 所以连那条一起验：
        // 分支被改名 / 忘了 exit / 分隔符换行，这里都会红，而脚本那边会拒绝打包。
        func runSelf(_ flag: String) -> String? {
            let pipe = Pipe()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            task.arguments = [flag]
            task.standardOutput = pipe
            task.standardError = Pipe()
            do { try task.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }
        let printed = (runSelf("--default-hotkeys") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultChecks: [(String, Bool)] = [
            ("默认值印得出字（说明书里不会是空的）", !capText.isEmpty),
            ("满足本 app 自己的规矩：至少两个修饰键", capDefault.modifierCount >= 2),
            ("没撞 macOS 自带截图那四条", !macScreenshot.contains(capText)),
            ("写法按 Apple 的修饰键顺序（⌃⇧⌘）",
                HotKeySpec.modifierOrderViolation(in: capText) == nil),
            ("--default-hotkeys 那条 CLI 在，且吐的就是这个值（打包脚本读的是它）",
                printed == capText)
        ]
        for (label, ok) in defaultChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }
        print("  当前：截图 \(capText)　CLI 读到「\(printed)」")

        noteGroup("── 参数清单（--help 那张表和真实分派的那批必须是同一批）")
        // 这张表是手抄的，已经错过两次：热键两行抄跑了（现在从设置读）、
        // 自检改名 --logic-selftest 之后清单里还留着旧名。这一组把它对着
        // `CLI.knownFlags`（未知参数那道门用的就是它）反来复去量一遍。
        let usage = usageText()
        let mentioned = Set(try! NSRegularExpression(pattern: "--[a-z][a-z-]*")
            .matches(in: usage, range: NSRange(usage.startIndex..., in: usage))
            .compactMap { Range($0.range, in: usage).map { String(usage[$0]) } })
        let usageChecks: [(String, Bool)] = [
            ("每个真会被分派的参数都在清单里（新加的不会没人知道）",
                CLI.knownFlags.isSubset(of: mentioned)),
            ("清单里没有代码里不存在的参数（改过名的不会留在那儿误人）",
                mentioned.isSubset(of: CLI.knownFlags)),
            ("--diagnose 那行不再承诺“热键占用”（跨进程占用读不到）",
                !usage.contains("热键占用")),
            ("热键那行是从设置读的（写死就会跟真实组合分家）",
                usage.contains(SettingsStore.shared.hotKeyCapture.displayString)
                    && !usage.contains("静默截图"))
        ]
        let missingFlags = CLI.knownFlags.subtracting(mentioned).sorted()
        let extraFlags = mentioned.subtracting(CLI.knownFlags).sorted()
        for (label, ok) in usageChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }
        print("  当前：清单 \(mentioned.count) 项、分派 \(CLI.knownFlags.count) 项（互相对不上的："
              + "\(missingFlags.isEmpty ? "无" : missingFlags.joined(separator: "、")) / "
              + "\(extraFlags.isEmpty ? "无" : extraFlags.joined(separator: "、"))）")

        // 那句结论从走过来的分组标题里长出来，不再手抄。
        let shortNames = groupTitles.map(Self.shortGroupName)
        let recapOK = !shortNames.isEmpty
            && shortNames.allSatisfy { !$0.isEmpty }
            && Set(shortNames).count == shortNames.count
        if !recapOK { failures += 1 }
        print("  \(recapOK ? "✓" : "✗") 结论是从 \(groupTitles.count) 个分组标题现读的，"
              + "每项都叫得出名字且不重名（手抄的那份和上面迟早走散）")
        // 短名那条规矩也得有对照，否则"摘括号"可以顺手摘成人人同名的前缀。
        let tail = Self.shortGroupName("── 系统打开（点了没反应也要说话）+ 最近截图清账")
        let plain = Self.shortGroupName("── 屏幕坐标 → 像素坐标")
        let colonCut = Self.shortGroupName("── 模板：没看懂的占位符要说出来，动了哪几刀要只说真动过的")
        let nameChecks: [(String, Bool)] = [
            ("摘掉「── 」和括号里那段解释，括号外的尾巴留着　得到 = \(tail)",
             tail == "系统打开 + 最近截图清账"),
            ("没有括号的标题一个字不改　得到 = \(plain)",
             plain == "屏幕坐标 → 像素坐标"),
            ("冒号起头的那种只留冒号前那截（结论是索引，不是把标题再念一遍）　得到 = \(colonCut)",
             colonCut == "模板"),
            ("反向对照：带括号的确实变短了（上一条不是恒等）",
             Self.shortGroupName("── 丢弃（「移到废纸篓」失败了就必须承认）") == "丢弃"),
        ]
        for (label, ok) in nameChecks {
            if !ok { failures += 1 }
            print("  \(ok ? "✓" : "✗") \(label)")
        }

        print(failures == 0
            ? "结论：\(shortNames.joined(separator: "、"))　—— \(shortNames.count) 组全部正确 ✓"
            : "结论：有 \(failures) 项不对　·　退出码 1")
        exit(failures == 0 ? 0 : 1)
    }

    /// 一张「数据顺序的前半是红、后半是蓝」的图：直接写像素缓冲，
    /// 不经过 CGContext，免得用绘图翻转去验绘图翻转（自己验自己）。
    private static func quadrantImage(side: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for row in 0..<side {
            for col in 0..<side {
                let index = (row * side + col) * 4
                if row < side / 2 { pixels[index] = 255 } else { pixels[index + 2] = 255 }
                pixels[index + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: side * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func firstPixel(_ image: CGImage) -> (Int, Int, Int)? {
        guard let data = image.dataProvider?.data else { return nil }
        let bytes = CFDataGetBytePtr(data)!
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    static func runShotTest() {
        guard Permissions.hasScreenRecording else {
            // 只说"缺权限"等于让人去猜：这一页在哪、勾完要不要重启，才是卡住人的地方。
            print("缺少屏幕录制权限，无法截图。")
            print("  1) 系统设置 → 隐私与安全性 → 屏幕录制，勾上 Grabi")
            print("     （菜单栏图标 →「修复权限」会直接打开这一页）")
            print("  2) 勾完必须重启一次 app 才生效 —— 系统限制，当前进程拿不到新权限")
            exit(1)
        }
        guard let screen = NSScreen.main else {
            print("找不到主显示器（屏幕可能已休眠或已断开）")
            exit(1)
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            do {
                let start = Date()
                let image = try await CaptureEngine().captureDisplay(containing: screen)
                let captureMS = Date().timeIntervalSince(start) * 1000

                let writeStart = Date()
                let url = try ImageWriter.write(image, type: "selftest")
                let writeMS = Date().timeIntervalSince(writeStart) * 1000

                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? Int) ?? 0

                print(String(format: "截图 %.0f ms  |  写盘 %.0f ms", captureMS, writeMS))
                print("逻辑分辨率 \(Int(screen.frame.width))×\(Int(screen.frame.height)) pt @\(screen.backingScaleFactor)x")
                print("输出 \(image.width)×\(image.height) px  |  \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                print("已保存: \(url.path)")

                let ocrStart = Date()
                let text = try await OCRRecognizer().recognize(image, languages: SettingsStore.shared.ocrLanguages)
                let ocrMS = Date().timeIntervalSince(ocrStart) * 1000
                print(String(format: "OCR %.0f ms  |  识别 %d 字符", ocrMS, text.count))
            } catch {
                print("失败: \(error.localizedDescription)")
            }
        }
        semaphore.wait()
        exit(0)
    }

    static func runAgentCommand(_ action: String) {
        let manager = AutoStartManager.shared
        let settings = SettingsStore.shared

        switch action {
        case "install", "enable":
            settings.launchAtLogin = true
            settings.keepAlive = true
            manager.apply(launchAtLogin: true, keepAlive: true)
            print("已开启：开机自启 + 崩溃保活")
            print("机制: \(manager.activeMechanism.rawValue)")
            print("状态: \(manager.statusDescription)")
        case "uninstall":
            settings.launchAtLogin = false
            settings.keepAlive = false
            manager.apply(launchAtLogin: false, keepAlive: false)
            print("已关闭自启动与保活")
        case "status":
            print(manager.detailedStatus())
        case "refresh":
            guard manager.activeMechanism != .none else {
                print("当前没有配置自启动，无需刷新")
                exit(0)
            }
            manager.apply(launchAtLogin: settings.launchAtLogin,
                          keepAlive: settings.keepAlive,
                          silent: true, force: true)
            print("已刷新后台项的签名登记")
            print("状态: \(manager.statusDescription)")
        case "preview":
            print(manager.previewPlist())
        default:
            print("用法: Grabi --agent install|uninstall|status|refresh|preview")
        }
        exit(0)
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
