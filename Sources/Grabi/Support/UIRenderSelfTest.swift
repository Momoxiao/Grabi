import AppKit

/// 离屏渲染自检：把界面组件真的画成 PNG 来看，不依赖屏幕录制。
///
///     Grabi --ui-render /tmp/grabi-ui
///
/// 为什么需要：交互层的改动（工具栏按钮会不会挤爆、角标那行说明会不会被截断、
/// 压暗层的挖空和尺寸标签对不对、边框手柄有没有被圆角裁掉）**只有看见才算验证过**。
/// 而拍屏那条路要求显示器亮着 + 屏幕录制权限，两者都可能没有；离屏渲染两个都不要求。
///
/// 局限要说清楚：这里验的是**视图自己**，不是窗口合成 —— 投影、层级、
/// 多窗口对位、鼠标光标这些仍然只能在真机上看。
enum UIRenderSelfTest {

    /// 渲染过程中顺手收集，最后统一做一次无障碍体检。
    private static var accessibilityRoots: [(String, NSView)] = []
    /// 顺手收集的「控件被父视图切到」记录。同样只取第一遍（两套外观是同一批视图）。
    private static var layoutHits: [String] = []
    /// 每次"想画一张"都记一笔：通道、文件名、有没有真落盘。
    /// `saveInPlace` 画不出来时返回 nil，而 9 个调用点全都没接这个返回值；
    /// 写盘用的又是 `try?` —— 两头都可能静默少一张，而"跑完了"照样绿。
    private static var renderShots: [(pass: String, name: String, ok: Bool)] = []
    private static var renderRoot = ""
    /// 每一遍（深色 / 浅色）真走了哪些面。"检查过的面板"那句话如果手写就会漂；
    /// 覆盖范围应该从真实走过的面里读出来。
    private static var overflowSurfaces: [String: Set<String>] = [:]

    /// 所有输出走这里：顺手数红 / 未验到，最后据此决定退出码。
    ///
    /// 以前 `--ui-render` 不管多少行红都 `exit(0)`，而 `--logic-selftest` 会给退出码。
    /// 一个只会打字的自检当不了闸门：脚本、CI、或者下一个只跑一次的人,都会把
    /// "跑完了" 当成 "跑对了"。
    private static var redLines = 0
    private static var unverifiedLines = 0

    static func say(_ line: String) {
        if line.contains("✗") { redLines += 1 }
        if line.contains("△") { unverifiedLines += 1 }
        print(line)
    }

    static func run(to directory: String) {
        try? FileManager.default.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true)
        renderRoot = directory
        _ = NSApplication.shared

        // 两套外观各画一遍。只看深色是不够的：设置窗口等界面用的是语义色，
        // 谁在某个角落写死了一个白色，浅色下就是"字没了"——而这种问题只有画出来才看得见。
        emitChecks = true
        renderSuite(to: "\(directory)/dark", appearance: .darkAqua)
        // 控件清单只取第一遍。两套外观画的是同一批视图，两遍都收会让"多少个控件"
        // 这种数字直接翻倍 —— 报出去的就是假指标。
        let roots = accessibilityRoots
        emitChecks = false
        renderSuite(to: "\(directory)/light", appearance: .aqua)

        // 自检的自检：浅色通道要是和深色一样暗，说明动态色没在对应外观上下文里解算，
        // 那整套浅色截图都是假的（这一条就是这么发现的）。
        printAppearanceCheck()
        printAccessibilityCheck(roots: roots)
        printMenuCheck()
        printActionNamingCheck()
        printToggleNamingCheck()
        printMenuStateCheck()
        printCaptureMenuCheck()
        printLocalizationCheck()
        printTooltipCheck(roots: roots)
        printLayoutCheck(hits: layoutHits)
        printShotInventory()
        printHeadlessCheck()
        say("已输出到 \(directory)（dark / light 两套外观）")
        // 结论行**不带 ✓/✗/△ 这些记号**，也不走 say：它自己带记号的话，
        // "红 N 行" 和外面 `grep -c ✗` 就会差一行（差的那一行还是它自己），
        // 而这两种数法迟早会有人拿去互相对账。
        print("结论：" + (redLines == 0 ? "全部通过" : "有 \(redLines) 行没过")
              + "　·　红 \(redLines) 行　·　未验到 \(unverifiedLines) 行"
              + "　·　退出码 \(redLines == 0 ? 0 : 1)")
        exit(redLines == 0 ? 0 : 1)
    }

    /// 数值断言只在第一遍打印（排版和外观无关，打两遍只会把红绿看混）。
    private static var emitChecks = true

    /// 当前通道的外观。抓图时必须在这个上下文里画，否则
    /// `NSColor.windowBackgroundColor.cgColor` 这类动态色会按系统默认解出来 ——
    /// 浅色通道拍出来还是深色，等于没测。
    private static var passAppearance: NSAppearance?

    /// 当前通道名 + 两套外观下同一张图的亮度（用来验"浅色通道真的是浅色"）。
    private static var passLabel = "dark"
    private static var appearanceProbe: [String: CGFloat] = [:]
    private static var appearanceGrays: [(String, String, CGFloat)] = []

    private static func renderSuite(to directory: String, appearance: NSAppearance.Name) {
        try? FileManager.default.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true)
        let resolved = NSAppearance(named: appearance)
        NSApp.appearance = resolved
        passAppearance = resolved
        passLabel = appearance == .darkAqua ? "dark" : "light"
        say("── \(appearance == .darkAqua ? "深色" : "浅色")通道")

        renderToolbars(in: directory)
        printStatusIconCheck(in: directory)
        renderToast(in: directory)
        renderDimOverlay(in: directory)
        renderPreviewComposition(in: directory)
        renderInkStates(in: directory)
        renderSettings(in: directory)
        printSettingsDesignCheck()
        printAdvisoryInkCheck()
        printSurfaceContrastSweep()
        printDesignTokenAudit()
        checkInkComposite()
        printInkToolCheck()
        renderOverlay(in: directory)
        printWidthChecks()
        printAppearanceProbe()
    }

    /// 无头自检的自检：跑完之后，屏幕上应该什么都没有多出来。
    ///
    /// 这一条是用户反馈引出来的 —— 自检几十张图，弹窗一遍遍盖到人家的工作上。
    /// "我们没打算显示窗口"是猜测，"跑完一遍没有任何窗口在屏上"才是检查。
    private static func printHeadlessCheck() {
        // 判据是"有没有落在用户看得见的屏幕上"。两个坑都踩过：
        // - `occlusionState.contains(.visible)` 在这台机器上从不置位（`.prohibited`
        //   的 app 收不到遮挡更新），拿它当判据的检查是永远绿的假检查 ——
        //   反向对照（把窗口留在屏内）跑出来照样绿，才发现的；
        // - 光看 `isVisible` 又太宽：菜单一被填充，AppKit 就挂出 NSCarbonMenuWindow
        //   这类系统窗，用户什么都看不见却会被算成"弹窗"。
        // 自检确实需要一个上屏的 key window（Esc / 查找条那几项查的就是键盘路由），
        // 它被挪到屏幕外面 —— 下面这条正好放过它、抓住留在屏内的。
        if ProcessInfo.processInfo.environment["LITESHOT_DEBUG_WINDOWS"] != nil {
            say("    屏幕 \(NSScreen.screens.map { NSStringFromRect($0.frame) }.joined(separator: " "))")
            for window in NSApp.windows {
                say("    win \(type(of: window)) frame=\(NSStringFromRect(window.frame))"
                    + " visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue)"
                    + " alpha=\(window.alphaValue)")
            }
        }
        let screens = NSScreen.screens.map { $0.frame }
        let onScreen = NSApp.windows.filter { window in
            let name = String(describing: type(of: window))
            let chrome = name.contains("Menu") || name.contains("Status") || name.hasPrefix("TUI")
            return window.isVisible && !chrome
                && screens.contains { $0.intersects(window.frame) }
        }.map { "\(type(of: $0))「\($0.title)」@\(NSStringFromPoint($0.frame.origin))" }
        let statusBar = StatusBarController()
        say("── 无头自检（不给用户的屏幕留东西）")
        say("    \(onScreen.isEmpty ? "✓" : "✗") 跑完没有任何窗口在屏上"
            + (onScreen.isEmpty ? "" : "：\(onScreen.joined(separator: "、"))"))
        let policyOK = NSApp.activationPolicy() == .prohibited && Headless.active
        say("    \(policyOK ? "✓" : "✗") 激活策略 prohibited、无头开关是开的"
            + "（策略=\(NSApp.activationPolicy().rawValue) 开关=\(Headless.active)）")
        let iconOK = !statusBar.statusItemVisibleForSelfTest
        say("    \(iconOK ? "✓" : "✗") 自检构造的菜单栏图标没占格子")
    }

    /// 语义色在当前外观下到底解成什么灰度：布局没问题但颜色不对时，这个数字先说话。
    /// 统一化对账：**同一个意思，在屏幕上必须只有一个值**。
    ///
    /// 量的是合成之后的像素，不是代码里的常量 —— 常量都取自 `Design` 也可能被中间
    /// 某层又叠了一次透明度。浮条和结果角标以前就是 0.92 / 0.82 两块深浅，各自都
    /// "看着对"，那种分家只有把两块东西真画出来、各取众数比一遍才看得见。
    private static func printDesignTokenAudit() {
        say("── 统一化对账（同一种东西必须同一块颜色；量像素，不量常量）")

        let bar = ToolbarBackgroundView(frame: NSRect(x: 0, y: 0, width: 320, height: 42))
        let card = ToastCardView(title: "Grabi-20261006-014000.png",
                                 detail: "已保存　·　存到 ~/Pictures/Grabi", thumbnail: nil)
        card.frame = NSRect(x: 0, y: 0, width: 320, height: 56)

        guard let barShot = renderOpaque(bar), let cardShot = renderOpaque(card),
              let barBase = modeColor(barShot), let cardBase = modeColor(cardShot) else {
            say("    ✗ 两块 HUD 底画不出来或量不到 —— 这一节等于没跑")
            return
        }
        let same = abs(barBase.alpha - cardBase.alpha) < 0.01 && barBase.gray < 0.02 && cardBase.gray < 0.02
        say(String(format: "    %@ 浮条底与结果角标底是同一块：黑 %@ / 透明 %@　vs　黑 %@ / 透明 %@",
                   same ? "✓" : "✗",
                   String(format: "%.2f", barBase.gray) as NSString,
                   String(format: "%.2f", barBase.alpha) as NSString,
                   String(format: "%.2f", cardBase.gray) as NSString,
                   String(format: "%.2f", cardBase.alpha) as NSString))

        // 只比"两块一样"不够 —— 两块一起漂移照样绿。所以还要对上 `Design.Ink.hud` 本身。
        let hudToken = Design.Ink.hud.usingColorSpace(.deviceRGB)
        let matchesToken = abs(barBase.alpha - (hudToken?.alphaComponent ?? 0)) < 0.01
            && barBase.gray < 0.02
        say("    \(matchesToken ? "✓" : "✗") 这块底就是 `Design.Ink.hud` 本身"
            + String(format: "（alpha %.2f）", hudToken?.alphaComponent ?? 0))

        // 角标：覆盖层那条和预览压暗层那条现在是同一个函数画的，值也得对得上。
        let rows = [HUDBadge.Row(text: "1040 × 1160"),
                    HUDBadge.Row(text: "520×580 pt @2x",
                                 font: Design.Fonts.micro, ink: Design.TextInk.secondary)]
        let badgeSize = HUDBadge.size(of: rows)
        let badgeShot = renderBadgeOnly(rows, boxSize: badgeSize)
        let badgeMode = badgeShot.flatMap { modeColor($0, minAlpha: 120) }
        let badgeOK = badgeMode.map {
            abs($0.alpha - Design.Ink.badge.alphaComponent) < 0.01 && $0.gray < 0.02
        } ?? false
        say("    \(badgeOK ? "✓" : "✗") 角标底 = `Design.Ink.badge`，两处角标共用这一个渲染函数"
            + String(format: "　量到 alpha %@",
                     (badgeMode.map { String(format: "%.2f", $0.alpha) } ?? "量不到") as NSString))
        // 两级压暗是**故意的**（截图时还要隔着它判断内容），但两档各是多少得钉住 ——
        // 不然"有意的差别"和"没人管过的漂移"在代码里长得一模一样。
        let dimGap = Design.Ink.dimFocus.alphaComponent - Design.Ink.dimSelect.alphaComponent
        say("    \(dimGap > 0.08 ? "✓" : "✗") 截图遮罩 "
            + String(format: "%.2f", Design.Ink.dimSelect.alphaComponent)
            + " 比预览遮罩 "
            + String(format: "%.2f", Design.Ink.dimFocus.alphaComponent)
            + " 浅（浅的那档要能隔着它选内容），两档都有名字")
    }

    /// 标注合成：屏幕上画的那一笔，必须原样进得了文件。
    ///
    /// 量的是**像素**，不是"函数返回了非 nil"。这一节要抓的是三种真会犯的错：
    /// 尺寸变了（Retina 换算写反）、一笔都没进去（坐标空间搞错，视图点当像素用）、
    /// 粗细不对（归一化宽度在某处被当成像素宽度用了）。
    private static func checkInkComposite() {
        say("── 标注合成（画在屏幕上的那一笔 = 存进文件的那一笔）")
        let viewSize = NSSize(width: 200, height: 100)
        let pixelsWide = 400, pixelsHigh = 200          // 2× 屏上的一块选区
        guard let base = solidImage(width: pixelsWide, height: pixelsHigh,
                                    gray: 0.5) else {
            say("    ✗ 底图造不出来，这一节没跑")
            return
        }
        let view = ImagePreviewView(frame: NSRect(origin: .zero, size: viewSize))
        view.image = base

        // ① 什么都没画：原图直接交回去，不该做一次多余的采样往返
        let untouched = view.composited(base: base)
        let passthroughOK = untouched.map { $0 === base } ?? false
        say("      \(passthroughOK ? "✓" : "✗") 没标注时原图交回（不多走一次位图往返，"
            + "那会悄悄换掉色彩空间和一张图的字节数）")

        // ② 画一条横线：屏幕上 3pt，存进 2× 图就是 6px
        view.inkLayer.addStrokeForSelfTest(Ink.Stroke(
            tool: .pen,
            points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.5)],
            color: .systemRed, width: Ink.normalizedWidth(viewWidth: viewSize.width)))
        guard let out = view.composited(base: base) else {
            say("      ✗ 合成没出图，下面几条都量不了")
            return
        }
        let sizeOK = out.width == pixelsWide && out.height == pixelsHigh
        say("      \(sizeOK ? "✓" : "✗") 存出去的仍是 \(pixelsWide)×\(pixelsHigh)"
            + "　实际 \(out.width)×\(out.height)")

        let redBefore = redPixelCount(base), redAfter = redPixelCount(out)
        say("      \(redBefore == 0 && redAfter > 200 ? "✓" : "✗") 底图本来一个红点都没有（\(redBefore)）"
            + "，合成之后有 \(redAfter) 个")

        // 那条线在正中间，量它竖向占了几个像素：这就是"3pt 的笔"在图上的实际粗细
        let band = redRunAt(column: pixelsWide / 2, in: out)
        let bandOK = abs(band - 6) <= 1
        say("      \(bandOK ? "✓" : "✗") 那一笔在图里占了 \(band)px 高"
            + "（屏幕上 \(Ink.onScreenWidth)pt × 2 倍 = 6px）")

        // ③ 标注那一组在四种形态里都得在：只放在 normal 那一档，识别期间或失败条上
        //    就"没有画笔"了，而用户可能刚圈了一半。收起态例外（那一档整排都收）。
        let controller = InlinePreviewController()
        // 画笔 1 + 形状 4 + 颜色 / 撤销 / 清空 3。形状那一档按模型数，不写死 4：
        // 加第五种形状时这里跟着长，而"四颗各占一颗"那条会去查名字对不对得上。
        let wantInk = 1 + Ink.Shape.allCases.count + 3
        var perMode: [(String, Int)] = []
        for (name, mode): (String, InlinePreviewController.ToolbarMode) in
            [("normal", .normal), ("ocr", .ocr), ("busy", .busy), ("failure", .failure("超时"))] {
            perMode.append((name, inkButtonCount(controller.toolbarStack(for: mode, saved: false))))
        }
        let groupOK = perMode.allSatisfy { $0.1 == wantInk }
        say("      \(groupOK ? "✓" : "✗") 标注那一组 \(wantInk) 颗在四种形态里都在"
            + "　读到 " + perMode.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
            + "　折叠态已删除")
        // 四种形状各占一颗，而且**没有一颗说"下一个"**：一颗按钮循环切四种的时候，
        // 第一下点下去得到的是眼睛没看到的那一种。
        let tips = inkButtonTitles(controller.toolbarStack(for: .normal, saved: false))
        let missing = Ink.Shape.allCases.filter { shape in
            !tips.contains { $0.hasPrefix(shape.name) }
        }.map(\.name)
        say("      \(missing.isEmpty ? "✓" : "✗") 四种形状各占一颗、各自报名字"
            + "　缺 " + (missing.isEmpty ? "0" : missing.joined(separator: "、")))
        let noCycle = !tips.contains { $0.contains("下一个") || $0.contains("再点一下换") }
        say("      \(noCycle ? "✓" : "✗") 反向对照：这一组里一个字都不提「下一个 / 再点一下换」（切法已经没了）")
    }

    private static func solidImage(width: Int, height: Int, gray: CGFloat) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                                         pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: gray, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private static func redPixelCount(_ image: CGImage) -> Int {
        withPixels(image) { buffer, count in
            var found = 0
            for index in stride(from: 0, to: count, by: 4) {
                if Int(buffer[index]) > 150, Int(buffer[index + 1]) < 90,
                   Int(buffer[index + 2]) < 90 { found += 1 }
            }
            return found
        } ?? -1
    }

    /// 某一列上连续红色的最长一段（就是那条线在这儿的粗细）。
    private static func redRunAt(column x: Int, in image: CGImage) -> Int {
        withPixels(image) { buffer, _ in
            var best = 0, run = 0
            for y in 0..<image.height {
                let i = (y * image.width + x) * 4
                if Int(buffer[i]) > 150, Int(buffer[i + 1]) < 90, Int(buffer[i + 2]) < 90 {
                    run += 1; best = max(best, run)
                } else { run = 0 }
            }
            return best
        } ?? -1
    }

    /// 把图摊进一块位图内存，**在上下文还活着的时候**跑完回调。
    ///
    /// 这里原先返回一个 `UnsafeBufferPointer`：上下文一离开作用域，那块内存就还给了
    /// 系统，调用方拿着的是一个悬空指针 —— 判据当场段错误（exit 139）。
    /// 返回指针的写法一律改成"把缓冲区借给一个闭包"。
    private static func withPixels<T>(_ image: CGImage,
                                      _ body: (UnsafeBufferPointer<UInt8>, Int) -> T) -> T? {
        guard let context = pixelContext(width: image.width, height: image.height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let base = context.data else { return nil }
        let count = image.width * image.height * 4
        let buffer = UnsafeBufferPointer(start: base.bindMemory(to: UInt8.self, capacity: count),
                                         count: count)
        return body(buffer, count)
    }

    /// 标注那一组那几颗：按 tooltip 的**开头**认，不按位置 —— 位置以后会调，名字不会。
    /// 用前缀而不是 `contains`：`contains("撤销")` 会把别处提到撤销的按钮也捞进来。
    private static let inkTooltipPrefixes: [String] =
        ["画笔"] + Ink.Shape.allCases.map(\.name) + ["颜色：", "撤销一笔", "清空："]

    private static func inkButtonCount(_ stack: NSStackView) -> Int {
        inkButtonTitles(stack).count
    }

    private static func inkButtonTitles(_ stack: NSStackView) -> [String] {
        stack.arrangedSubviews.compactMap { ($0 as? NSButton)?.toolTip }
            .filter { tip in inkTooltipPrefixes.contains { tip.hasPrefix($0) } }
    }

    /// 不带背景地把一个视图画成位图：对账要的是它自己那块底，不是合成结果。
    private static func renderOpaque(_ view: NSView) -> CGImage? {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = BackdropView(frame: NSRect(origin: .zero, size: view.frame.size))
        canvas.drawsBackdrop = false
        canvas.addSubview(view)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
        withAppearance { canvas.cacheDisplay(in: canvas.bounds, to: rep) }
        return rep.cgImage
    }

    /// 只画一块角标：留 12pt 边距，让 `HUDBadge` 的摆位正好把它落在 (12, 12)。
    private static func renderBadgeOnly(_ rows: [HUDBadge.Row], boxSize: NSSize) -> CGImage? {
        let margin: CGFloat = 12
        let canvas = NSRect(x: 0, y: 0, width: boxSize.width + margin * 2,
                            height: boxSize.height + margin * 2)
        guard let context = pixelContext(width: Int(canvas.width), height: Int(canvas.height)) else { return nil }
        let anchor = NSRect(x: margin, y: margin * 2 + boxSize.height, width: 10, height: 10)
        HUDBadge.draw(rows, below: anchor, in: canvas, context: context)
        return context.makeImage()
    }

    /// 图里最多的那个不透明颜色（灰度 + alpha）。HUD 的底是一整块平色，众数就是它。
    /// - Parameter minAlpha: 最低不透明度。角标那块底本来就是半透明的（0.75），
    ///   按 200/255 筛会把整块底筛没，量出来是「什么都没有」而不是「它很淡」。
    private static func modeColor(_ image: CGImage, minAlpha: Int = 200) -> (gray: CGFloat, alpha: CGFloat)? {
        guard let context = pixelContext(width: image.width, height: image.height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let base = context.data else { return nil }
        let count = image.width * image.height
        let px = base.bindMemory(to: UInt8.self, capacity: count * 4)
        var buckets: [Int: (n: Int, r: Int, g: Int, b: Int, a: Int)] = [:]
        for index in stride(from: 0, to: count * 4, by: 4) {
            let a = Int(px[index + 3])
            guard a > minAlpha else { continue }
            // 按 8 分箱归并抗锯齿的抖动，桶里再累加真实值
            let key = ((Int(px[index]) >> 3) << 16) | ((Int(px[index + 1]) >> 3) << 8) | (Int(px[index + 2]) >> 3)
            var bucket = buckets[key] ?? (0, 0, 0, 0, 0)
            bucket.n += 1
            bucket.r += Int(px[index]); bucket.g += Int(px[index + 1])
            bucket.b += Int(px[index + 2]); bucket.a += a
            buckets[key] = bucket
        }
        guard let best = buckets.max(by: { $0.value.n < $1.value.n }), best.value.n > 0 else { return nil }
        let r = CGFloat(best.value.r) / CGFloat(best.value.n)
        let g = CGFloat(best.value.g) / CGFloat(best.value.n)
        let b = CGFloat(best.value.b) / CGFloat(best.value.n)
        let gray = (r * 0.299 + g * 0.587 + b * 0.114) / 255
        return (gray, CGFloat(best.value.a) / CGFloat(best.value.n) / 255)
    }

    private static func printAppearanceProbe() {
        withAppearance {
            let samples: [(String, NSColor)] = [
                ("underPage", .underPageBackgroundColor),
                ("text", .textBackgroundColor),
                ("window", .windowBackgroundColor),
                ("label", .labelColor)
            ]
            for (name, color) in samples {
                let resolved = color.usingColorSpace(.deviceRGB) ?? color
                let gray = 0.299 * resolved.redComponent
                         + 0.587 * resolved.greenComponent
                         + 0.114 * resolved.blueComponent
                appearanceGrays.append((passLabel, name, gray))
            }
        }
    }

    /// 浅色通道必须明显更亮，否则两次通道其实是同一张图。
    private static func printAppearanceCheck() {
        guard let dark = appearanceProbe["dark"], let light = appearanceProbe["light"] else {
            say("外观对账没做成（缺探针）")
            return
        }
        say(String(format: "── 外观对账：同一设置面板 深色 %.3f / 浅色 %.3f　%@",
                     dark, light,
                     light - dark > 0.25 ? "✓ 浅色通道真的是浅色" : "✗ 浅色通道没生效（动态色没按外观解算）"))
        for (pass, name, gray) in appearanceGrays {
            say(String(format: "    %@ 语义色 %8@ → 灰度 %.3f",
                         pass == "dark" ? "深色" : "浅色", name as NSString, gray))
        }
    }

    /// 在指定外观上下文里跑一段绘制。
    private static func withAppearance(_ body: () -> Void) {
        guard let passAppearance else { body(); return }
        passAppearance.performAsCurrentDrawingAppearance(body)
    }

    // MARK: 工具栏各形态

    private static func renderToolbars(in directory: String) {
        let controller = InlinePreviewController()
        // 五种形态 × 「这张图存过没有」。少了 saved 那一遍，「已保留」那颗禁用按钮
        // 在这套门里从来没被画过 —— 而它正是按完「保留」之后用户盯得最久的一排。
        let modes: [(String, InlinePreviewController.ToolbarMode)] = [
            ("toolbar-normal", .normal),
            ("toolbar-ocr", .ocr),
            ("toolbar-busy", .busy),
            ("toolbar-failure", .failure("识别超时，再点一次试试"))
        ]

        for (name, mode) in modes {
            for saved in [false, true] {
                renderToolbar(controller, stack: controller.toolbarStack(for: mode, saved: saved),
                              base: name, saved: saved, in: directory)
            }
        }
    }

    private static func renderToolbar(_ controller: InlinePreviewController,
                                      stack: NSStackView, base: String, saved: Bool,
                                      in directory: String) {
        let name = base + (saved ? "-kept" : "")
        do {
            let bar = ToolbarBackgroundView(frame: NSRect(x: 0, y: 0, width: 800,
                                        height: InlinePreviewController.toolbarHeight))
            bar.install(stack, animated: false)
            stack.layoutSubtreeIfNeeded()
            accessibilityRoots.append((name, bar))
            save(bar, to: "\(directory)/\(name).png")

            if emitChecks {
                let views = stack.arrangedSubviews
                let separators = views.compactMap { $0 as? NSBox }.count
                // 当前工具栏最少有三组动作：标注 / 主操作 / 保存与丢弃。
                // 组之间必须有真正的分隔线；除此之外不该再出现旧的「收起」尾巴。
                let separatorsOK = separators >= 2
                let lastType = views.last.map { String(describing: type(of: $0)) } ?? "—"
                let ok = separatorsOK
                if !ok { groupingProblems += 1 }
                say(String(format: "  %@ %@：分组分隔线 %d　最后一项是 %@",
                             ok ? "✓" : "✗", name as NSString, separators,
                             lastType as NSString))
                // 「已保存」必须是禁用态：再按一次会在同一秒写出第二个同名文件
                // （ImageWriter 自动加 -2 后缀，用户看到的却是"我明明只点了一次"）。
                let keepButton = views.compactMap { $0 as? NSButton }
                    .first { $0.action == #selector(InlinePreviewController.keep) }
                let keepTitle = keepButton?.title.trimmingCharacters(in: .whitespaces)
                let keepDisabledOK: Bool
                if let keepButton {
                    keepDisabledOK = keepButton.isEnabled == !saved
                        && keepTitle == (saved ? "已保存" : "保存")
                } else {
                    keepDisabledOK = false
                }
                if !keepDisabledOK { groupingProblems += 1 }
                say("      \(keepDisabledOK ? "✓" : "✗") \(name)：保存那颗 = 「\(keepButton?.title.trimmingCharacters(in: .whitespaces) ?? "没有")」"
                    + "　可点=\(keepButton?.isEnabled.description ?? "?")（该 \(!saved)）")

                if base == "toolbar-busy" {
                    // 「在跑」这件事要说明白，而且跑的时候不能把人锁在原地：
                    // busy 这一档以前只有一个转圈，保存 / 丢弃 跟着整排按钮一起没了。
                    let titles = views.compactMap {
                        ($0 as? NSButton)?.title.trimmingCharacters(in: .whitespaces)
                    }
                    let saysWhat = views.contains {
                        ($0 as? NSTextField)?.stringValue.contains("正在识别") == true
                    }
                    // 按后缀而不是全等：已保存那一档写的是「已保存」，
                    // 「丢弃」那一颗落盘之后改叫「移到废纸篓」。
                    let canAct = titles.contains { $0.hasSuffix("保存") }
                        && titles.contains { $0.hasSuffix("丢弃") || $0.hasSuffix("废纸篓") }
                    let busyOK = saysWhat && canAct
                    if !busyOK { groupingProblems += 1 }
                    say("      \(busyOK ? "✓" : "✗") busy 态说了在做什么（\(saysWhat ? "有" : "没有")那句「正在识别…」）"
                        + "，并且保存 / 丢弃 还在（\(canAct ? "能处置" : "识别期间被锁住")）")
                }
            }
        }
        if emitChecks {
            say("  工具栏分组（标注 / 主操作 / 保存与丢弃）问题 \(groupingProblems)"
                  + (groupingProblems == 0 ? " ✓" : " ✗"))
        }
    }

    private static var groupingProblems = 0

    // MARK: 结果角标

    private static func renderToast(in directory: String) {
        // 挑最长的真实文案：文件名 + 「已保存 · 存到 … · 已复制」
        let card = ToastCardView(
            title: "Grabi-20261005-013940.jpg",
            detail: "已保存　·　存到 ~/Pictures/Grabi　·　已复制",
            thumbnail: backdropImage(width: 220, height: 160))
        card.frame = NSRect(x: 0, y: 0, width: toastRenderWidth, height: 64)
        accessibilityRoots.append(("toast", card))
        save(card, to: "\(directory)/toast.png")

        let short = ToastCardView(title: "已识别 12 行文字",
                                  detail: "在原图上按住拖动即可划选",
                                  thumbnail: nil)
        short.frame = NSRect(x: 0, y: 0, width: toastRenderWidth, height: 52)
        save(short, to: "\(directory)/toast-ocr.png")

        // 首次运行那条引导：没有缩略图，而且文案最长，最容易被切成半句
        let welcome = ToastCardView(
            title: "Grabi 已就绪",
            detail: "先点菜单栏的 Grabi 图标授权「屏幕录制」，之后按 ⌃⌥A 截图",
            thumbnail: nil)
        welcome.frame = NSRect(x: 0, y: 0, width: toastRenderWidth, height: 56)
        accessibilityRoots.append(("toast-welcome", welcome))
        save(welcome, to: "\(directory)/toast-welcome.png")

        // 最长的那条真实文案：保存路径很深时必须折行，而**卡片要跟着长高**，
        // 否则折行只是把截断从右边挪到了下面。
        let tall = ToastCardView(
            title: "Grabi-20261005-013940.jpg",
            detail: "已保存　·　存到 ~/Documents/截图存档/2026/十月/项目资料　·　已复制到剪贴板",
            thumbnail: backdropImage(width: 220, height: 160))
        let needed = tall.fittingSize.height
        tall.frame = NSRect(x: 0, y: 0, width: toastRenderWidth, height: max(56, needed))
        save(tall, to: "\(directory)/toast-long-path.png")
        if emitChecks {
            say(String(format: "  两行文案时卡片高 %.0f（单行基线 56）　%@", needed,
                         needed > 62 ? "✓ 会跟着长高" : "✗ 折出来的第二行会被裁掉"))
        }
    }

    /// 和 `ToastHUD` 里的卡片宽度同源，见 `toastCardWidth`。
    private static let toastRenderWidth: CGFloat = toastCardWidth

    // MARK: 压暗层

    private static func renderDimOverlay(in directory: String) {
        let view = DimOverlayView(frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
        view.wantsLayer = false
        view.holeRect = CGRect(x: 300, y: 180, width: 560, height: 380)
        view.badgeText = "2880 × 1800"
        save(view, to: "\(directory)/dim.png", backdrop: false)
    }

    // MARK: 预览 + 文字层 + 边框手柄

    private static func renderPreviewComposition(in directory: String) {
        let size = NSSize(width: 620, height: 400)
        let preview = ImagePreviewView(frame: NSRect(origin: .zero, size: size))
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true
        preview.image = backdropImage(width: 1240, height: 800)

        let lines = (0..<3).map { index -> OCRRecognizer.Line in
            // 行高取 0.05：真实的一行字差不多就是这个比例，
            // 用夸张的框验出来的观感不作数。
            let top = 0.74 - Double(index) * 0.16
            let box = CGRect(x: 0.08, y: top, width: 0.62, height: 0.05)
            var units: [OCRRecognizer.Unit] = []
            for unit in 0..<6 {
                let x = box.minX + CGFloat(unit) * (box.width / 6)
                units.append(.init(text: ["识别", "文字", "自检", "Lite", "Shot", "图"][unit],
                                   boundingBox: CGRect(x: x, y: box.minY,
                                                       width: box.width / 6, height: box.height)))
            }
            return .init(text: "第 \(index + 1) 行识别结果 Grabi 自检", boundingBox: box, units: units)
        }
        preview.installOCRHighlights(lines: lines)
        // 全选一次：选中色带会不会糊住原图上的字，只有真的叠上去才看得出来
        preview.highlightView.selectAll()

        let handles = ResizeHandlesView(frame: NSRect(origin: .zero, size: size))
        handles.textLayer = preview.highlightView
        preview.addSubview(handles)

        accessibilityRoots.append(("preview-composition", preview))
        save(preview, to: "\(directory)/preview-composition.png", backdrop: false)

        // 钉住那一档的壳：投影 + 角落「×」。单独画一张，是因为这两样都是
        // "只在真机上才看得见"的东西 —— 阴影被窗口边界裁、圆底按钮在浅色内容上
        // 会不会隐身，编译和字符串断言都验不到。
        renderPinnedPreviewShell(image: backdropImage(width: 1240, height: 800),
                                 in: directory)

        if emitChecks {
            let overflow = handles.knobOverflowForSelfTest()
            say("  边框手柄绘制矩形是否全在边界内："
                  + (overflow.isEmpty ? "8 个手柄 × 常态/悬停 全部 ✓"
                                      : "✗ \(overflow.count) 个会探出边界被削平 → \(overflow.prefix(6).joined(separator: "，"))"))

            // 「×」的圆形底必须真的画出来。无边框 NSButton + 白色 SF Symbol
            // 在浅色截图上等于隐身 —— 判据落在"合成之后的角落有没有一块深色像素"。
            let shell = pinnedShellForSelfTest(image: backdropImage(width: 1240, height: 800))
            let corner = shell.map { cornerHasDarkBackdrop($0) } ?? false
            say("  角落「×」：" + (corner ? "圆形深底 + 白叉画得出来 ✓"
                                          : "✗ 角落没有深色底，压在浅色内容上会隐身"))
        }
    }

    /// 离屏画一张"钉住的预览壳"（含投影 + 角落「×」），返回给自检量像素。
    private static func renderPinnedPreviewShell(image: CGImage?, in directory: String) {
        guard let shell = pinnedShellForSelfTest(image: image) else {
            say("  ✗ 钉住的预览壳没画出来")
            return
        }
        saveCGImage(shell, to: "\(directory)/preview-pinned-shell.png")
    }

    /// 造一个和真预览同构的容器：投影边距 + 内层圆角图 + 右上角「×」。
    /// 直接复用 `PreviewHoverContainer` 和 `HoverCloseButton`，不是另画一份赝品。
    private static func pinnedShellForSelfTest(image: CGImage?) -> CGImage? {
        let padding: CGFloat = 18
        let inner = NSSize(width: 520, height: 320)
        let size = NSSize(width: inner.width + padding * 2, height: inner.height + padding * 2)
        let container = PreviewHoverContainer(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.30
        container.layer?.shadowRadius = 6
        container.layer?.shadowOffset = CGSize(width: 0, height: -2)
        let ambient = CALayer()
        ambient.masksToBounds = false
        ambient.shadowColor = NSColor.black.cgColor
        ambient.shadowOpacity = 0.18
        ambient.shadowRadius = 12
        ambient.shadowOffset = CGSize(width: 0, height: -4)
        container.layer?.addSublayer(ambient)
        container.ambientShadow = ambient

        let view = ImagePreviewView(frame: NSRect(x: padding, y: padding,
                                                  width: inner.width, height: inner.height))
        view.image = image
        view.wantsLayer = true
        view.layer?.cornerRadius = Design.Radius.card
        view.layer?.masksToBounds = true
        container.addSubview(view)

        let close = HoverCloseButton(frame: NSRect(x: size.width - padding - 30,
                                                   y: size.height - padding - 30,
                                                   width: 26, height: 26))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        close.imagePosition = .imageOnly
        close.contentTintColor = .white
        container.addSubview(close)
        close.layoutSubtreeIfNeeded()

        container.layoutSubtreeIfNeeded()
        container.updateAmbientShadowPath(imageFrame: view.frame)
        return renderOpaque(container)
    }

    /// 右上角那一小块里有没有足够多的深色像素（「×」的圆形底）。
    private static func cornerHasDarkBackdrop(_ image: CGImage) -> Bool {
        let side = min(60, min(image.width, image.height))
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return false }
        let bpp = image.bitsPerPixel / 8
        let stride = image.bytesPerRow
        let originX = image.width - side - 18
        let originY = 18
        var dark = 0
        for y in originY..<(originY + side) {
            for x in originX..<(originX + side) {
                let offset = y * stride + x * bpp
                guard offset + 2 < CFDataGetLength(data) else { continue }
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                if (r + g + b) / 3 < 90 { dark += 1 }
            }
        }
        return dark > 40
    }

    // MARK: 标注的三种"画出来才作数"的样子

    /// 图上真有笔 / 工具栏的选中态 / 笔尖光标。
    ///
    /// 这一节是用户反馈引出来的：形状改成全部列举、第一下就选中、颜色点开候选色、
    /// 画笔换光标 —— 四件改的都是眼睛要看的东西，而那时这套门里读的全是字符串
    /// （tooltip 写了什么、菜单有几条、tag 对不对）。字符串对得上不代表画出来对。
    private static func renderInkStates(in directory: String) {
        let size = NSSize(width: 620, height: 400)
        let preview = ImagePreviewView(frame: NSRect(origin: .zero, size: size))
        preview.image = backdropImage(width: 1240, height: 800)
        // 五种工具各画一笔，颜色 / 线宽全用表里那几档 —— 一张图同时看到
        // "形状对不对、颜色分不分得开、线宽有没有生效"。
        // 底图左半边是白的、右半边是黑的，所以深色那笔一律放左边。
        func width(_ points: CGFloat) -> CGFloat {
            Ink.normalizedWidth(viewWidth: size.width, screenWidth: points)
        }
        let samples: [(Ink.Tool, NSColor, CGFloat, [CGPoint])] = [
            (.pen, .systemRed, 2, [CGPoint(x: 0.06, y: 0.86), CGPoint(x: 0.16, y: 0.72),
                                   CGPoint(x: 0.28, y: 0.88), CGPoint(x: 0.40, y: 0.70)]),
            (.shape(.rectangle), .systemYellow, 3, [CGPoint(x: 0.06, y: 0.24),
                                                    CGPoint(x: 0.30, y: 0.52)]),
            (.shape(.ellipse), .systemBlue, 5, [CGPoint(x: 0.58, y: 0.58),
                                                CGPoint(x: 0.84, y: 0.90)]),
            (.shape(.arrow), .systemGreen, 3, [CGPoint(x: 0.58, y: 0.16),
                                               CGPoint(x: 0.80, y: 0.42)]),
            // 黑笔压在白底那一半：它是最容易"画了等于没画"的一档。
            (.shape(.line), .black, 5, [CGPoint(x: 0.34, y: 0.30), CGPoint(x: 0.48, y: 0.10)])
        ]
        for (tool, color, points, path) in samples {
            preview.inkLayer.addStrokeForSelfTest(
                Ink.Stroke(tool: tool, points: path, color: color, width: width(points)))
        }
        accessibilityRoots.append(("preview-ink", preview))
        let inkShot = renderOpaque(preview)
        saveCGImage(inkShot, to: "\(directory)/preview-ink.png")

        // ② 工具栏那一排的三种状态各画一张：没有历史 / 有历史 / 有历史且点中了矩形。
        //    分三张是因为"画完一笔之后那两颗自己亮了"和"点中了哪颗"是两件事，
        //    挤在一张里对账，少了一条也看不出来。
        let controller = InlinePreviewController()
        func bar(_ name: String) -> (CGImage?, ToolbarBackgroundView, NSStackView) {
            let view = ToolbarBackgroundView(frame: NSRect(x: 0, y: 0, width: 800,
                                        height: InlinePreviewController.toolbarHeight))
            let stack = controller.toolbarStack(for: .normal, saved: false)
            view.install(stack, animated: false)
            view.layoutSubtreeIfNeeded()
            let shot = renderOpaque(view)
            saveCGImage(shot, to: "\(directory)/\(name).png")
            return (shot, view, stack)
        }
        func inkButton(_ stack: NSStackView, named: String) -> NSButton? {
            stack.arrangedSubviews.compactMap { $0 as? NSButton }
                .first { $0.toolTip?.hasPrefix(named) == true }
        }
        let (bareShot, bareBar, bareStack) = bar("toolbar-ink-bare")
        // 挂两层历史进去：这一排里只有「撤销 / 清空」的状态取决于历史，
        // 而离屏只画工具栏时没有面板、也就没有标注层，那颗只能按"没东西可撤"画。
        let history = InkLayer(frame: NSRect(origin: .zero, size: size))
        for (tool, color, points, path) in samples.prefix(2) {
            history.addStrokeForSelfTest(
                Ink.Stroke(tool: tool, points: path, color: color, width: width(points)))
        }
        controller.attachInkLayerForSelfTest(history)
        let (idleShot, _, _) = bar("toolbar-ink-idle")
        // 点第一下矩形：走 `performClick`，和用户那一下是同一条路。
        guard let rectButton = inkButton(bareStack, named: "矩形") else {
            say("  ✗ 找不到「矩形」那颗，选中态那两张没画成")
            return
        }
        rectButton.performClick(nil)
        let (activeShot, activeBar, _) = bar("toolbar-ink-active")
        accessibilityRoots.append(("toolbar-ink-active", activeBar))

        // ③ 笔尖光标：放大八倍、压在深浅两块底上。热点偏一格，用户圈的就差两像素。
        let cursorShot = renderCursorOnSplit(InkLayer.penCursor.image)
        saveCGImage(cursorShot, to: "\(directory)/ink-cursor.png")

        guard emitChecks else { return }
        say("── 标注画出来是什么样（图上落墨 / 选中态 / 笔尖光标）")
        // 一档颜色在成图里出现了几次。先换算到 sRGB 再比：`NSColor.systemRed` 是
        // 带色彩空间的目录色，直接取 `redComponent` 拿到的是另一个数（或者干脆崩）。
        func inkCount(_ image: CGImage, _ color: NSColor) -> Int {
            guard let srgb = color.usingColorSpace(.sRGB) else { return -1 }
            let want = [Int(srgb.redComponent * 255), Int(srgb.greenComponent * 255),
                        Int(srgb.blueComponent * 255)]
            return withPixels(image) { px, count in
                var hits = 0
                for index in stride(from: 0, to: count, by: 4) where px[index + 3] > 200 {
                    if abs(Int(px[index]) - want[0]) < 26,
                       abs(Int(px[index + 1]) - want[1]) < 26,
                       abs(Int(px[index + 2]) - want[2]) < 26 { hits += 1 }
                }
                return hits
            } ?? -1
        }
        // 五种工具各留一块墨。判据是"这一档颜色在图里出现了几次"而不是"有几次"：
        // 少一种形状、或者两档颜色画成了同一个，只数总数看不出来。
        if let inkShot {
            let short = samples.filter { inkCount(inkShot, $0.1) < 40 }
                .map { "\(toolName($0.0))=\(inkCount(inkShot, $0.1))" }
            say("      \(short.isEmpty ? "✓" : "✗") 五种工具在图上各留了一块墨（每种 ≥40 px）"
                + (short.isEmpty ? "" : "　缺 " + short.joined(separator: "、")))
            // 反向对照：底图（没画之前）里这些颜色一块都没有 —— 上面那条不是白送的分。
            let polluted = [NSColor.systemYellow, .systemGreen, .systemBlue]
                .compactMap { color -> String? in
                    let n = preview.image.map { inkCount($0, color) } ?? -1
                    return n > 40 ? "\(n)" : nil
                }
            say("      \(polluted.isEmpty ? "✓" : "✗") 反向对照：底图里这三档颜色本来一块都没有"
                + (polluted.isEmpty ? "" : "　读到 \(polluted.joined(separator: "、"))"))
        } else {
            say("      ✗ 图上落墨那张没画出来")
        }

        // 没有历史 → 有历史：这一排里只该有「撤销 / 清空」两颗变亮，别的像素一个不动。
        // 差异必须落在它自己那两块里 —— 不然"整排都跟着变"也会被算成"历史生效了"。
        if let bareShot, let idleShot, let activeShot {
            let scale = CGFloat(bareShot.width) / bareBar.bounds.width
            let historyBox: NSRect? = {
                let two = [inkButton(bareStack, named: "撤销"), inkButton(bareStack, named: "清空")]
                    .compactMap { $0 }
                guard two.count == 2 else { return nil }
                let union = two.dropFirst().reduce(two[0].convert(two[0].bounds, to: bareBar)) {
                    $0.union($1.convert($1.bounds, to: bareBar))
                }
                // 位图第 0 行是顶部，视图坐标 y 朝上 —— 期望框得翻一次。
                return NSRect(x: union.minX * scale,
                              y: (bareBar.bounds.height - union.maxY) * scale,
                              width: union.width * scale, height: union.height * scale)
            }()
            let lit = historyBox.flatMap { pixelDiff(a: bareShot, b: idleShot, inside: $0) }
            say("      \((lit?.count ?? 0) > 40 && lit?.inside == true ? "✓" : "✗") "
                + "画完一笔之后「撤销 / 清空」自己亮了（差 \(lit?.count ?? 0) 个像素，"
                + "全在那两颗的格子里）")
            if let box = lit?.box, let want = historyBox {
                say(String(format: "        差集 %@　该落在 %@",
                             NSStringFromRect(box), NSStringFromRect(want)))
            }
            let chip = pixelDiff(a: idleShot, b: activeShot, inside: nil)
            say("      \((chip?.count ?? 0) > 120 ? "✓" : "✗") 点中之后那颗自己画出了选中底"
                + "（差 \(chip?.count ?? 0) 个像素）　·　不是只有 tooltip 换了词")
            // 选中不许把整排按钮挤得搬家：三张一样宽，
            // 否则刚点完一颗，旁边几颗就从鼠标底下溜走了。
            let widths = [bareShot.width, idleShot.width, activeShot.width]
            say("      \(Set(widths).count == 1 ? "✓" : "✗") 三种状态这一排一样宽（读到 "
                + widths.map(String.init).joined(separator: " / ") + " px）"
                + "　·　按钮不许从鼠标底下溜走")
            // 整排的实际宽度是硬约束，不是观感问题：这一排 14 颗，宽到放不下时
            // `toolbarOrigin` 有夹取兜底（逻辑门里那七种摆法测过），但兜底不是设计。
            // 五种形态各量一次，最宽的那一种（失败条要带一句中文提示）定上限。
            var perMode: [(String, CGFloat)] = []
            for (name, mode): (String, InlinePreviewController.ToolbarMode) in
                [("normal", .normal), ("ocr", .ocr), ("busy", .busy),
                 ("failure", .failure("识别超时，再点一次试试"))] {
                let measure = ToolbarBackgroundView(
                    frame: NSRect(x: 0, y: 0, width: 900,
                                  height: InlinePreviewController.toolbarHeight))
                let stack = controller.toolbarStack(for: mode, saved: false)
                measure.install(stack, animated: false)
                measure.layoutSubtreeIfNeeded()
                perMode.append((name, stack.fittingSize.width.rounded(.up)))
            }
            let widest = perMode.map(\.1).max() ?? 0
            let ceiling = InlinePreviewController.toolbarWidthCeiling
            say("      \(widest <= ceiling ? "✓" : "✗") 五种形态最宽的一排 \(Int(widest))pt"
                + "　·　上限 \(Int(ceiling))pt　读到 "
                + perMode.map { "\($0.0)=\(Int($0.1))" }.joined(separator: " "))
            // 反向对照：从**最宽的那一档**再多塞两颗按钮必须撞红 ——
            // 不然这条"上限"就是一条永远绿着的装饰。
            let stuffed = controller.toolbarStack(for: .ocr, saved: false)
            let probeBar = ToolbarBackgroundView(
                frame: NSRect(x: 0, y: 0, width: 900,
                              height: InlinePreviewController.toolbarHeight))
            probeBar.install(stuffed, animated: false)
            for _ in 0..<2 {
                stuffed.addArrangedSubview(NSButton(title: "", target: nil, action: nil))
            }
            probeBar.layoutSubtreeIfNeeded()
            let stuffedWidth = stuffed.fittingSize.width.rounded(.up)
            say("      \(stuffedWidth > ceiling ? "✓" : "✗") 反向对照：多塞两颗按钮就 "
                + "\(Int(stuffedWidth))pt，撞破上限（这条不是永远绿着的装饰）")
        } else {
            say("      ✗ 工具栏那三张里有一张没画出来，这一节没跑成")
        }
        say("      \(cursorShot != nil ? "✓" : "✗") 笔尖光标画到了盘上（放大 8×、压在深浅两块底上）")
    }

    private static func toolName(_ tool: Ink.Tool) -> String {
        switch tool {
        case .pen: return "画笔"
        case .shape(let shape): return shape.name
        }
    }

    /// 把一枚光标放大八倍、压在"左白右灰"两块底上画成一张图。
    ///
    /// 光标平时只有 18pt，缩略图里看它就是个糊点；放大八倍才看得出环圆不圆、
    /// 那圈深色描边在浅底上有没有断。两块底是因为它要出现在任何截图上。
    private static func renderCursorOnSplit(_ image: NSImage) -> CGImage? {
        let scale: CGFloat = 8
        let side = image.size.width * scale
        let box = NSSize(width: side * 2 + 48, height: side + 48)
        let canvas = NSImage(size: box, flipped: false) { rect in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: rect.midX, height: rect.height).fill()
            NSColor(white: 0.16, alpha: 1).setFill()
            NSRect(x: rect.midX, y: 0, width: rect.midX, height: rect.height).fill()
            let draw = NSSize(width: side, height: image.size.height * scale)
            image.draw(in: NSRect(x: 24, y: (rect.height - draw.height) / 2,
                                  width: draw.width, height: draw.height))
            image.draw(in: NSRect(x: rect.midX + 24, y: (rect.height - draw.height) / 2,
                                  width: draw.width, height: draw.height))
            return true
        }
        var rect = NSRect(origin: .zero, size: box)
        return canvas.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// 一张已经成形的位图直接落盘，并把成败记进清点。
    ///
    /// `save` 那条路要自己开窗、自己画底，而这里三张图都已经有了自己的位图
    /// （或者本来就该压在指定的底上，比如那枚光标压在深浅两块上）。
    /// 少一张会同时被"出图清点"和退出码抓到，不像静默 return 那样糊过去。
    private static func saveCGImage(_ image: CGImage?, to path: String) {
        let shotName = (path as NSString).lastPathComponent
        guard let image,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width,
                                         pixelsHigh: image.height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { renderShots.append((passLabel, shotName, false)); return }
        ctx.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil
        else { renderShots.append((passLabel, shotName, false)); return }
        renderShots.append((passLabel, shotName, true))
    }

    // MARK: 设置面板

    /// 四个设置面板逐个画一遍。纯代码拼的布局，间距和截断不看着验一遍不放心。
    private static func renderSettings(in directory: String) {
        let controller = SettingsWindowController(onSettingsChanged: {})
        guard let content = controller.window?.contentView else {
            say("设置窗口没建起来，跳过")
            return
        }
        let names = ["save", "ocr", "hotkey", "runtime"]
        for (index, name) in names.enumerated() {
            controller.showPane(at: index)
            // showPane 里换窗口高度用的是带动画的 setFrame，不先把这一轮动画跑完
            // 就抓图，抓到的是动画中途的压缩状态 —— 那是工具的错觉，不是产品的样子。
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            // 先把 alpha 和整棵子树的布局跑完，再打印再抓图。
            // 顺序很关键：一个从没上过屏的窗口在 runloop 里不会自己排版，
            // 先 dump 会读到上一帧的陈旧 frame —— 之前那几次"设置面板塌陷"
            // 有一半就是工具读到了脏数据。
            forceVisible(content)
            content.layoutSubtreeIfNeeded()
            if ProcessInfo.processInfo.environment["LITESHOT_DUMP_TREE"] != nil {
                dumpTree(content, depth: 0)
            }
            accessibilityRoots.append(("settings-\(name)",
                                      controller.paneViewForSelfTest(index) ?? content))
            let paneShot = saveInPlace(content, to: "\(directory)/settings-\(name).png")
            if name == "save", let paneShot, let brightness = meanBrightness(paneShot) {
                appearanceProbe[passLabel] = brightness
            }
            say("  settings-\(name): \(Int(content.bounds.width))×\(Int(content.bounds.height))")
            printPaneFit(in: content, needed: controller.lastPaneHeight, visible: controller.paneHeightsForSelfTest.visible,
                         document: controller.paneHeightsForSelfTest.document,
                         scroll: controller.paneScrollForSelfTest)
            // 越界体检的根改成**面板自己**那棵树：`overflowingViews` 有意不走进
            // NSScrollView（documentView 比窗口大是设计如此），而面板现在住在滚动视图里
            // —— 从窗口往下走就一个设置控件都查不到了，检查会静默变成永远绿。
            layoutHits += overflowingViews(in: controller.paneViewForSelfTest(index) ?? content)
                .map { "\(passLabel)/settings-\(name) · \($0)" }
            overflowSurfaces[passLabel, default: []].insert("settings-\(name)")
        }

        // 「文件名格式」的示例行在模板被清洗时会多出一段说明，而且是**单行**的 ——
        // 放不下就是被切成「…」。填一个非法 + 超长的模板，量一次最坏情况。
        controller.showPane(at: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        forceVisible(content)
        controller.setPatternForSelfTest("我的截图/{datetime}/{datetme}/一长串用来把示例行撑爆的中文模板名")
        content.layoutSubtreeIfNeeded()
        saveInPlace(content, to: "\(directory)/settings-save-sanitized.png")
        say("  settings-save（模板被清洗 + 示例折行）: "
              + "\(Int(content.bounds.width))×\(Int(content.bounds.height))")
        printPaneFit(in: content, needed: controller.lastPaneHeight, visible: controller.paneHeightsForSelfTest.visible,
                     document: controller.paneHeightsForSelfTest.document,
                     scroll: controller.paneScrollForSelfTest)
        // 示例行的竖向余量、⌘ 键切面板，两件检查各自独立跑：谁失败都不该顺手让
        // 另一组数字从输出里消失（早退 = 那一遍没检查，而屏幕上看着一切正常）。
        if let fit = controller.nameExampleFitForSelfTest, emitChecks {
            // 宽度单独判：长文案的正确反应是**折行**，不是把整个窗口顶宽。
            let widthOK = content.bounds.width <= 620.5
            say(String(format: "      %@ 窗口宽 %.0f（模板再长也不该把设置窗顶宽）",
                         widthOK ? "✓" : "✗", content.bounds.width))
            let slack = fit.given - fit.needed
            say(String(format: "  示例行最坏情况：宽 %.0f　折 %d 行　需要 %.0f　给了 %.0f　余量 %+0.0f　%@",
                         fit.width, fit.lines, fit.needed, fit.given, slack,
                         slack >= -0.5 ? "✓ 放得下" : "✗ 竖向被切"))
        } else if emitChecks {
            say("      ✗ 示例行标签读不到，宽度/折行这一组没跑成")
        }
        checkPaneKeyShortcuts(controller)
        checkHotKeyRecorder(controller)

        // 最小宽度那一趟。面板是按 588 的内容宽设计的，而窗口能被拖到 `minSize.width` ——
        // 那一档从前从来没量过（越界体检只在默认宽度上跑）。现在 minSize 是从面板自己的
        // fitting 宽算出来的，所以两头都要验：算出来的够不够宽、真拖到那里会不会切掉控件。
        if let window = controller.window {
            let minWidth = window.minSize.width
            let keepHeight = content.bounds.height
            var widestPane: CGFloat = 0
            for (index, name) in names.enumerated() {
                window.setContentSize(NSSize(width: minWidth, height: keepHeight))
                controller.showPane(at: index, animate: false)
                RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                forceVisible(content)
                content.layoutSubtreeIfNeeded()
                let pane = controller.paneViewForSelfTest(index) ?? content
                widestPane = max(widestPane, pane.fittingSize.width)
                saveInPlace(content, to: "\(directory)/settings-\(name)-minwidth.png")
                layoutHits += overflowingViews(in: pane)
                    .map { "\(passLabel)/settings-\(name)@minWidth · \($0)" }
                overflowSurfaces[passLabel, default: []].insert("settings-\(name)@minWidth")
            }
            if emitChecks {
                let fits = minWidth + 0.5 >= widestPane + 32
                say(String(format: "      %@ 能拖到的最窄宽 %.0f　面板最宽需要 %.0f + 32 留白 = %.0f"
                                + "（拖更窄也不会切：窗口不许比这更窄）",
                             fits ? "✓" : "✗", minWidth, widestPane, widestPane + 32))
                say(String(format: "      %@ minSize 是从面板算的、不是手抄的（读到 %.0f）",
                             controller.minContentWidth == minWidth ? "✓" : "✗",
                             controller.minContentWidth))
            }
            window.setContentSize(NSSize(width: 620, height: keepHeight))
        }
    }

    /// 状态行的分色**按像素量**：带 ⚠ 的那行该是最亮的一行，陈述行该比它暗一档。
    ///
    /// 为什么非要量像素：`advisoryAttributed` 的逐行前景色是纯函数，逻辑自检里
    /// 判它怎么判都对 —— 而真实界面上它曾经整段都是橙的，因为赋值之后又被
    /// `textColor` 盖了一道。这种"设了等于没设"只有从图上量才看得见。
    private static func printAdvisoryInkCheck() {
        // 两遍都跑：这一节量的本来就是"某个外观下这行字到底显不显眼"，
        // 只跑深色那遍会漏掉浅色卡片上真正糊掉的那一档（见 printSurfaceContrastSweep）。
        let controller = SettingsWindowController(onSettingsChanged: {})
        controller.showPane(at: 3, animate: false)
        guard let pane = controller.paneViewForSelfTest(3),
              let label = controller.runStateLabelForSelfTest,
              let superview = label.superview else {
            say("── 状态行分色（像素实测）　✗ 拿不到运行面板或状态行，这一组没跑成")
            return
        }
        // 文案自己给：判据要的是"哪一行属于哪一句"，而这只有构造时才说得准。
        // ⚠ 用 U+26A0 + U+FE0E，和 `AutoStartManager` 发出去的那份一模一样。
        let statement = "当前机制：未启用　·　系统未找到记录"
        let problem = "\u{26A0}\u{FE0E} Grabi 当前不在 ~/Applications 或 /Applications 下，"
            + "系统会拒绝自动启动它。请把它拖到「应用程序」文件夹后再开启自启动。"

        /// 把状态行那块矩形里的文字按"行"分组，量每行的暖度（R-B）和亮度。
        /// 分色从前靠"橙 vs 灰"，现在靠"亮 vs 次级"—— 两个都量，报出来才有得核对。
        ///
        /// "哪些像素算字"是相对**这块矩形自己的底色**判的（取出现最多的那档颜色当底），
        /// 不是写死一个亮度阈值：深色通道下字比底亮、浅色通道下反过来，
        /// 写死阈值的那版只在深色跑得通，浅色一遍会一行都量不到而假绿。
        func bands(of image: CGImage)
            -> [(rows: Int, ink: Int, warmth: Int, luma: Int, contrast: CGFloat)] {
            let rep = NSBitmapImageRep(cgImage: image)
            let scale = CGFloat(image.width) / max(pane.bounds.width, 1)
            let rect = pane.convert(label.frame, from: superview)
            let top = pane.isFlipped ? rect.minY : pane.bounds.height - rect.maxY
            let y0 = max(0, Int(top * scale)), y1 = min(image.height - 1, Int((top + rect.height) * scale))
            let x0 = max(0, Int(rect.minX * scale)), x1 = min(image.width - 1, Int(rect.maxX * scale))
            func luma(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
                0.299 * r + 0.587 * g + 0.114 * b
            }
            var buckets: [Int: (n: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]
            for y in y0...max(y0, y1) {
                for x in x0...max(x0, x1) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let key = (Int(c.redComponent * 15) << 8) | (Int(c.greenComponent * 15) << 4)
                        | Int(c.blueComponent * 15)
                    var bucket = buckets[key] ?? (0, 0, 0, 0)
                    bucket.n += 1
                    bucket.r += c.redComponent * 255
                    bucket.g += c.greenComponent * 255
                    bucket.b += c.blueComponent * 255
                    buckets[key] = bucket
                }
            }
            let bgLuma: CGFloat
            var bgRGB: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
            if let base = buckets.values.max(by: { $0.n < $1.n }) {
                let n = CGFloat(max(base.n, 1))
                bgRGB = (base.r / n, base.g / n, base.b / n)
                bgLuma = luma(bgRGB.0, bgRGB.1, bgRGB.2)
            } else {
                bgLuma = -1
            }
                func finish(_ run: (rows: Int, ink: Int, warm: Int, lum: Int,
                                    r: Int, g: Int, b: Int))
                    -> (rows: Int, ink: Int, warmth: Int, luma: Int, contrast: CGFloat) {
                    let n = CGFloat(max(run.ink, 1))
                    let ratio = contrastRatio((CGFloat(run.r) / n, CGFloat(run.g) / n,
                                               CGFloat(run.b) / n, 1), bgRGB)
                    return (run.rows, run.ink, run.warm / max(run.ink, 1),
                            run.lum / max(run.ink, 1), ratio)
                }
            var out: [(rows: Int, ink: Int, warmth: Int, luma: Int, contrast: CGFloat)] = []
            var run: (rows: Int, ink: Int, warm: Int, lum: Int, r: Int, g: Int, b: Int) =
                (0, 0, 0, 0, 0, 0, 0)
            for y in y0...max(y0, y1) {
                var ink = 0, warm = 0, lum = 0, sr = 0, sg = 0, sb = 0
                for x in x0...max(x0, x1) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let r = c.redComponent * 255, g = c.greenComponent * 255, b = c.blueComponent * 255
                    if abs(luma(r, g, b) - bgLuma) < 25 { continue }
                    ink += 1
                    warm += Int(r - b)
                    lum += Int(luma(r, g, b))
                    sr += Int(r); sg += Int(g); sb += Int(b)
                }
                if ink > 3 {
                    run.rows += 1; run.ink += ink; run.warm += warm; run.lum += lum
                    run.r += sr; run.g += sg; run.b += sb
                } else if run.rows > 0 {
                    out.append(finish(run))
                    run = (0, 0, 0, 0, 0, 0, 0)
                }
            }
            if run.rows > 0 { out.append(finish(run)) }
            return out
        }

        func shoot(_ name: String) -> CGImage? {
            var out: CGImage?
            withAppearance { out = saveInPlace(pane, to: "\(renderRoot)/\(passLabel)/\(name).png") }
            return out
        }

        controller.setAdvisoryForSelfTest(lines: [statement, problem], warning: true)
        pane.layoutSubtreeIfNeeded()
        let warned = shoot("settings-runtime-ink")
        // 声明的那两档要在**换成非警示文案之前**取：填第二次就把第一份覆盖了
        // （第一版正是这么写出两行同对比的假红的）。
        var declaredLines: [[NSColor]] = []
        var declaredBG: (CGFloat, CGFloat, CGFloat)?
        if let warned {
            // 动态色必须在当前外观里解算：不套这层，浅色那遍会拿深色的 labelColor（白）
            // 去当"要避开的颜色"，结果避开的是卡片本身，取到的"底"反而是字的颜色。
            withAppearance {
                declaredLines = lineInks(of: label)
                declaredBG = localBackground(warned, root: pane, view: label,
                                             avoiding: declaredLines.flatMap { $0.map { rgb($0) } })
            }
        }
        controller.setAdvisoryForSelfTest(lines: [statement, problem], warning: false)
        pane.layoutSubtreeIfNeeded()
        let calm = shoot("settings-runtime-ink-calm")

        say("── 状态行分色（\(passLabel)：像素实测，陈述行不许跟着喊）")
        guard let warned, let calm else {
            say("    ✗ 状态行那两张图没画出来，这一组没跑成")
            return
        }
        let hot = bands(of: warned)
        guard hot.count >= 2 else {
            say("    ✗ 只量到 \(hot.count) 行文字：状态行没折出两行，分色无从判起")
            return
        }
        // 行会被折行切成多段：第一段属于陈述句，最后一段属于 ⚠ 那行。
        let first = hot[0], last = hot[hot.count - 1]
        // 像素那两档只当"画面上真的有两档"的证据：11pt 细笔画的对比度会被反锯齿
        // 往下压，深色那遍两档被压得几乎贴在一起（3.29 vs 3.98），拿它当判据会误报。
        say(String(format: "    · 警示态：共 %d 段文字　像素实测首段 %.2f:1、末段 %.2f:1"
                        + "（%d / %d 个文字像素）",
                   hot.count, first.contrast, last.contrast, first.ink, last.ink))
        // 判据走"声明的字色 × 量出来的底"：这两半各自都准。
        let lineRatios: [[CGFloat]] = declaredLines.map { colors in
            colors.compactMap { color -> CGFloat? in
                guard let bg = declaredBG,
                      let c = withAppearanceResolved(color) else { return nil }
                return contrastRatio(c, bg)
            }
        }
        let headRatio = lineRatios.first?.max() ?? -1
        let tailRatio = lineRatios.last?.min() ?? -1
        let splitOK = headRatio > 0 && tailRatio > headRatio * 1.25
        say(String(format: "    · 声明字色对同一块底：陈述行 %.2f:1　⚠ 行 %.2f:1",
                   headRatio, tailRatio))
        say("    \(splitOK ? "✓" : "✗") ⚠ 那行和陈述行的对比确实分开了（同色 = 逐行上色被盖掉）")
        let calmBands = bands(of: calm)
        let calmSpread = (calmBands.map(\.contrast).max() ?? 0)
            - (calmBands.map(\.contrast).min() ?? 0)
        // 把"量到多少文字像素"一起报出来：非警示态那两行本来就更暗，
        // 只报暖度的话，"一行都没量到"看起来和"量到了但都是灰的"一样干净。
        say(String(format: "    · 非警示态：各段对比最大差 %.2f　共 %d 段 %d 个文字像素",
                   calmSpread, calmBands.count, calmBands.reduce(0) { $0 + $1.ink }))
        say("    \(calmSpread <= 0.6 ? "✓" : "✗") 不警示时没有哪一行在自己喊（对比差 ≤0.6）")
    }

    /// 在当前外观上下文里把动态色解成 sRGB 分量。
    private static func withAppearanceResolved(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        var out: (CGFloat, CGFloat, CGFloat, CGFloat)?
        withAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            out = (c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255,
                   c.alphaComponent)
        }
        return out
    }

    /// 一个 label 的 attributed 串里，每一行声明了哪些前景色（按行切开逐段收）。
    private static func lineInks(of field: NSTextField) -> [[NSColor]] {
        let text = field.attributedStringValue
        var lines: [[NSColor]] = [[]]
        for index in 0..<text.length {
            if text.attributedSubstring(from: NSRange(location: index, length: 1)).string == "\n" {
                lines.append([])
                continue
            }
            guard let color = text.attribute(.foregroundColor, at: index,
                                             effectiveRange: nil) as? NSColor else { continue }
            if lines[lines.count - 1].last != color { lines[lines.count - 1].append(color) }
        }
        return lines
    }

    private static func rgb(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        return (rgb.redComponent * 255, rgb.greenComponent * 255, rgb.blueComponent * 255)
    }

    /// 逐面对比：每个面上"看得见的字"用**自己声明的字色**，去对**量出来的那块底**。
    ///
    /// 为什么不整段都从像素取：小字号的笔画在位图里很少有整像素被字色盖满，
    /// 从图上取"字"会系统性偏低（同一行 `secondaryLabelColor` 的 11pt 中文，
    /// 标称 4.7:1，像素法只量到 2.9:1），拿这种数去判绝对线会误伤。
    /// 但**底**是平色，取众数就准 —— 所以字色走视图树、底色走像素，各用自己可靠的那一半。
    ///
    /// 判据两档：有彩度的字 ≥4.5:1（橙 / 红 / 绿是我们自己选的），
    /// 灰阶 ≥3:1（Apple 的 label / secondary 层级，低于这条就是"看得见的字看不清"）。
    /// 禁用态与隐藏的控件不判 —— 那正是系统表达"此刻不能点"的手段，WCAG 也豁免。
    private static func printSurfaceContrastSweep() {
        let preview = InlinePreviewController()
        var surfaces: [(String, NSView)] = []
        for (name, mode): (String, InlinePreviewController.ToolbarMode) in
            [("normal", .normal), ("ocr", .ocr), ("busy", .busy),
             ("failure", .failure("识别超时，再点一次试试"))] {
            for saved in [false, true] {
                let stack = preview.toolbarStack(for: mode, saved: saved)
                let bar = ToolbarBackgroundView(frame: NSRect(x: 0, y: 0, width: 800,
                                        height: InlinePreviewController.toolbarHeight))
                bar.install(stack, animated: false)
                stack.layoutSubtreeIfNeeded()
                bar.layoutSubtreeIfNeeded()
                // kept 那一档顺带验一件事：禁用态的「已保留」确实被排除在对比度判定外
                // （系统靠"变淡"表达不能点，硬要它达到 4.5:1 反而是错的）。
                surfaces.append((name + (saved ? "-kept" : ""), bar))
            }
        }
        let toast = ToastCardView(title: "Grabi-20261005-013940.jpg",
                                  detail: "已保存　·　存到 ~/Pictures/Grabi　·　已复制",
                                  thumbnail: backdropImage(width: 220, height: 160))
        toast.frame = NSRect(x: 0, y: 0, width: toastRenderWidth, height: 64)
        surfaces.append(("toast", toast))
        let settings = SettingsWindowController(onSettingsChanged: {})
        for (index, name) in ["save", "ocr", "hotkey", "runtime"].enumerated() {
            settings.showPane(at: index, animate: false)
            guard let pane = settings.paneViewForSelfTest(index) else { continue }
            pane.layoutSubtreeIfNeeded()
            surfaces.append(("settings-\(name)", pane))
        }
        var offenders: [String] = []
        var judged = 0
        var noBackground = 0
        var faces = 0
        var worst = (what: "", ratio: CGFloat(99))
        // 每一处量到的字都留一份，`LITESHOT_DEBUG_INK` 打开时按最低的几处倒出来。
        // 只倒 offender 不够用：刚过线的那几处（3.0x 对 3.0 的门槛）恰恰是
        // "到底是真糊还是采样偏了"唯一能看的样本。
        var spots: [(ratio: CGFloat, bar: CGFloat, what: String,
                     bg: (CGFloat, CGFloat, CGFloat), ink: (CGFloat, CGFloat, CGFloat))] = []
        say("── 逐面对比（工具栏 / 提示条 / 设置窗：看得见的字不许糊在自己的底上）")
        for (name, root) in surfaces {
            guard let image = saveInPlace(root,
                                          to: "\(renderRoot)/\(passLabel)/sweep-\(name).png") else {
                say("    ✗ sweep-\(name) 没画出来，这一面没量到")
                continue
            }
            faces += 1
            var views: [NSView] = []
            collectInkViews(in: root, into: &views)
            // 解算动态色必须在当前外观里做：不套这一层，浅色那遍会拿深色的
            // `labelColor`（白）去配浅色画出来的底，整面全红。
            withAppearance {
            for view in views {
                let declared = declaredInks(of: view).compactMap { pair -> (NSColor, CGFloat, (CGFloat, CGFloat, CGFloat))? in
                    guard let rgb = pair.0.usingColorSpace(.sRGB) else { return nil }
                    return (pair.0, pair.1, (rgb.redComponent * 255, rgb.greenComponent * 255,
                                             rgb.blueComponent * 255))
                }
                guard let bg = localBackground(image, root: root, view: view,
                                               avoiding: declared.map { $0.2 }) else {
                    noBackground += 1
                    continue
                }
                for entry in declared {
                    let (color, size, ink) = entry
                    let rgb = color.usingColorSpace(.sRGB)!
                    let ratio = contrastRatio((ink.0, ink.1, ink.2, rgb.alphaComponent), bg)
                    let mixed = (bg.0 * (1 - rgb.alphaComponent) + ink.0 * rgb.alphaComponent,
                                 bg.1 * (1 - rgb.alphaComponent) + ink.1 * rgb.alphaComponent,
                                 bg.2 * (1 - rgb.alphaComponent) + ink.2 * rgb.alphaComponent)
                    let mx = max(mixed.0, max(mixed.1, mixed.2))
                    let sat = mx > 0 ? (mx - min(mixed.0, min(mixed.1, mixed.2))) / mx : 0
                    // 图标（size 记 0）走 WCAG 的非文本一档 3:1；文字里带色相的 4.5:1，
                    // 灰阶文字 3:1。
                    let bar: CGFloat = size == 0 ? 3.0 : (sat > 0.25 ? 4.5 : 3.0)
                    judged += 1
                    let what = "\(name) · \(describe(view))"
                    spots.append((ratio, bar, what, bg, ink))
                    if ratio < worst.ratio { worst = (what, ratio) }
                    if ratio < bar {
                        offenders.append(String(format: "%@ #\(Int(ink.0)),\(Int(ink.1)),\(Int(ink.2))"
                                                    + " \(Int(size))pt %.2f:1（门槛 %.1f）",
                                                what, ratio, bar))
                        if ProcessInfo.processInfo.environment["LITESHOT_DEBUG_INK"] != nil {
                            say(String(format: "        debug %@ 底 #%.0f,%.0f,%.0f  字 #%.0f,%.0f,%.0f α%.2f  %@",
                                       what, bg.0, bg.1, bg.2, ink.0, ink.1, ink.2,
                                       rgb.alphaComponent, describeRect(view)))
                        }
                    }
                }
            }
            }
        }
        say(String(format: "    量到 %d 面　判了 %d 处字（取不到底的 %d 处）　不达标 %d 处　最差 %@ %.2f:1",
                   faces, judged, noBackground, offenders.count,
                   worst.ratio < 99 ? worst.what : "—", worst.ratio < 99 ? worst.ratio : 0))
        for line in offenders.prefix(12) { say("    · ✗ \(line)") }
        if offenders.count > 12 { say("    · 其余 \(offenders.count - 12) 处略") }
        if ProcessInfo.processInfo.environment["LITESHOT_DEBUG_INK"] != nil {
            let ranked = spots.sorted { $0.ratio < $1.ratio }
            say("    最低的 \(min(8, ranked.count)) 处（含刚过线的，用来看"
                + "「是字真的糊还是底采歪了」）")
            for (index, spot) in ranked.prefix(8).enumerated() {
                say(String(format: "      %d/%d %.2f:1（门槛 %.1f）%@　底 #%0.0f,%0.0f,%0.0f　字 #%0.0f,%0.0f,%0.0f",
                           index + 1, ranked.count, spot.ratio, spot.bar, spot.what,
                           spot.bg.0, spot.bg.1, spot.bg.2, spot.ink.0, spot.ink.1, spot.ink.2))
            }
        }
        // 判得太少等于没判：面数或字数掉下去就是走树那一段悄悄断了。
        let gate = faces == surfaces.count && judged >= 60
        say("    \(gate && offenders.isEmpty ? "✓" : "✗") 每一处看得见的字在自己那块底上都够看清"
            + "（有彩度 ≥4.5:1、灰阶 ≥3:1；禁用 / 隐藏不算）"
            + (gate ? "" : "　·　覆盖不足：面 \(faces)/\(surfaces.count)、字 \(judged)（少于 60 处）"))
    }

    /// 一个矩形里能算字色的控件：文字、按钮、图标。
    private static func collectInkViews(in view: NSView, into out: inout [NSView]) {
        if view.isHidden { return }
        if let control = view as? NSControl, !control.isEnabled { return }
        if let field = view as? NSTextField, !field.stringValue.isEmpty { out.append(field) }
        else if let button = view as? NSButton,
                !(button.title.isEmpty && button.image == nil) {
            // 标题单元格自己就是一个 NSTextField —— 有的话走那一层，别把同一个字量两遍
            if !containsTextField(button) { out.append(button) }
        }
        else if let image = view as? NSImageView, image.image != nil,
                image.contentTintColor != nil {
            // 没上色的图片视图是缩略图 / 照片，它自己没有"字色"
            out.append(image)
        }
        for child in view.subviews { collectInkViews(in: child, into: &out) }
    }

    private static func containsTextField(_ view: NSView) -> Bool {
        for child in view.subviews {
            if child is NSTextField || containsTextField(child) { return true }
        }
        return false
    }

    private static func describeRect(_ view: NSView) -> String {
        var chain: [String] = []
        var cursor: NSView? = view
        var rect = view.bounds
        while let current = cursor {
            chain.append("\(type(of: current))")
            if let parent = current.superview {
                rect = parent.convert(rect, from: current)
                cursor = parent
            } else {
                rect = current.bounds
                break
            }
        }
        return "根内 rect=\(NSStringFromRect(rect)) 链=\(chain.prefix(4).joined(separator: "<"))"
    }

    private static func describe(_ view: NSView) -> String {
        if let field = view as? NSTextField {
            return "「\(field.stringValue.prefix(12).replacingOccurrences(of: "\n", with: ""))」"
        }
        if let button = view as? NSButton {
            return "按钮「\(button.title.trimmingCharacters(in: .whitespaces).prefix(8))」"
        }
        return "图标"
    }

    /// 控件声明出来的字色：attributed 串里逐段的前景色优先。
    private static func declaredInks(of view: NSView) -> [(NSColor, CGFloat)] {
        if let field = view as? NSTextField {
            let size = field.font?.pointSize ?? 13
            let attributed = field.attributedStringValue
            var colors: [NSColor] = []
            if attributed.length > 0 {
                attributed.enumerateAttribute(.foregroundColor,
                                              in: NSRange(location: 0, length: attributed.length)) {
                    value, _, _ in
                    if let color = value as? NSColor { colors.append(color) }
                }
            }
            if colors.isEmpty { colors.append(field.textColor ?? .labelColor) }
            return colors.map { ($0, size) }
        }
        if let button = view as? NSButton {
            let size = button.font?.pointSize ?? 13
            // 无边框按钮的标题跟着 contentTintColor 走；没设 tint 时是控件默认字色
            return [(button.contentTintColor ?? .controlTextColor, size)]
        }
        if let image = view as? NSImageView {
            return [(image.contentTintColor ?? .labelColor, 0)]
        }
        return []
    }

    /// 这块矩形里的**众数颜色**当底。底是平色，取众数很稳；字则不适合这么量（见上）。
    /// `avoiding` 是要排除的颜色（这个控件自己声明的字色）：小图标那种矩形里，
    /// 图标自己就能占过半数像素，取众数会取到"字"上，然后把字当成底算出 1:1。
    private static func localBackground(_ image: CGImage, root: NSView, view: NSView,
                                        avoiding: [(CGFloat, CGFloat, CGFloat)] = [])
        -> (CGFloat, CGFloat, CGFloat)? {
        guard let parent = view.superview else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        let scale = CGFloat(image.width) / max(root.bounds.width, 1)
        let rect = root.convert(view.frame, from: parent)
        let top = root.isFlipped ? rect.minY : root.bounds.height - rect.maxY
        let y0 = max(0, Int(top * scale)), y1 = min(image.height - 1, Int((top + rect.height) * scale))
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(image.width - 1, Int(rect.maxX * scale))
        guard y1 > y0, x1 > x0 else { return nil }
        var buckets: [Int: (n: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]
        var total = 0
        for y in y0...y1 {
            for x in x0...x1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let probe = (c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255)
                let nearInk = avoiding.contains { pair in
                    abs(pair.0 - probe.0) + abs(pair.1 - probe.1) + abs(pair.2 - probe.2) < 36
                }
                if nearInk { continue }
                total += 1
                let key = (Int(c.redComponent * 15) << 8) | (Int(c.greenComponent * 15) << 4)
                    | Int(c.blueComponent * 15)
                var bucket = buckets[key] ?? (0, 0, 0, 0)
                bucket.n += 1
                bucket.r += c.redComponent * 255
                bucket.g += c.greenComponent * 255
                bucket.b += c.blueComponent * 255
                buckets[key] = bucket
            }
        }
        guard total > 24, let base = buckets.values.max(by: { $0.n < $1.n }) else { return nil }
        let n = CGFloat(max(base.n, 1))
        return (base.r / n, base.g / n, base.b / n)
    }

    /// WCAG 相对亮度对比度。alpha 先按底色合成，不然"半透明的字"会算虚高。
    private static func contrastRatio(_ ink: (CGFloat, CGFloat, CGFloat, CGFloat),
                                      _ bg: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        func channel(_ v: CGFloat) -> CGFloat {
            let s = v / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        func luma(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
            0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }
        let a = ink.3
        let mix = (bg.0 * (1 - a) + ink.0 * a, bg.1 * (1 - a) + ink.1 * a,
                   bg.2 * (1 - a) + ink.2 * a)
        let one = luma(mix.0, mix.1, mix.2), two = luma(bg.0, bg.1, bg.2)
        return (max(one, two) + 0.05) / (min(one, two) + 0.05)
    }

    /// 菜单栏和设置窗里那四个开关必须叫同一个名字。
    ///
    /// 共用一份常量 ≠ 两边真的都用了它 —— 所以两处都从**界面上**读：
    /// 菜单摊开逐项看标题，设置窗摊开整棵面板文字看有没有那句话。
    /// 判"前缀"而不是判相等：设置窗那侧会在括号里补一句"它还会顺带干什么"。
    private static func printToggleNamingCheck() {
        let statusBar = StatusBarController()
        guard let menu = statusBar.menuForSelfTest else {
            say("── 开关名对账　✗ 拿不到状态栏菜单，这一组没跑成")
            return
        }
        statusBar.menuWillOpen(menu)
        let menuTitles = menu.items.map(\.title)
        let settings = SettingsWindowController(onSettingsChanged: {})
        let paneText = settings.paneJoinedTextForSelfTest()

        var bad: [String] = []
        for (_, base) in ToggleTitles.all where !paneText.contains(base) {
            bad.append("「\(base)」不在设置窗")
        }
        say("── 开关名对账（同一个开关在菜单栏和设置窗里不许有两个名字）")
        say("    四条核心名在设置窗里一项不少　缺 \(bad.count)　\(bad.isEmpty ? "✓" : "✗")")
        for line in bad { say("    · ✗ \(line)") }

        // 菜单那边现在只带两条开关（W5 的瘦身）。"少"必须说得出为什么：
        // 自启和保活是**并**成一条，隐藏图标是**挪**进设置 —— 两种都各有断言盯着，
        // 不许哪天变成"就是没人管了"。
        let pair = ToggleTitles.autoStartPair
        let mergedOK = menuTitles.contains(pair) && pair.contains(ToggleTitles.launchAtLogin)
            && pair.contains(ToggleTitles.keepAlive)
        say("    \(mergedOK ? "✓" : "✗") 自启 + 保活并成一条，而且那条名字里两条核心名都在"
            + "　菜单读到 \(menuTitles.first { $0.contains("自动启动") } ?? "没有")")
        let movedOK = !menuTitles.contains { $0.hasPrefix(ToggleTitles.hideStatusBarIcon) }
            && paneText.contains(ToggleTitles.hideStatusBarIcon)
        say("    \(movedOK ? "✓" : "✗") 「隐藏菜单栏图标」从菜单挪进设置（不是删掉）")
        let keptTwo = menuTitles.filter { title in
            ToggleTitles.all.contains { title.hasPrefix($0.title) } || title == pair
        }.count
        say("    \(keptTwo == 1 ? "✓" : "✗") 菜单上的开关条数 \(keptTwo)（当前只保留自启并保活这一条）")

        // 整张菜单的行数就是"减一半"那条验收口径。以前是 16 行（14 条动作 + 2 行提示），
        // 现在必须 ≤8 条动作；写死上限而不是写死内容，改天加一条正当的会红得说明白。
        let actions = menu.items.filter { !$0.isSeparatorItem && $0.action != nil }.count
        say("    \(actions <= 8 ? "✓" : "✗") 主菜单动作行 \(actions) 条（瘦身前 14 条 + 2 条提示）"
            + "　上限 8")
        // 这一档以前在菜单里叫「开机自动启动」—— 和设置窗的「登录后自动启动」
        // 是同义不同名，而开机和登录根本不是一回事（SMAppService 登记的是登录项）。
        // 上面那条会因为"不含新名"而红；这条再钉一次"旧名一个都不许留着"，
        // 免得有人把两处一起改成第三个名字。
        let stale = menuTitles.filter { $0.contains("开机自动启动") }
        say("    旧写法「开机自动启动」残留 \(stale.count)　\(stale.isEmpty ? "✓" : "✗")")

        // 设置页用同一把尺子量。瘦身前实测（本轮改之前跑出来的）：
        // save 9　ocr 8　hotkey 8　runtime 9，合计 **34** 行；现在 24 行。
        // 每一行都是"眼睛扫到的一条"：横向并排的三个语言勾选框算一行，
        // `grouped(...)` 把说明和它管的控件钉成一组也算一行。
        // 上限按面板各自封顶、留一格余量，超了就是又往一节里塞了一行 ——
        // 写死上限不写死内容，加一条正当的会红得说明白。
        let paneNames = ["save", "ocr", "hotkey", "runtime"]
        let caps = [6, 7, 7, 8]
        var over: [String] = []
        var census: [String] = []
        var total = 0
        for (index, name) in paneNames.enumerated() {
            settings.showPane(at: index, animate: false)
            let rows = paneRows(settings, index: index)
            total += rows
            census.append("\(name) \(rows)")
            if rows > caps[index] { over.append("\(name) \(rows)>上限\(caps[index])") }
        }
        let overText = over.isEmpty ? "0" : over.joined(separator: "、")
        say("    \(over.isEmpty ? "✓" : "✗") 四个面板行数 " + census.joined(separator: "　")
            + "　合计 \(total)（瘦身前 34）　超限 \(overText)")
    }

    /// 一段文字在另一段里出现几次（重叠的也算一次起点，但这里查的是整栏级别的重复，
    /// 栏与栏之间不互相包含）。
    private static func occurrences(_ needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack.startIndex
        while let range = haystack.range(of: needle, range: search..<haystack.endIndex) {
            count += 1
            search = range.upperBound
        }
        return count
    }

    /// 一个设置面板里的行数 = 每张分组卡片内容栈的 arrangedSubviews 之和。
    ///
    /// 数的是**排版出来的行**，不是源码里 `section(rows:)` 传了几项：横向并排的三个
    /// 语言勾选框是一行，`grouped(...)` 折叠的一组也算一行。这正是这个口径有用之处 ——
    /// 把说明和它管的控件钉成一组会真的让数字变小，而把两行文字硬塞进一个标签
    /// （字号、间距都不动）不会。
    private static func paneRows(_ controller: SettingsWindowController, index: Int) -> Int {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let cards = cardViews(in: controller.paneViewForSelfTest(index) ?? NSView())
        return cards.reduce(0) { total, card in
            total + ((card.subviews.first as? NSStackView)?.arrangedSubviews.count ?? 0)
        }
    }

    /// 菜单状态体检：手工置灰的那条，活不活得过系统弹出前的那一趟启用校验。
    ///
    /// `NSMenu.autoenablesItems` 默认是开着的 —— 菜单显示前系统会按 target/action
    /// 重算每一项的可用状态。也就是说建菜单时写的那句 `isEnabled = false`
    /// 有可能只是**暂时**灰了，系统那一趟跑完又亮了。这一节就量这件事，
    /// 顺带把「最近截图」子菜单的三种状态（全失效 / 有真文件 / 混着）摊开看。
    ///
    /// 为什么值得单独一节：这类 bug 的用户体验形态是"点了叮一声"，
    /// 静态读代码看不出来，只能把菜单真建出来再走一遍系统的流程。
    private static func printMenuStateCheck() {
        let statusBar = StatusBarController()
        guard let menu = statusBar.menuForSelfTest else {
            say("── 菜单状态体检　✗ 拿不到状态栏菜单，这一组没跑成")
            return
        }
        let store = SettingsStore.shared
        let snapshot = store.recentShots
        defer { store.recentShots = snapshot }

        func item(action: String) -> NSMenuItem? {
            func search(_ items: [NSMenuItem]) -> NSMenuItem? {
                for entry in items {
                    if entry.action != nil && NSStringFromSelector(entry.action!) == action { return entry }
                    if let hit = entry.submenu.flatMap({ search($0.items) }) { return hit }
                }
                return nil
            }
            return search(menu.items)
        }
        /// 和真实弹出一样的两步：委托重建 → 系统校验启用态。
        ///
        /// 子菜单要各自再走一趟：真实弹出时，用户展开哪一层系统就对哪一层
        /// 调一次 `update()`，而 `menu.update()` **不会递归进子菜单**。少了这一步，
        /// 「最近截图 ▸ 编辑最近一张截图…」的启用态在这里根本没被校验过，
        /// 于是"置灰活不过 update()"这条老 bug 会重新悄悄长回来。
        func reopen() {
            statusBar.menuWillOpen(menu)
            menu.update()
            for item in menu.items { item.submenu?.update() }
        }

        /// 「最近截图」子菜单里非分隔条的行。
        func filesRows() -> [NSMenuItem] {
            (menu.items.first { $0.title.hasPrefix("最近截图") }?.submenu?.items ?? [])
                .filter { !$0.isSeparatorItem }
        }

        /// 这一行是不是指向一张真实照片（而不是说明行或固定动作）。
        func isShotRow(_ item: NSMenuItem) -> Bool {
            guard let action = item.action else { return false }
            return NSStringFromSelector(action) == "openRecentShot:"
        }

        /// 其中真正指向一张照片的行（其余是说明行 / 打开文件夹 / 编辑最近一张）。
        func shotRows(_ rows: [NSMenuItem]) -> [NSMenuItem] { rows.filter { isShotRow($0) } }

        // 「有真文件」这一档用渲染出来的 PNG，不另造临时文件 —— 跑到这节时它们已经在盘上。
        let realShot = (try? FileManager.default.contentsOfDirectory(atPath: "\(renderRoot)/dark"))?
            .first { $0.hasSuffix(".png") }
            .map { "\(renderRoot)/dark/\($0)" }
        let ghost = "\(renderRoot)/dark/这一张不存在-\(UUID().uuidString.prefix(8)).png"

        say("── 菜单状态体检（手工置灰能不能活过系统那趟 update()）")
        say("    autoenablesItems = \(menu.autoenablesItems ? "on" : "off")"
            + "　·　校验前手工置灰，校验后再读一次")

        // A：最近截图里只剩一个已经不在盘上的路径 → 照片行必须消失，
        //    但「打开文件夹」这条固定出口仍然在。
        store.recentShots = [ghost]
        reopen()
        // 全失效时「最近截图」这一组还在（打开文件夹永远有用），但**照片行一条都不许留**：
        // 摆三条按下去打不开的路径，比不摆更糟。
        let dead = filesRows()
        say("    \(shotRows(dead).isEmpty ? "✓" : "✗") 最近截图全失效 → 「最近截图」里一张照片行都不留"
            + "（读到 \(shotRows(dead).count) 条）")
        // 但这一组本身不能跟着空掉 —— 打开文件夹、说明路径都还在。
        let stillUseful = dead.contains { $0.title == "打开文件夹" }
        say("    \(stillUseful ? "✓" : "✗") 全失效时「打开文件夹」仍然在（它不依赖于有没有文件）")

        guard let realShot else {
            say("    △ 渲染目录里没找到 PNG，「有真文件」那两档没跑成")
            return
        }

        // B：有一条真在盘上的截图 → 子菜单只列这张照片 + 路径说明 + 打开文件夹。
        store.recentShots = [realShot]
        reopen()
        let rows = filesRows()
        let shots = shotRows(rows)
        // 一行路径说明 + 一张照片 + 打开文件夹，多一条少一条都算不合格。
        let fixed = rows.filter { $0.action != nil && !isShotRow($0) }.map(\.title)
        let hint = rows.first { $0.action == nil }
        let shaped = shots.count == 1
            && shots[0].isEnabled
            && shots[0].title == (realShot as NSString).lastPathComponent
            && fixed == ["打开文件夹"]
            && hint?.isEnabled == false
        say("    \(shaped ? "✓" : "✗") 子菜单 1 张照片行 + 路径说明 + 打开文件夹　"
            + "读到 \(rows.map(\.title).joined(separator: " / "))")

        // C：混着一条已删除的 → 显示层过滤掉了，偏好里也不该继续占格子。
        store.recentShots = [ghost, realShot]
        reopen()
        let live = shotRows(filesRows())
        let pruned = store.recentShots == [realShot]
        say("    \(live.count == 1 && live[0].isEnabled && pruned ? "✓" : "✗") 失效 + 有效混着：只列真存在的那张，"
            + "偏好里的账也同步清了（读到 \(store.recentShots.count) 条）")

        // D：除了说明行，别的一条都不许被系统悄悄按灰。
        let victims = menu.items.filter { item in
            guard !item.isSeparatorItem, item.action != nil else { return false }
            return !item.isEnabled
        }
        say("    \(victims.isEmpty ? "✓" : "✗") 其余带动作的条目校验后全可点，没被系统顺手按灰"
            + "　异常 \(victims.count) 条\(victims.isEmpty ? "" : "：" + victims.map { $0.title }.joined(separator: "、"))")

        // E：勾选标记活过校验 —— 菜单里那几个开关的状态读的是偏好，不是建菜单时的快照。
        var stateBad: [String] = []
        for (key, base) in ToggleTitles.all {
            guard let found = menu.items.first(where: { $0.title.hasPrefix(base) }) else { continue }
            let want = store.isEnabled(forToggleKey: key) ? NSControl.StateValue.on : .off
            if found.state != want { stateBad.append("「\(base)」显示 \(found.state == .on ? "✓" : "空")、偏好是 \(want == .on ? "勾" : "空")") }
        }
        say("    \(stateBad.isEmpty ? "✓" : "✗") 四个开关的勾选标记与偏好一致，且活过 update()"
            + "　不符 \(stateBad.count) 项\(stateBad.isEmpty ? "" : "：" + stateBad.joined(separator: "；"))")
    }

    /// 同一个动作在工具栏和右键菜单里不许有两个名字。
    ///
    /// 起因是一组真的双名字：工具栏写「全部」、菜单写「复制全部文字」——
    /// 光看按钮不知道是"复制全部"还是"全选文字"。这种"第二份真相"在本仓库被抓过
    /// 好几回，只是每次都得靠人眼，所以这次把它变成对账。
    ///
    /// 判据取"动词开头一致"而不是"字符串相等"：菜单那侧常常多一句说明
    /// （「丢弃（移到废纸篓）」），那是补充不是分家。
    private static func printActionNamingCheck() {
        let controller = InlinePreviewController()
        // 两个轴都摊开：工具栏五种形态 × 「这张图存过没有」。少摊一个轴，
        // 那一侧的名字就没人对过账 —— 「已保留」差一点就是这么溜过去的。
        var toolbar: [String: Set<String>] = [:]
        for mode: InlinePreviewController.ToolbarMode in
            [.normal, .ocr, .busy, .failure("识别超时，再点一次试试")] {
            for saved in [false, true] {
                let stack = controller.toolbarStack(for: mode, saved: saved)
                for view in stack.arrangedSubviews {
                    guard let button = view as? NSButton, let action = button.action else { continue }
                    let title = button.title.trimmingCharacters(in: .whitespaces)
                    if title.isEmpty { continue }
                    toolbar[NSStringFromSelector(action), default: []].insert(title)
                }
            }
        }
        let combos: [(label: String, ocr: Bool, saved: Bool)] = [
            ("未保存·非 OCR", false, false), ("未保存·OCR", true, false),
            ("已保存·非 OCR", false, true), ("已保存·OCR", true, true)
        ]
        var shared = 0
        var bad: [String] = []
        for combo in combos {
            let entries = InlinePreviewController.contextMenuItems(isOCRMode: combo.ocr,
                                                                   saved: combo.saved)
            for entry in entries {
                guard let titles = toolbar[NSStringFromSelector(entry.action)] else { continue }
                shared += 1
                let verb = String(entry.title.prefix(2))
                if !titles.contains(where: { $0.hasPrefix(verb) }) {
                    let seen = titles.sorted().joined(separator: "」「")
                    bad.append("\(combo.label) 菜单「\(entry.title)」 vs 工具栏「\(seen)」")
                }
            }
        }
        say("── 动作名对账（同一个动作在工具栏和菜单里不许有两个名字）")
        // 共有动作少于 6 个就说不上话：多半是某一侧根本没摊开（清单空了照样 0 处不一致）。
        let enough = shared >= 6
        say("    四个组合共对上 \(shared) 个动作　名字对不上 \(bad.count)　"
            + (bad.isEmpty && enough ? "✓" : "✗"))
        if !enough {
            say("    · ✗ 只对上 \(shared) 个动作，这一组基本没走到（工具栏或菜单清单没摊开）")
        }
        for line in bad { say("    · ✗ \(line)") }

        // 条数由「存过没有」和「OCR 档」两条轴决定，四个组合的关系是钉死的：
        // OCR 档恒比非 OCR 档多两条（复制选中 + 复制全文）；已保存那一档
        // **更短**（保存 / 丢弃 两条换成一条「在访达中显示」），因为磁盘上那份
        // 已经存在，「保存」没意义、「丢弃」交给还在的工具栏，右键只留最常用的几条。
        func count(_ ocr: Bool, _ saved: Bool) -> Int {
            InlinePreviewController.contextMenuItems(isOCRMode: ocr, saved: saved).count
        }
        let shapeOK = count(false, false) == 3 && count(true, false) == 5
            && count(false, true) == 2 && count(true, true) == 4
        say("    菜单项数 未保存 \(count(false, false))/\(count(true, false))　"
            + "已保存 \(count(false, true))/\(count(true, true))（非 OCR / OCR）　"
            + (shapeOK ? "✓ OCR 多 2、已保存更短" : "✗ 和「OCR 多 2、已保存更短」对不上"))

        // 文件动作得有个文件才可点：摆在没有文件的状态里，就是一条按下去
        // 什么都不发生的菜单项，而它看起来完全正常。
        let fileVerbs = ["在访达中显示"]
        func fileTitles(_ saved: Bool) -> [String] {
            let entries = InlinePreviewController.contextMenuItems(isOCRMode: false, saved: saved)
            return entries.map(\.title).filter { fileVerbs.contains($0) }
        }
        let hidden = fileTitles(false)
        let shown = fileTitles(true)
        say("    \(hidden.isEmpty ? "✓" : "✗") 没保存时菜单里不出现「\(fileVerbs.joined(separator: " / "))」"
            + "　读到 \(hidden.count) 项\(hidden.isEmpty ? "" : "：\(hidden.joined(separator: "、"))")")
        say("    \(shown.count == fileVerbs.count ? "✓" : "✗") 保存之后文件动作一项不少　读到 \(shown.count) 项")
        // 已保存那一档右键只留两条最常用的（复制图片 / 在访达中显示）：磁盘上那份
        // 已经在了，再摆「保存」是骗人，「丢弃」也撤下去 —— 用户明确要求存过之后
        // 右键只剩两条有用的。未保存那档仍要留着它（那时它是唯一的出口）。
        func hasDiscard(_ saved: Bool) -> Bool {
            InlinePreviewController.contextMenuItems(isOCRMode: false, saved: saved)
                .contains { $0.action == #selector(InlinePreviewController.discard) }
        }
        let savedMenu = InlinePreviewController.contextMenuItems(isOCRMode: false, saved: true)
            .map(\.title)
        let shortMenu = hasDiscard(false) && !hasDiscard(true)
            && count(false, false) == 3 && count(false, true) == 2
            && savedMenu == ["复制图片", "在访达中显示"]
        say("    \(shortMenu ? "✓" : "✗") 存过之后右键只剩两条（复制图片 / 在访达中显示）"
            + "　·　未保存那档仍留「丢弃」　读到 已保存 = \(savedMenu.joined(separator: "、"))")

        // 「复制选中」和「复制全文」必须是**两件事**：以前「复制选中」没划选时
        // 静默退化成"复制全部"，两颗按钮点出来一个结果，用户自然问"这俩有啥区别"。
        // 判据落在动作选择器上 —— 一个选择器对应一个函数，同名字就不可能同结果。
        let ocrEntries = InlinePreviewController.contextMenuItems(isOCRMode: true, saved: false)
        let copySel = ocrEntries.first { $0.title == "复制选中" }?.action
        let copyAllSel = ocrEntries.first { $0.title == "复制全文" }?.action
        say("    " + (copySel != nil && copyAllSel != nil && copySel != copyAllSel ? "✓" : "✗")
            + " 「复制选中」和「复制全文」各绑各的动作（不再是同一个结果）")
        let dragGate = InlinePreviewController.allowsPanelDragging(isOCRMode: false)
            && !InlinePreviewController.allowsPanelDragging(isOCRMode: true)
        say("    \(dragGate ? "✓" : "✗") 普通预览可拖动，OCR 模式空白处不拖动面板")

        // 划着字时回车属于文字选择，不该顺手保存并关掉预览。
        let returnGate = InlinePreviewController.blocksKeepWhileSelectingText(isOCRMode: true,
                                                                              hasSelection: true)
            && !InlinePreviewController.blocksKeepWhileSelectingText(isOCRMode: false,
                                                                     hasSelection: true)
            && !InlinePreviewController.blocksKeepWhileSelectingText(isOCRMode: true,
                                                                     hasSelection: false)
            && !InlinePreviewController.blocksKeepWhileSelectingText(isOCRMode: false,
                                                                     hasSelection: false)
        say("    \(returnGate ? "✓" : "✗") 只有 OCR 且有选区时吞掉回车，普通预览仍可回车保存")
    }

    /// 设置窗的设计系统：分段图标 + 分组卡片，两样都要"真的看得见"。
    ///
    /// 为什么不只数视图：卡片要是画成和窗口同色，「这几行是一组」的信号就等于零，
    /// 而代码看起来完全正常 —— 所以量的是合成之后的灰度差，不是"有没有这个视图"。
    ///
    /// 深浅两套外观在这里一次算完，而不是"当前是哪遍就算哪遍"：这一组只在深色通道
    /// 跑（`emitChecks`），跟着通道走的话浅色那套的对比度永远没人量，而卡片色是
    /// 动态色，恰恰最容易出"深色看得见、浅色糊成一片"。
    private static func printSettingsDesignCheck() {
        guard emitChecks else { return }
        let controller = SettingsWindowController(onSettingsChanged: {})
        guard controller.window?.contentView != nil else {
            say("── 设计系统　✗ 设置窗没建起来，这一组没跑成")
            return
        }
        let names = ["save", "ocr", "hotkey", "runtime"]
        var cardCounts: [String] = []
        var emptyPanes: [String] = []
        for (index, name) in names.enumerated() {
            controller.showPane(at: index, animate: false)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let cards = cardViews(in: controller.paneViewForSelfTest(index) ?? NSView())
            if cards.isEmpty { emptyPanes.append(name) }
            cardCounts.append("\(name) \(cards.count)")
        }
        let pass = passLabel == "dark" ? "深色" : "浅色"
        let icons = controller.segmentsWithIconForSelfTest
        say("── 设计系统（\(pass)）：分段图标 + 分组卡片 + 溢出有人接")
        say("    · 分段带图标 \(icons)/\(names.count)　\(icons == names.count ? "✓" : "✗ 有面板没图标")")
        say("    · 卡片数　" + cardCounts.joined(separator: "　")
            + "　" + (emptyPanes.isEmpty ? "✓"
                      : "✗ 这些面板一张卡片都没有：\(emptyPanes.joined(separator: "、"))"))
        // 结构先判一遍：这台机器上四个面板都放得下，"差额有没有人接"在高度差上永远是绿的，
        // 把滚动视图拆掉也不会有半行红 —— 所以按结构判一次，再按实测判一次。
        say("    · 面板住在滚动视图里　"
            + (controller.paneIsScrollableForSelfTest
                ? "✓"
                : "✗ 没有滚动视图：窗口一矮，最后一节就被裁到看不见的地方"))
        // 真把窗口压矮一次。只看 `windowHeight` 的算术不够：它说"压掉 80pt"，
        // 而那 80pt 到底去哪了 —— 是被裁没，还是留在文档里等用户滚 ——
        // 只有把窗口压矮、再滚到底量一遍才知道。
        if let window = controller.window, let scroll = controller.paneScrollForSelfTest,
           let pane = controller.paneViewForSelfTest(2) {
            controller.showPane(at: 2, animate: false)
            window.contentView?.layoutSubtreeIfNeeded()
            let full = pane.bounds.height
            window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: 200))
            window.contentView?.layoutSubtreeIfNeeded()
            let clip = scroll.contentView
            let doc = scroll.documentView?.bounds.height ?? 0
            let vis = clip.bounds.height
            // 滚到底：文档的底边应该进到可见矩形里
            clip.scroll(to: NSPoint(x: 0, y: max(0, doc - vis)))
            scroll.reflectScrolledClipView(clip)
            let bottomEdge = clip.bounds.maxY
            let reached = doc >= full - 0.5 && vis < doc - 0.5 && bottomEdge >= doc - 0.5
            say(String(format: "    · 压到 200 高实测：内容 %@　可见 %@　滚到底够到 %@　%@",
                         "\(Int(full))", "\(Int(vis))", "\(Int(doc))",
                         reached ? "✓ 溢出的一截还在文档里，能滚到"
                             : "✗ 溢出没被接住（文档 \(Int(doc)) vs 内容 \(Int(full))，"
                                 + "底边 \(Int(bottomEdge)) vs \(Int(doc))）"))
        } else {
            say("    · ✗ 拿不到窗口或滚动视图，压窗这一验没跑成")
        }
        func ink(_ color: NSColor) -> (gray: CGFloat, alpha: CGFloat)? {
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
            return (0.299 * rgb.redComponent + 0.587 * rgb.greenComponent
                        + 0.114 * rgb.blueComponent, rgb.alphaComponent)
        }
        func contrast(_ appearance: NSAppearance, fillWith fillColor: NSColor) -> CGFloat? {
            var delta: CGFloat?
            appearance.performAsCurrentDrawingAppearance {
                guard let base = ink(.windowBackgroundColor), let fill = ink(fillColor) else { return }
                let composited = fill.alpha * fill.gray + (1 - fill.alpha) * base.gray
                delta = abs(composited - base.gray)
            }
            return delta
        }
        for (name, appearance) in [("深色", NSAppearance(named: .darkAqua)),
                                   ("浅色", NSAppearance(named: .aqua))] {
            guard let appearance, let delta = contrast(appearance, fillWith: .quaternaryLabelColor)
            else {
                say("    · \(name) ✗ 卡片色或窗口色解不出来，这一条没跑成")
                continue
            }
            say(String(format: "    · %@ 卡片底 vs 窗口底 灰度差 %.3f　%@", name, delta,
                       delta >= 0.04 ? "✓ 分组看得出来"
                           : "✗ 差太小，卡片和窗口糊成一片（分组等于没分）"))
        }
        // 判据探针：把卡片色换成窗口色，这条必须掉到 0 以下 —— 不然上面那个
        // 「灰度差够大」可能只是条永远成立的空判据，红是永远不会红的。
        let probe = NSAppearance(named: .darkAqua).flatMap {
            contrast($0, fillWith: .windowBackgroundColor)
        }
        let probeText = probe.map { String(format: "%.3f", $0) } ?? "读不到"
        say("    判据探针：卡片涂成窗口色时灰度差 \(probeText)"
            + "　\((probe ?? 1) < 0.005 ? "✓ 会被抓到" : "✗ 判据失灵")")
    }

    private static func cardViews(in root: NSView) -> [SettingsCardView] {
        var found: [SettingsCardView] = []
        if let card = root as? SettingsCardView { found.append(card) }
        for sub in root.subviews { found += cardViews(in: sub) }
        return found
    }

    /// 快捷键录制框：用真实 keyDown 走一遍拦截路径，再把「框里那句提示塞不塞得进去」量出来。
    ///
    /// 这里用的是游离控件（不接 onChange）：自检既不该写
    /// 用户的偏好，也不该在离屏渲染里弹模态框。
    private static func checkHotKeyRecorder(_ controller: SettingsWindowController) {
        guard emitChecks else { return }
        say("    快捷键录制框")

        let mk = HotKeySpec.make
        let cmdC = mk(HotKeySpec.Key.c, HotKeySpec.Mod.cmd)
        let ctrlOptA = mk(HotKeySpec.Key.a, HotKeySpec.Mod.ctrl | HotKeySpec.Mod.opt)
        let systemShot = mk(HotKeySpec.Key.four, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift)
        let recorder = HotKeyRecorderView()
        let before = recorder.spec

        let rejected = recorder.recordForSelfTest(keyCode: HotKeySpec.Key.c, modifiers: .command)
        // 反证：框里原本存的不是 ⌘C。否则「被拦下、值没变」这句话是空的 ——
        // 拦没拦都读得到同一个值。
        let meaningful = before != cmdC
        let rejectedMark = meaningful && rejected.stopped == false
            && rejected.spec == before && rejected.hint != nil
        let rejectedHint = rejected.hint ?? "（没字）"
        say("      \(rejectedMark ? "✓" : "✗") "
              + "按 ⌘C 被拦在框里：框里原本不是 ⌘C、值没变、还在收键、写了原因 →「\(rejectedHint)」")

        let stillRecording = recorder.isRecordingForSelfTest
        let accepted = recorder.recordForSelfTest(keyCode: HotKeySpec.Key.a,
                                                 modifiers: [.control, .option])
        say("      \(stillRecording && accepted.stopped && accepted.spec == ctrlOptA ? "✓" : "✗") "
              + "拦完不用重新点：接着按 ⌃⌥A 就收下了（\(accepted.spec.displayString)）")

        // 通道本身：收下的时候必须正好送到一次，被拦的时候一次都不许送。
        // 少一次 = 框里换了字、偏好没动；多一次 = 一次按键改两回设置。
        let wired = HotKeyRecorderView()
        var delivered: [HotKeySpec] = []
        wired.onChange = { delivered.append($0) }
        _ = wired.recordForSelfTest(keyCode: HotKeySpec.Key.c, modifiers: .command)
        say("      \(delivered.isEmpty ? "✓" : "✗") 被拦下的那次一个字节都没交出去（交出去就是偷偷改了设置）")
        _ = wired.recordForSelfTest(keyCode: HotKeySpec.Key.a, modifiers: [.control, .option])
        say("      \(delivered == [ctrlOptA] ? "✓" : "✗") 收下时正好交一次，且交的就是按下的那条（\(delivered.count) 次）")
        _ = wired.recordForSelfTest(keyCode: 51, modifiers: [])
        say("      \(delivered.count == 2 && delivered.last == HotKeySpec.none ? "✓" : "✗") 按 Delete 清空也走同一条通道（交出去的是「未启用」）")

        say("      \(controller.hotKeyRecordersWiredForSelfTest ? "✓" : "✗") 设置面板里那两个框都真的接上了提交通道")

        // 逻辑自检那边量的是**常量**；这里量的是常量有没有真的贴到窗上。
        // 少了这一行，面板改回内联硬编码（或者整栏没排进去）时，那边的 ✓ 就成了
        // 一张免检通行证 —— 代码里的文案对，用户看到的那份照样能写反。
        // 「恢复默认快捷键」：判断在逻辑自检里钉死了，这里钉接线 ——
        // 按钮的 action 必须真的指向那个会先问一句的方法，而那句结果话术得有地方显示。
        // 走**真方法本体**（写盘和问句注入），因为只查 selector 名字的话，把方法体
        // 改回「无条件写盘」这条断言照样绿 —— 而那正是要防的事故。
        var rsWrites = 0, rsAsks = 0, rsChanged = 0
        let savedHandler = controller.onSettingsChanged
        controller.onSettingsChanged = { rsChanged += 1 }
        let rsBefore = controller.hotKeyViewsSnapshotForSelfTest
        let rsUser = mk(HotKeySpec.Key.x, HotKeySpec.Mod.cmd | HotKeySpec.Mod.shift)
        _ = controller.performHotKeyReset(capture: rsUser,
                                          write: { rsWrites += 1 }) { _ in rsAsks += 1; return false }
        let cancelOK = rsAsks == 1 && rsWrites == 0 && rsChanged == 0
            && controller.hotKeyStatusLabelTextForSelfTest
                == SettingsWindowController.resetStatus(.cancelled)
            && controller.hotKeyViewsSnapshotForSelfTest == rsBefore
        say("      \(cancelOK ? "✓" : "✗") 有东西可恢复时按「取消」：问 1 次、写盘 \(rsWrites) 次、"
              + "不重注册热键（通知 \(rsChanged) 次）、两个框还是原组合")
        rsWrites = 0; rsAsks = 0; rsChanged = 0
        _ = controller.performHotKeyReset(capture: .defaultCapture,
                                          write: { rsWrites += 1 }) { _ in rsAsks += 1; return true }
        say("      \(rsAsks == 0 && rsWrites == 0 && rsChanged == 0 ? "✓" : "✗") "
              + "本来就都是默认时连问都不问（问 \(rsAsks) 次、写 \(rsWrites) 次）")
        // 真按钮读的是设置里的当前值，不是硬编码的那对
        let liveOK: Bool = {
            var asked = 0
            _ = controller.performHotKeyReset(write: { }) { _ in asked += 1; return false }
            let expectAsk = SettingsWindowController.resetDecision(
                capture: SettingsStore.shared.hotKeyCapture) != .nothingToRestore
            return asked == (expectAsk ? 1 : 0)
        }()
        say("      \(liveOK ? "✓" : "✗") 按钮那条路读的是设置里的当前组合（问句次数跟着真实状态走）")
        controller.onSettingsChanged = savedHandler

        // 状态行得在用户按按钮时看得见的那个面板里。面板是切过去才挂进窗口的，
        // 所以这里用真的 ⌘N 按键事件把它切出来，再验它在窗口里。
        var labelPlaced = false
        if let label = controller.hotKeyStatusLabelForSelfTest,
           let paneIndex = controller.paneIndexContainingForSelfTest(label) {
            labelPlaced = controller.selectPaneViaKeyEventForSelfTest(digit: paneIndex + 1)
                && SettingsWindowController.contains(view: controller.window?.contentView, label)
        }
        say("      \(labelPlaced ? "✓" : "✗") 结果话术有地方显示：状态行在快捷键面板里，"
              + "而那个面板真的会被挂进窗口（不在这儿，那句「没改任何东西」就没处说）")

        // 按钮那条路必须自己也能挡住：上一轮的对照把方法体改回"无条件恢复"之后
        // 全场仍然全绿 —— 因为上面的行调的是方法，不是按钮。这里走真 `sendAction`。
        var btnWrites = 0, btnAsks = 0, btnChanged = 0
        let savedBtn = controller.onSettingsChanged
        controller.onSettingsChanged = { btnChanged += 1 }
        // 先把状态行抹成一个不可能的值：不然上一条行留下的「按了取消…」会让
        // "这具方法体根本没设置状态行"的对照看起来照样绿。
        controller.hotKeyStatusLabelOverrideForSelfTest("（自检抹掉的占位）")
        let dispatched = controller.clickResetButtonForSelfTest(write: { btnWrites += 1 }) { _ in
            btnAsks += 1; return false
        }
        let liveDecision = SettingsWindowController.resetDecision(
            capture: SettingsStore.shared.hotKeyCapture)
        // 问几次跟着**当前真实状态**走：两条都已经是默认时正确行为是不问自回。
        // 但"答了取消之后一个字节都不写"两种状态下都必须成立 —— 那才是挡住
        // "方法体改回无条件恢复"的那一只手（上一轮这条行没这效力）。

        let expectAsks = liveDecision == .nothingToRestore ? 0 : 1
        let wantOutcome: SettingsWindowController.HotKeyResetOutcome =
            liveDecision == .nothingToRestore ? .nothingToRestore : .cancelled
        let buttonKept = controller.hotKeyStatusLabelTextForSelfTest
            == SettingsWindowController.resetStatus(wantOutcome)
        say("      \(dispatched && btnAsks == expectAsks && btnWrites == 0 && buttonKept ? "✓" : "✗") "
              + "从按钮真派发一次（\(liveDecision == .nothingToRestore ? "两条已是默认" : "有得恢复")）："
              + "问 \(btnAsks)/\(expectAsks) 次、写 \(btnWrites) 次、不重注册（通知 \(btnChanged) 次）"
              + "，答「取消」就一个字节都不动")

        controller.onSettingsChanged = savedBtn

        // 状态行是**点完之后才长出来的**。窗口高度按内容算，但那是建面板时算的：
        // 事后多出一行字，窗口不会自己长高 —— 这一行量的是"长了字之后还放得下吗"。
        if let status = controller.hotKeyStatusLabelForSelfTest {
            let longest = SettingsWindowController.resetStatus(.nothingToRestore)
            status.stringValue = longest
            status.window?.contentView?.layoutSubtreeIfNeeded()
            let given = status.frame.height
            let want = status.cell?.cellSize(forBounds: NSRect(x: 0, y: 0,
                width: status.preferredMaxLayoutWidth > 0 ? status.preferredMaxLayoutWidth : 540,
                height: .greatestFiniteMagnitude)).height ?? given
            let pane = status.superview
            var ancestor: NSView? = pane
            while let a = ancestor, a.frame.height < 1 { ancestor = a.superview }
            let rowsHeight = (pane?.subviews ?? []).reduce(CGFloat(0)) { max($0, $1.frame.maxY) }
            say(String(format: "      \(want - given <= 1.5 ? "✓" : "✗") "
                    + "状态行填上最长的话术之后没被裁（需要 %.0f　给了 %.0f）", want, given))
            say("      \(rowsHeight > 0 ? "✓" : "✗") 那一节的排布高度读得到（\(Int(rowsHeight))pt，"
                    + "窗口高 \(Int(controller.window?.contentView?.frame.height ?? 0))pt）")
            status.stringValue = ""
        }

        let wiring = controller.hotKeyResetWiringForSelfTest
        say("      \(wiring["action"] == true && wiring["target"] == true ? "✓" : "✗") "
              + "「恢复默认快捷键」按钮走的是会先问一句的那个方法"
              + "（action \(wiring["action"] == true ? "对" : "不对")　·　target \(wiring["target"] == true ? "是控制器" : "不是")）")
                let helpTexts = [SettingsWindowController.hotKeyHelpText]
            + SettingsWindowController.captureHelpTexts
        // 比的是**拼起来的整棵面板文字**，不是逐个标签比：图例把一段说明拆成了一行
        // 一个标签，逐标签比会让"改排版"和"文案没贴上去"报成同一条红。
        // 拼起来照样防得住它本来要防的那件事（常量还在、面板换成内联硬编码的副本）。
        let paneText = controller.paneJoinedTextForSelfTest()
        let hits = helpTexts.map { occurrences($0, in: paneText) }
        let onWindow = hits.filter { $0 >= 1 }.count
        let twice = hits.filter { $0 > 1 }.count
        say("      \(onWindow == helpTexts.count ? "✓" : "✗") "
              + "说明文案是真贴在窗上的（窗口里读到 \(controller.paneStringsForSelfTest().count) 段文字，"
              + "拼起来后 \(onWindow)/\(helpTexts.count) 栏整段对得上；对不上就是自检在查一份没人看的副本）")
        // 「在不在」防的是"常量改了没贴到窗上"，防不住"同一栏贴了两遍"。
        // 这一条数的是次数 —— 上一轮把三条说明分成 `prefix(2)` + `suffix(2)`，
        // 一共三条时两边都含中间那条，「截完之后」整栏在窗上印了两遍，
        // 而上面那条「在不在」一格都没红。行数那条也没抓到（两栏还是两栏）。
        say("      \(twice == 0 ? "✓" : "✗") 每一栏在窗上正好出现一次（次数 \(hits.map(String.init).joined(separator: "/"))）"
            + "　·　重叠的 prefix/suffix 会让中间那栏印两遍")

        let takeover = HotKeyRecorderView().recordForSelfTest(keyCode: HotKeySpec.Key.four,
                                                              modifiers: [.command, .shift])
        say("      \(takeover.stopped && takeover.spec == systemShot ? "✓" : "✗") "
              + "⇧⌘4 不在这里拦（那是「先问一句」那一档，拦重了就是替用户做主）")

        // 框里文案的宽度不在这里量 —— 那边「文案宽度」一张表已经在读真源头了，
        // 这里再量一遍就是第二把尺子。
        let alert = SettingsWindowController.systemScreenshotAlert(systemShot)
        let plan = SettingsWindowController.systemScreenshotPrompt(systemShot)
        let orderOK = alert.buttons.count == 2
            && alert.buttons.first?.title == plan.swapTitle
            && alert.buttons.last?.title == plan.keepTitle
        say("      \(orderOK ? "✓" : "✗") 那台询问的默认按钮是安全的一个（回车 = 「\(plan.swapTitle)」，不是「\(plan.keepTitle)」）")
    }

    /// ⌘1…⌘4 切面板：决策是纯函数，接线走真的 `window.sendEvent`。
    /// 两半都查，避免"函数写对了、没人调用它"也能变绿。
    private static func checkPaneKeyShortcuts(_ controller: SettingsWindowController) {
        guard emitChecks else { return }
        say("    ⌘1…⌘4 切面板")

        let digits = [3, 1, 4, 2]
        var landed = 0
        for digit in digits where controller.selectPaneViaKeyEventForSelfTest(digit: digit) {
            landed += 1
        }
        let switchingOK = landed == digits.count && controller.selectedPaneIndexForSelfTest == 1
        say("      \(switchingOK ? "✓" : "✗") 按键事件进得了窗口、四个面板都切到位（命中 \(landed)/\(digits.count)，停在第 \(controller.selectedPaneIndexForSelfTest + 1) 个）")

        let index = SettingsWindowController.paneIndex(characters:modifiers:isRecordingHotKey:paneCount:)
        let onlyPlainCommand = index("1", [.command, .option], false, 4) == nil
            && index("1", [.command, .control], false, 4) == nil
            && index("1", [.command], false, 4) == 0
        say("      \(onlyPlainCommand ? "✓" : "✗") 只认裸 ⌘：⌥⌘1 / ⌃⌘1 留给系统，不越权")

        let yieldsToRecorder = index("3", [.command], true, 4) == nil
        say("      \(yieldsToRecorder ? "✓" : "✗") 录制框正收键时让路（⌘1 是完全合法的截图热键）")

        let staysInBounds = index("9", [.command], false, 4) == nil
            && index("4", [.command], false, 4) == 3
            && index("a", [.command], false, 4) == nil
        say("      \(staysInBounds ? "✓" : "✗") 数字超面板数 / 不是数字都当没听见（不崩、不误切）")

        let hintsOnScreen = (0..<4).allSatisfy {
            controller.paneTooltipForSelfTest($0)?.contains("⌘\($0 + 1)") == true
        }
        say("      \(hintsOnScreen ? "✓" : "✗") 每段提示写了 ⌘ 键（只在代码里接了键、界面上一字不提 = 对不知道它的人不存在）")
    }

    /// 把视图树打出来（`LITESHOT_DUMP_TREE=1` 时）——布局塌了的时候，
    /// 猜原因不如直接看每一层的 frame。
    private static func dumpTree(_ view: NSView, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        say("\(indent)\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue) autoresize=\(view.translatesAutoresizingMaskIntoConstraints)")
        view.subviews.forEach { dumpTree($0, depth: depth + 1) }
    }

    /// 就地渲染一个已经挂在窗口里的视图 —— 设置面板不能换爹，
    /// 把它挪进别的窗口会让控制器对不上。
    /// 顺手把成图的 CGImage 带出去，数值断言（亮度对账）要用。
    @discardableResult
    private static func saveInPlace(_ view: NSView, to path: String,
                                    over backdrop: CGImage? = nil,
                                    scale: CGFloat = 1) -> CGImage? {
        // 面板是淡入进来的（alpha 从 0 起），不推进动画就得自己掰回 1，
        // 否则拍出来只有分段控件那一行。
        forceVisible(view)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        let shotName = (path as NSString).lastPathComponent
        // scale > 1 时得自己造 rep：`bitmapImageRepForCachingDisplay` 按窗口的
        // backing scale 出图，而没上屏的窗口那个值是 1 —— 1× 的位图里 11pt 的细笔画
        // 没有一个像素被字色盖满，量出来的对比度比标称低两三成（真机 Retina 上不是这样）。
        let rep: NSBitmapImageRep?
        if scale == 1 {
            rep = view.bitmapImageRepForCachingDisplay(in: bounds)
        } else {
            rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0).map { made in
                // pixelsWide = 2×points 而 size = points，这个比值就是倍率
                // （SDK 里没有可写的 `scale`）
                made.size = bounds.size
                return made
            }
        }
        guard width > 1, height > 1,
              let rep,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            renderShots.append((passLabel, shotName, false))
            return nil
        }

        var image: CGImage?
        withAppearance {
            view.cacheDisplay(in: bounds, to: rep)
            guard let captured = rep.cgImage else { return }
            // 窗口背景要自己铺：没显示的窗口不会替我们画底色。
            // 覆盖层这类「靠透明挖空」的视图传 backdrop 进来：它擦出来的洞
            // 在真机上是露出桌面，在这里就该露出这张合成图。
            if let backdrop {
                ctx.draw(backdrop, in: CGRect(x: 0, y: 0, width: width, height: height))
            } else {
                ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            ctx.draw(captured, in: CGRect(x: 0, y: 0, width: width, height: height))
            image = ctx.makeImage()
        }

        guard let image,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png,
                                                                        properties: [:]) else {
            renderShots.append((passLabel, shotName, false))
            return nil
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            renderShots.append((passLabel, shotName, true))
        } catch {
            // 目录不存在 / 只读 / 磁盘满：少一张图就等于少查一个面，必须说话
            renderShots.append((passLabel, shotName, false))
            Log.ui.error("写 \(path) 失败：\(error.localizedDescription)")
        }
        return image
    }

        /// 两张同样尺寸的图逐像素比：差异个数 + 差异外接框（视图坐标，y 朝上），
    /// 并判一句"差异是不是全落在 expected 里"。
    private static func pixelDiff(a: CGImage, b: CGImage, inside expected: NSRect?)
        -> (count: Int, box: CGRect?, inside: Bool)? {
        guard a.width == b.width, a.height == b.height,
              let ca = pixelContext(width: a.width, height: a.height),
              let cb = pixelContext(width: b.width, height: b.height) else { return nil }
        let full = CGRect(x: 0, y: 0, width: a.width, height: a.height)
        ca.draw(a, in: full)
        cb.draw(b, in: full)
        guard let pa = ca.data, let pb = cb.data else { return nil }
        let n = a.width * a.height * 4
        let A = pa.bindMemory(to: UInt8.self, capacity: n)
        let B = pb.bindMemory(to: UInt8.self, capacity: n)
        var count = 0, minX = a.width, minY = a.height, maxX = -1, maxY = -1
        for y in 0..<a.height {
            for x in 0..<a.width {
                let i = (y * a.width + x) * 4
                if abs(Int(A[i]) - Int(B[i])) > 8
                    || abs(Int(A[i + 1]) - Int(B[i + 1])) > 8
                    || abs(Int(A[i + 2]) - Int(B[i + 2])) > 8 {
                    count += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX else { return (0, nil, false) }
        // 缓冲第 0 行是位图**顶部**（和视图的 y 朝上相反）—— 调用方负责换算，
        // 因为"哪一层翻过一次"是渲染那条路的事，不是这个比对函数的事。
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let inside: Bool
        if let expected {
            let slack = expected.insetBy(dx: -2, dy: -2)
            inside = box.minX >= slack.minX && box.minY >= slack.minY
                && box.maxX <= slack.maxX && box.maxY <= slack.maxY
        } else {
            inside = false
        }
        return (count, box, inside)
    }

        /// 出图清点：想画的、真落盘的、深浅两边是不是同一批。
    private static func printShotInventory() {
        let dark = Set(renderShots.filter { $0.pass == "dark" }.map(\.name))
        let light = Set(renderShots.filter { $0.pass == "light" }.map(\.name))
        let failed = renderShots.filter { !$0.ok }
        say("── 出图清点（每一张都该真写到盘上）")
        say("    深色 \(dark.count) 张　·　浅色 \(light.count) 张　·　两边同名 \(dark.intersection(light).count) 张")
        var bad = 0
        if renderShots.isEmpty {
            bad += 1
            say("    ✗ 一笔都没记上 —— 清点自己没接上，这一节等于没跑")
        }
        if !failed.isEmpty {
            bad += 1
            say("    ✗ \(failed.count) 次想画但没成：\(failed.prefix(5).map { "\($0.pass)/\($0.name)" }.joined(separator: "、"))")
        }
        if dark != light, !dark.isEmpty, !light.isEmpty {
            bad += 1
            say("    ✗ 深浅两套画的不是同一批：只在深色 \(dark.subtracting(light).sorted().joined(separator: "、"))"
                + "　只在浅色 \(light.subtracting(dark).sorted().joined(separator: "、"))")
        }
        // 最后拿磁盘对一遍：记账说写成了，文件却不在，就是账在骗人
        let fm = FileManager.default
        var missing: [String] = []
        for pass in ["dark", "light"] {
            let dir = "\(renderRoot)/\(pass)"
            let onDisk = Set((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            for name in Set(renderShots.filter { $0.pass == pass && $0.ok }.map(\.name))
            where !onDisk.contains(name) { missing.append("\(pass)/\(name)") }
        }
        if !missing.isEmpty {
            bad += 1
            say("    ✗ 账上写成了但盘上没有：\(missing.prefix(5).joined(separator: "、"))")
        }
        if bad == 0 && !dark.isEmpty { say("    ✓ 想画的都落盘了，深浅是同一批（\(dark.count) × 2）") }
    }

    /// 布局越界总账。默认尺寸和最小尺寸都画过一遍，所以这一条管的是
    /// "用户把窗口拖小 / 屏比默认尺寸小"之后界面还站不站得住。
    private static func printLayoutCheck(hits: [String]) {
        say("── 布局越界（控件被父视图切到）")
        let dark = hits.filter { $0.hasPrefix("dark/") }.count
        let light = hits.filter { $0.hasPrefix("light/") }.count
        let darkSet = overflowSurfaces["dark"] ?? []
        let lightSet = overflowSurfaces["light"] ?? []
        let onlyDark = darkSet.subtracting(lightSet).sorted()
        let onlyLight = lightSet.subtracting(darkSet).sorted()
        let covered = (darkSet.union(lightSet)).sorted()
        // 覆盖范围从真走过的那一遍里读，不手写，避免账面覆盖和实际渲染不一致。
        say("    检查过的面 \(covered.count) 个（深色 \(darkSet.count)　·　浅色 \(lightSet.count)）："
            + covered.joined(separator: "、"))
        if covered.isEmpty {
            say("    ✗ 一个面都没走到 —— 这条布局检查等于没跑")
        } else if !onlyDark.isEmpty || !onlyLight.isEmpty {
            say("    ✗ 两套外观走的面不一样：只在深色 \(onlyDark.joined(separator: "、"))"
                + "　只在浅色 \(onlyLight.joined(separator: "、"))"
                + "（只在一遍里画过的面，另一遍的裁剪问题没人看）")
        } else {
            say("    ✓ 深浅两遍走的是同一批面")
        }
        say(hits.isEmpty ? "    ✓ 0 个控件越界"
                           : "    ✗ 深色 \(dark) 处 / 浅色 \(light) 处 → \(hits.prefix(6).joined(separator: "；"))")
    }

    /// 走一遍视图树，找出被父视图切掉的控件。
    ///
    /// 判据只盯**横向**（±1pt）：这一条要抓的是"内容比面板宽"——设置窗被顶到 894pt、
    /// 小屏上工具栏被挤掉一块，都是横向出事。纵向只报超过 8pt 的：
    /// `NSButton` / `NSSlider` 的 frame 本来就比行的对齐矩形探出几 pt（bezel 和阴影），
    /// 那是 AppKit 的正常行为，报出来只会让这条检查失去可信度。
    /// 也不钻进控件内部：`NSSliderKnob` 天生比 `NSSliderTrack` 大，那是系统的私事。
    private static func overflowingViews(in root: NSView) -> [String] {
        var hits: [String] = []
        func name(_ view: NSView) -> String {
            if let id = view.identifier?.rawValue, !id.isEmpty { return id }
            // 光说"某个 NSTextField 越界"没法查：把它的文字带上，一眼就知道是哪个标签
            if let field = view as? NSTextField, !field.stringValue.isEmpty {
                return "NSTextField「\(field.stringValue.prefix(14))」"
            }
            return String(describing: type(of: view))
        }
        /// 只继续往下走"容器"：滚动视图整个不进（documentView 比窗口大是设计如此），
        /// 叶子控件也不进（它们的内部视图是系统的私事）。
        func isContainer(_ view: NSView) -> Bool {
            if view is NSScrollView || view is NSControl { return false }
            return !view.subviews.isEmpty
        }
        func walk(_ view: NSView) {
            for child in view.subviews where !child.isHidden {
                let frame = child.frame
                if frame.width > 0, frame.height > 0 {
                    let bounds = view.bounds
                    let insets = child.alignmentRectInsets
                    let box = NSRect(x: frame.minX + insets.left,
                                     y: frame.minY + insets.top,
                                     width: frame.width - insets.left - insets.right,
                                     height: frame.height - insets.top - insets.bottom)
                    let outside = box.minX < bounds.minX - 1 || box.maxX > bounds.maxX + 1
                        || box.minY < bounds.minY - 8 || box.maxY > bounds.maxY + 8
                    if outside {
                        hits.append("\(name(child)) 越出 \(name(view))"
                                    + "（\(Int(box.minX)),\(Int(box.minY))–\(Int(box.maxX)),\(Int(box.maxY))"
                                    + " vs 0,0–\(Int(bounds.width)),\(Int(bounds.height))）")
                    }
                }
                if isContainer(child) { walk(child) }
            }
        }
        walk(root)
        return hits
    }

    /// 选区覆盖层的五个状态。
    ///
    /// 这是每次截图都第一眼看到、却最难自查的一层：它铺满整屏，只能靠截屏看见。
    /// 底下铺一张合成图当"真实桌面"，它用 `.clear` 挖的洞就该露出这张图。
    private static func renderOverlay(in directory: String) {
        let size = NSSize(width: 1440, height: 900)
        guard let desktop = backdropImage(width: 1440, height: 900) else {
            say("合成图没画出来，跳过覆盖层自检")
            return
        }
        let controller = ShotOverlayController()
        let screen = NSScreen.main
        controller.showHintForSelfTest(on: screen)

        let states: [(String, NSRect?, Bool, (NSPoint, NSPoint)?)] = [
            ("overlay-empty", nil, false, nil),
            ("overlay-window", NSRect(x: 360, y: 260, width: 520, height: 320), false, nil),
            ("overlay-fullscreen", NSRect(origin: .zero, size: size), true, nil),
            ("overlay-drag", nil, false, (NSPoint(x: 240, y: 760), NSPoint(x: 760, y: 180))),
            ("overlay-drag-bottom", nil, false, (NSPoint(x: 300, y: 260), NSPoint(x: 900, y: 60)))
        ]
        var shots: [String: CGImage] = [:]
        for (name, hover, isDisplay, drag) in states {
            let view = OverlayView(frame: NSRect(origin: .zero, size: size))
            view.screenRef = screen
            view.controller = controller
            view.populateForSelfTest(hover: hover, isDisplayCandidate: isDisplay, drag: drag)
            accessibilityRoots.append((name, view))
            if let shot = saveInPlace(view, to: "\(directory)/\(name).png", over: desktop) {
                shots[name] = shot
            }
        }
        say("  overlay: \(states.count) 个状态")
        guard emitChecks else { return }

        // 数值断言：整屏候选必须真的画出框来。
        // 它的描边和尺寸标签原来全画在视图边界以外被裁光 —— 屏幕上只剩"变亮了"，
        // 一点反馈都没有。缩略图上看不出"少了一条 2px 的线"，所以直接数强调色像素：
        // 强调色只出现在选区框和手柄上，数量为 0 就说明框根本没画进屏内。
        if let full = shots["overlay-fullscreen"], let count = accentPixelCount(full) {
            say(String(format: "    整屏候选的强调色像素 %d　%@", count,
                         count > 3_000 ? "✓ 框画在屏内了" : "✗ 整屏候选没有任何可见边框反馈"))
        }
        printDragGeometry(size: size)
        checkSelectionFrame(size: size)
        checkOverlayKeyboard(size: size, screen: screen)
    }

    /// 选区框与手柄的形状。
    ///
    /// 这一节管两件事，都是"画出来的必须能操作"那条规矩的实测形式：
    /// ① 覆盖层的框上**不许有白点** —— 那里没有手柄拖拽，白点就是假把手；
    ///    四角括号得真画出来（否则整条判据只是在证明"什么都没画"）。
    /// ② 预览面板上那八个是真能拖的，形状必须分得开"改一条边"和"改两条边"。
    private static func checkSelectionFrame(size: NSSize) {
        say("── 选区框与手柄形状（白点只准出现在按得住的地方）")
        let rect = NSRect(x: 0, y: 0, width: 420, height: 260)
        let pad: CGFloat = 20
        let arm = OverlayView.cornerTick(minSide: min(rect.width, rect.height))

        // 四个角（图像坐标）。CGImage 从位图上下文取出来时第 0 行在哪一侧，
        // 对"离最近的角有多远"这个问题没有影响 —— 四个角上下对称，翻不翻都是那四个。
        let corners = [NSPoint(x: pad, y: pad), NSPoint(x: pad + rect.width, y: pad),
                       NSPoint(x: pad, y: pad + rect.height),
                       NSPoint(x: pad + rect.width, y: pad + rect.height)]

        guard let shot = OverlayView.renderFrameForSelfTest(rect: rect, active: true) else {
            say("    ✗ 框没画出来 —— 这一节等于没跑")
            return
        }
        guard let context = pixelContext(width: shot.width, height: shot.height) else {
            say("    ✗ 取不到像素上下文，这一节没跑")
            return
        }
        context.draw(shot, in: CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
        guard let base = context.data else {
            say("    ✗ 位图没有数据指针，这一节没跑")
            return
        }
        let w = shot.width, h = shot.height
        let px = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var whiteTotal = 0, whiteFar = 0
        var atCorner = [0, 0, 0, 0]
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                guard Int(px[i]) > 200, Int(px[i + 1]) > 200, Int(px[i + 2]) > 200,
                      Int(px[i + 3]) > 200 else { continue }
                whiteTotal += 1
                let point = NSPoint(x: CGFloat(x), y: CGFloat(y))
                var nearest = CGFloat.greatestFiniteMagnitude
                var nearestIndex = -1
                for (index, corner) in corners.enumerated() {
                    let d = hypot(point.x - corner.x, point.y - corner.y)
                    if d < nearest { nearest = d; nearestIndex = index }
                }
                if nearest <= arm + 4 { atCorner[nearestIndex] += 1 } else { whiteFar += 1 }
            }
        }
        // 括号本身量的是"臂长"，容得下抗锯齿；四边中点离最近的角有 130pt 以上，
        // 旧版那 8 颗白点（半径 3.5）一回来，`whiteFar` 立刻就不是 0。
        say("    \(whiteFar == 0 ? "✓" : "✗") 白色像素一个都不许落在四角之外"
            + "（旧版那 8 颗假把手就画在四边中点）　越界的 \(whiteFar) 个 / 共 \(whiteTotal) 个")
        let allFour = atCorner.allSatisfy { $0 > 20 }
        say("    \(allFour ? "✓" : "✗") 四角各有一段白括号　四角像素数 "
            + atCorner.map(String.init).joined(separator: " / ")
            + "（每角 >20 才算真画了东西，不是抗锯齿的碎点）")

        // 臂长政策：一条边上两只不许碰头，也不许短到看不见；小到放不下就干脆不画。
        var policyBad: [String] = []
        for side in [16.0, 24.0, 40.0, 60.0, 120.0, 420.0, 1_440.0] {
            let got = OverlayView.cornerTick(minSide: side)
            if got > 0 && 2 * got + 8 > side {
                policyBad.append("边长 \(Int(side)) 时臂长 \(String(format: "%.1f", got)) 会碰头")
            }
            if got > 30 { policyBad.append("边长 \(Int(side)) 时臂长超过 30") }
        }
        // 反向对照：政策要是恒给 0，"四角有括号"那条就永远红得掉、而这条永远绿 ——
        // 所以当场验一个正常边长确实给得出可见的臂。
        let visible = OverlayView.cornerTick(minSide: 420)
        let live = visible >= 8 && visible <= 30
        say("    \(policyBad.isEmpty ? "✓" : "✗") 臂长政策：一条边上两只不许碰头、上限 30"
            + (policyBad.isEmpty ? "" : "　不符：" + policyBad.joined(separator: "；")))
        say("    \(live ? "✓" : "✗") 反向对照：政策不是恒 0（420 的边给出臂长 "
            + String(format: "%.1f", visible) + "）")
        let paths = OverlayView.cornerTicks(in: rect, arm: 30)
        let fourPaths = paths.count == 4
        // 每条 L 恰好两个线段、拐角落在某一个角上、两臂都正好 30。
        let shapesOK = fourPaths && paths.allSatisfy { path in
            var points: [CGPoint] = []
            path.applyWithBlock { element in
                switch element.pointee.type {
                case .moveToPoint, .addLineToPoint: points.append(element.pointee.points[0])
                default: break
                }
            }
            guard points.count == 3 else { return false }
            let a = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
            let b = hypot(points[2].x - points[1].x, points[2].y - points[1].y)
            return abs(a - 30) < 0.01 && abs(b - 30) < 0.01
        }
        say("    \(shapesOK ? "✓" : "✗") 四段 L 形：每段两个线段、两臂各 30　读到 \(paths.count) 段")

        // 按下去是不是手柄 —— 走 `mouseDown` 真那一段状态。
        let view = OverlayView(frame: NSRect(origin: .zero, size: size))
        view.populateForSelfTest(hover: NSRect(x: 100, y: 100, width: 400, height: 300),
                                 isDisplayCandidate: false, drag: nil)
        let midTop = NSPoint(x: 300, y: 400)      // 候选上边中点：旧版这里有一颗白点
        let pressed = view.pressAtForSelfTest(midTop, thenDragTo: NSPoint(x: 320, y: 400))
        // 有手柄的话，按下应该把上边整体往上推、左右两条边一动不动（还是 100 和 500）；
        // 覆盖层没有手柄，所以按下点成了新选区的一个角。
        let resized = pressed.map { abs($0.minX - 100) < 1 && abs($0.maxX - 500) < 1 } ?? false
        say("    \(!resized ? "✓" : "✗") 反向对照：按在旧版那颗白点上，得到的不是「拖动那条边」"
            + "　读到 = \(pressed.map { NSStringFromRect($0) } ?? "nil")")
        say("      （所以框上画任何看起来能抓的东西都是谎报 —— 这一条就是那句谎话的探测器）")

        // 预览面板那一圈是真能拖的：形状必须说得出"改一条边"和"改两条边"。
        var cornerBad: [String] = []
        var edgeBad: [String] = []
        for handle in ResizeHandlesView.Handle.allCases {
            let knob = ResizeHandlesView.knobRect(for: handle, center: .zero, size: 10)
            if handle.isCorner {
                if abs(knob.width - knob.height) > 0.01 {
                    cornerBad.append("\(handle) \(knob.width)×\(knob.height)")
                }
            } else {
                let long = max(knob.width, knob.height), short = min(knob.width, knob.height)
                let horizontal = long == knob.width
                let wantsHorizontal = handle == .top || handle == .bottom
                if long / short < 2.5 || horizontal != wantsHorizontal {
                    edgeBad.append("\(handle) \(knob.width)×\(knob.height)")
                }
            }
        }
        say("    \(cornerBad.isEmpty ? "✓" : "✗") 四角是方块（拖它改两条边）"
            + (cornerBad.isEmpty ? "" : "　不像方块：" + cornerBad.joined(separator: "；")))
        say("    \(edgeBad.isEmpty ? "✓" : "✗") 四边是躺在那条边上的短棒（拖它只改这一条边）"
            + (edgeBad.isEmpty ? "" : "　摆错或太方：" + edgeBad.joined(separator: "；")))
    }

    /// 键盘那一轨：⏎ 采用候选、空格切整屏、Esc 取消。
    ///
    /// 逻辑自检那组查的是「按下什么键 = 做什么事」这张表；这里查两件它查不动的：
    /// 一是没有候选时不许假装接住（接住却不做事 = 键被吞了而屏幕上什么都没发生），
    /// 二是**键进不进得来这个视图** —— 合成一次真的 `keyDown` 从窗口打进来。
    /// 投的都是不截屏的键：⏎ 会经 `controller.finish` 真去抓一次屏，
    /// 而自检要的是判断和投递，不是一次截图。
    private static func checkOverlayKeyboard(size: NSSize, screen: NSScreen?) {
        guard emitChecks else { return }
        say("── 键盘那一轨（没候选不许吞键 / 真投递进不进得来 / 候选各交各的）")
        let hover = NSRect(x: 200, y: 200, width: 400, height: 300)
        func fresh(display: Bool, rect: NSRect? = nil) -> OverlayView {
            let view = OverlayView(frame: NSRect(origin: .zero, size: size))
            view.screenRef = screen
            // 必须装进窗口：覆盖层的「视图坐标 → 屏幕坐标」要问 view.window，
            // 没窗口时那条换算给 nil，"截这一块"这条路在自检里根本走不到。
            attachOffscreenWindow(view, size: size)
            view.populateForSelfTest(hover: rect ?? hover, isDisplayCandidate: display, drag: nil)
            return view
        }

        let bare = OverlayView(frame: NSRect(origin: .zero, size: size))
        let heldNothing = !bare.applyKeyForSelfTest(.adopt)
        say("      \(heldNothing ? "✓" : "✗") 反向对照：还没有候选时 ⏎ 不接"
            + "（接住却不做事 = 键被吞了而屏幕上什么都没发生）")

        let whole = fresh(display: true, rect: NSRect(origin: .zero, size: size))
        let wholeKind = adoptKind(of: whole.outcomeForSelfTest)
        say("      \(wholeKind == "整屏" ? "✓" : "✗") 整屏候选：⏎ 交出去的就是「整屏」　实际 = \(wholeKind)")

        let inset = fresh(display: false)
        let insetKind = adoptKind(of: inset.outcomeForSelfTest)
        say("      \(insetKind.hasPrefix("区域") ? "✓" : "✗") 屏内一块候选：⏎ 交出这一块矩形，"
            + "尺寸就是此刻那块　实际 = \(insetKind)")

        // 真投递那一段：合成 keyDown 走 `window.sendEvent` → firstResponder → `keyDown`。
        // 直接调 apply 的那几条只证明映射与决策对，证明不了键进得来。
        // 投 `空格` 因为它不截屏、只把候选换成整屏，效果在视图状态上看得见。
        let probeView = OverlayView(frame: NSRect(origin: .zero, size: size))
        probeView.screenRef = screen
        let probeWindow = OverlayWindow(contentRect: NSRect(x: -12_000, y: -12_000,
                                                            width: size.width, height: size.height),
                                        styleMask: .borderless, backing: .buffered, defer: false,
                                        screen: nil)
        probeWindow.isReleasedWhenClosed = false
        probeWindow.contentView = probeView
        probeView.populateForSelfTest(hover: hover, isDisplayCandidate: false, drag: nil)
        let delivered = probeView.deliverKeyForSelfTest(keyCode: 49)
        let landed = delivered.landedHere && delivered.changed
            && probeView.isDisplayCandidateForSelfTest
        say("      \(landed ? "✓" : "✗") 反向对照（真投递）：合成一个空格从窗口打进来，"
            + "键落到本视图=\(delivered.landedHere)　候选换成整屏=\(probeView.isDisplayCandidateForSelfTest)")
        say("      △ 真机上这个窗口能不能成为 key 窗口，无头验不到（本进程 isKeyWindow="
            + String(delivered.keyWindow) + "）—— 键进不来时先查这一环")
        probeWindow.orderOut(nil)
    }

    /// 自检夹具用的窗口：只给视图一个 `window` 让它能换算坐标，**从不 orderFront**，
    /// 所以屏幕上不会多出东西（无头那条清点会抓）。留着引用是因为窗口一旦释放，
    /// 视图的 `window` 又变回 nil。
    private static var selfTestWindows: [NSWindow] = []

    private static func attachOffscreenWindow(_ view: NSView, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        selfTestWindows.append(window)
    }

    /// ⏎ 交出去的那一段判断的"实际是什么"。
    ///
    /// 断言和打印共用这一个函数：`SelectionOutcome` 既没有 Equatable 也没有可读的
    /// 调试描述，✗ 那行若不带实际值，就只是在复读期望。
    private static func adoptKind(of outcome: SelectionOutcome?) -> String {
        switch outcome {
        case let .window(_, frame):
            return "窗口 \(Int(frame.width))×\(Int(frame.height))"
        case .display:
            return "整屏"
        case let .region(rect, _):
            return "区域 \(Int(rect.width))×\(Int(rect.height))"
        case .cancelled, nil:
            return "没有（等于取消）"
        }
    }

    /// 几何断言：提示条承诺的 ⇧ / ⌥ 行为必须真的做出来。
    ///
    /// 「说了没做」是这类工具最常见的半成品痕迹，而它恰好只有拿数字才查得出来 ——
    /// ⌥ 那一条原本写着"从中心向外扩"，代码里却只是把位移乘 2（按下点仍然是角）。
    private static func printDragGeometry(size: NSSize) {
        let anchor = NSPoint(x: 400, y: 400)
        let drag = (start: anchor, at: NSPoint(x: 520, y: 450))

        func rect(with modifiers: NSEvent.ModifierFlags) -> NSRect? {
            let view = OverlayView(frame: NSRect(origin: .zero, size: size))
            view.populateForSelfTest(hover: nil, isDisplayCandidate: false,
                                     drag: drag, modifiers: modifiers)
            return view.selectionRectForSelfTest
        }

        guard let square = rect(with: [.shift]), let centered = rect(with: [.option]) else {
            say("    拖拽几何对账没做成")
            return
        }
        let squareOK = abs(square.width - square.height) < 0.5 && square.width > 100
        let centerOK = abs(centered.midX - anchor.x) < 0.5 && abs(centered.midY - anchor.y) < 0.5
        say(String(format: "    ⇧ 锁正方形 → %.0f×%.0f　%@",
                     square.width, square.height, squareOK ? "✓" : "✗ 没锁住"))
        say(String(format: "    ⌥ 从中心 → 中心 (%.0f,%.0f) / 按下点 (%.0f,%.0f)　%@",
                     centered.midX, centered.midY, anchor.x, anchor.y,
                     centerOK ? "✓ 按下点就是中心" : "✗ 按下点还在角上，只是拖得快"))
    }

    /// 图里有多少像素是"强调色"（蓝占优且够亮）：选区框和手柄专用。
    private static func accentPixelCount(_ image: CGImage) -> Int? {
        let width = image.width, height = image.height
        guard let ctx = pixelContext(width: width, height: height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = ctx.data else { return nil }
        let pixels = base.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var count = 0
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            if b > 140, b - r > 50, b - g > 30 { count += 1 }
        }
        return count
    }

    private static func pixelContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 无障碍体检：图标按钮和自绘交互视图必须报得出名字。
    ///
    /// 只画得好看算不算"成熟"不算完 —— VoiceOver 用户点上去听到的是
    /// "按钮"两个字，等于这个控件对他不存在。这一条没法用截图验，只能直接查
    /// `accessibilityLabel()`，所以顺手做成断言。
    /// 这个控件是不是"得我们自己给个朗读名"那一类。
    ///
    /// 抽成函数是为了让探针和真检查用的是**同一份判据** —— 各写一遍迟早会漂移。
    private static func needsAccessibleName(_ view: NSView) -> Bool {
        if let button = view as? NSButton {
            // 有文字的按钮系统会自己拿标题当名字，只有纯图标按钮才要额外标
            return button.image != nil
                && button.title.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if let field = view as? NSTextField {
            // 空框不等于没名字：placeholder 就是 VoiceOver 念出来的那个名字。
            // 接了 ⌘F 之后系统那两个查找框就是这种 —— 判成"缺名字"是一条会误报的检查，
            // 而会误报的检查明天就没人信了。
            return field.stringValue.isEmpty && (field.placeholderString ?? "").isEmpty
        }
        return customInteractiveClasses.contains("\(type(of: view))")
    }

    /// 这些类是自己 draw + 自己吃鼠标事件的，AppKit 给不出任何有意义的默认朗读。
    private static let customInteractiveClasses: [String] = [
        "OverlayView", "ImagePreviewView", "ResizeHandlesView", "InkLayer",
        // 文字层实际实例是 `HighlightMenuView`（`OCRHighlightView` 的子类，只补一条
        // 右键转发）。基类从不被直接实例化，放进来会变成一条永远见不到的僵尸，
        // 而真正上屏的子类反倒因为判据只认基类名而逃过朗读名检查。
        "HighlightMenuView", "ToastCardView", "HotKeyRecorderView"
    ]

    /// 我们自己写的、但**不该**由类名清单来要朗读名的视图。
    ///
    /// 列在这儿是为了让下面那道"新面孔"闸门只对真正没人管的名字报警 —— 每一行都得
    /// 写清它归谁管，不然这个清单会变成"为了让自检闭嘴而加的白名单"。
    private static let customClassesCoveredElsewhere: Set<String> = [
        "BackdropView", "DimOverlayView", "ToolbarBackgroundView",  // 只画、不接鼠标、没内容可念
        "SettingsCardView",   // 同上：设置面板的分组卡片底，纯装饰
        "PassthroughImageView",   // NSImageView 且 hitTest 返回 nil：鼠标根本到不了它
        "ToolbarButton"           // NSButton 子类：走的是"图标 + 空标题"那条判据，且都设了朗读名
    ]

    private static func printAccessibilityCheck(roots: [(String, NSView)]) {
        // 清单里不能有重复对象：上一版四个设置面板收的是同一个 `window.contentView`，
        // 于是"四个面"其实是同一个面被数了四遍，而另外三个面一个控件都没被走到。
        let ids = roots.map { ObjectIdentifier($0.1) }
        let distinct = Set(ids).count
        if distinct != roots.count {
            say("    ✗ 清单里有 \(roots.count - distinct) 个根是同一个对象被重复登记的"
                + "（数出来的分母是假的，而真正没登记的那面永远查不到）")
        }
        var flagged: [String] = []
        var checked = 0
        // 分面报数，不只报总数。上一轮总数从 14 跳到 26，谁也说不清是"多查了"还是
        // "少查了" —— 而 `needsAccessibleName` 对文本框看的是**当前有没有字**，
        // 一个填了内容的状态行会静默掉出分母。摊到每个面上，掉没掉一眼看得见。
        var perRoot: [(String, Int, Int, Int)] = []   // 面　需要　缺　带显式朗读名
        for (name, root) in roots {
            var rootChecked = 0, rootMissing = 0, rootNamed = 0
            walkForAccessibility(root, depth: 0) { view in
                guard needsAccessibleName(view) else { return }
                checked += 1
                rootChecked += 1
                if !(view.accessibilityLabel() ?? "").isEmpty { rootNamed += 1 }
                let label = (view.accessibilityLabel() ?? "").trimmingCharacters(in: .whitespaces)
                if label.isEmpty {
                    let typeName = "\(type(of: view))"
                    let hint: String
                    if let field = view as? NSTextField {
                        hint = "placeholder: \(field.placeholderString ?? "—")　tooltip: \(view.toolTip ?? "—")"
                    } else {
                        hint = "tooltip: \(view.toolTip ?? "—")"
                    }
                    flagged.append("\(name) › \(typeName)（\(hint)）")
                    rootMissing += 1
                }
            }
            perRoot.append((name, rootChecked, rootMissing, rootNamed))
        }

        // 探针：判据本身也要被查一次。两个框都是空的，区别只在有没有 placeholder ——
        // 少了一半判据（只看 stringValue）就会把系统查找框报成缺陷，
        // 多了一半（placeholder 一律算名字）又会放过真的没名字的框。
        let bare = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let hinted = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        hinted.placeholderString = "查找"
        let bareCaught = needsAccessibleName(bare)
        let hintedSpared = !needsAccessibleName(hinted)

        say("── 无障碍（图标按钮 / 自绘交互视图的朗读名）")
        say("    需要名字的控件 \(checked)　缺名字 \(flagged.count)　\(flagged.isEmpty ? "✓" : "✗")")
        for (name, need, miss, named) in perRoot {   // 0 也要打出来：分母掉下去得看得见
            say(String(format: "    · %14@ 需要 %2d　缺 %d　其中带显式朗读名 %2d",
                       name as NSString, need, miss, named))
        }
        say("    判据探针：空框要名字 \(bareCaught ? "✓" : "✗")　有 placeholder 的空框放过 \(hintedSpared ? "✓" : "✗")")
        // 清单是手写的，手写的清单会两头坏：新加的自绘视图没进清单（它就永远不被查），
        // 或者清单里留着已经不存在的类（它让清单看起来比实际管得多）。
        // 所以两头都量：见到没登记的名字要红，登记了却一个都没见到的要说一声。
        var seenCustom: Set<String> = []
        for (_, root) in roots {
            walkForAccessibility(root, depth: 0) { view in
                // 判"是不是我们自己写的类"不能用名字前缀 —— 可执行文件里
                // `type(of:)` 打出来就是裸类名。看它定义在哪个 bundle：
                // AppKit 的控件解到 AppKit.bundle，我们的解到本程序。
                let cls: AnyClass = type(of: view)
                if Bundle(for: cls).bundlePath != Bundle(for: NSView.self).bundlePath {
                    seenCustom.insert("\(cls)")
                }
            }
        }
        let unknown = seenCustom.subtracting(customInteractiveClasses)
                          .subtracting(customClassesCoveredElsewhere)
        let zombies = Set(customInteractiveClasses).subtracting(seenCustom)
        if !unknown.isEmpty {
            say("    ✗ 出现了没登记的自绘视图类：\(unknown.sorted().joined(separator: "、"))"
                + "（不在判据里 = 它有没有朗读名没人查）")
        }
        if !zombies.isEmpty {
            say("    △ 清单里这些类这一趟一个都没见到：\(zombies.sorted().joined(separator: "、"))")
        }
        for item in flagged.prefix(14) {
            say("    · \(item)")
        }
        if flagged.count > 14 { say("    · 其余 \(flagged.count - 14) 个略") }
    }

    /// AppKit 自带控件说什么语言。
    ///
    /// 没有 `.lproj` 时它会按 `CFBundleDevelopmentRegion` 来 —— 中文机器上看不出
    /// 问题，英文用户却会拿到一套中文边栏（反过来也一样）。这里不查某个 plist 键，
    /// 只守 bundle 同时声明中英文，让系统控件能跟用户语言走。
    private static func printLocalizationCheck() {
        // 裸二进制没有 bundle 声明，不能据此给产品下结论。
        let inBundle = Bundle.main.bundlePath.hasSuffix(".app")
        let localizations = Bundle.main.localizations
        let wantsChinese = (Locale.preferredLanguages.first ?? "").hasPrefix("zh")
        say("── 语言声明（AppKit 自带控件跟着它走）")
        if !inBundle {
            say("    未验到：跑的是裸二进制（\(Bundle.main.bundlePath))，没有 bundle 声明可查；"
                  + "装机版才算数")
            return
        }
        // 声明只当背景信息打印；真正要守的是 bundle 同时声明中英文。
        say("    bundle 声明 \(localizations.joined(separator: "、"))（信息）")
        let declaresChinese = localizations.contains { $0.hasPrefix("zh") }
        let declaresEnglish = localizations.contains { $0.hasPrefix("en") }
        let declarationOK = declaresChinese && declaresEnglish
        say("    bundle 语言声明" + (declarationOK ? "中英文都在" : "缺一档")
            + "　当前系统语言偏好 \(wantsChinese ? "中文" : "非中文")　"
            + (declarationOK ? "✓" : "✗"))
        if !declarationOK {
            say("    ✗ bundle 未同时声明中文与英文，系统控件可能不跟用户语言走")
        }
    }

    /// 深度遍历一棵视图树。`depth` 只给调试打印用，访问顺序是"父先子后"。
    private static func walkForAccessibility(_ view: NSView, depth: Int, _ visit: (NSView) -> Void) {
        visit(view)
        view.subviews.forEach { walkForAccessibility($0, depth: depth + 1, visit) }
    }

    /// 菜单结构体检：分隔线、空标题、"可点但没有任何动作"、快捷键撞车。
    ///
    /// 这四类都是截图看不出来的 —— 菜单要点了才有，而自检不能点菜单。
    /// 主菜单里那两条截图命令。app 一激活（打开设置、弹权限说明），这排菜单就是
    /// 用户唯一**看得见**的截图入口 —— 全局热键没人会去猜，图标又可以被隐藏。
    private static func printCaptureMenuCheck() {
        guard let app = NSApp.mainMenu?.items.first?.submenu else {
            say("      ✗ 应用菜单没建起来，这一组没跑成")
            return
        }
        let settings = SettingsStore.shared
        let expected: [(String, HotKeySpec, Selector)] = [
            ("截图", settings.hotKeyCapture, #selector(AppController.captureFromMenu(_:)))
        ]
        var bad = 0
        for (title, spec, selector) in expected {
            guard let item = app.items.first(where: { $0.title == title }) else {
                say("      ✗ 「\(title)」不在主菜单里")
                bad += 1
                continue
            }
            let want = spec.menuKeyEquivalent
            let keyOK = item.keyEquivalent == (want?.key ?? "")
                && item.keyEquivalentModifierMask == (want?.modifiers ?? [])
            // target 必须是 nil：走响应链，app 没激活到能截图的上下文时自动是灰的
            let wiringOK = item.action == selector && item.target == nil
            if !keyOK || !wiringOK { bad += 1 }
            say("      \(keyOK && wiringOK ? "✓" : "✗") 「\(title)」指向 \(NSStringFromSelector(selector))，组合键与设置里的 \(spec.displayString) 一致")
        }
        let hasRefresher = app.delegate != nil
        say("      \(hasRefresher ? "✓" : "✗") 应用菜单挂了弹出时重标的 delegate（热键改了菜单不跟着变 = 第二份真相）")
        // 把键位故意改歪，再 update()：重标那条必须按**当前设置**把它掰回来。
        // 不去动偏好本身 —— 自检不该改用户的热键；而"歪了能掰回来"恰好同时证明
        // delegate 真在跑、且读的是设置而不是建菜单时的快照。
        if let first = app.items.first(where: { $0.title == expected[0].0 }) {
            first.keyEquivalent = "q"
            first.keyEquivalentModifierMask = [.command, .control, .option, .shift]
        }
        // 用 `menuNeedsUpdate` 而不是 `update()`：实测 `update()` 只做启用/禁用
        // 校验，不会叫到 delegate（第一版就是这么写出了一行假红）。
        // "菜单弹出前系统一定会调 menuNeedsUpdate" 是 AppKit 的承诺，
        // 这里能验的是"挂了这个 delegate"和"它确实按当前设置重标"。
        app.delegate?.menuNeedsUpdate?(app)
        let snappedBack = expected.allSatisfy { (title, spec, _) in
            guard let item = app.items.first(where: { $0.title == title }) else { return false }
            return item.keyEquivalent == (spec.menuKeyEquivalent?.key ?? "")
                && item.keyEquivalentModifierMask == (spec.menuKeyEquivalent?.modifiers ?? [])
        }
        say("      \(snappedBack ? "✓" : "✗") 键位被改歪后让 delegate 重标一遍，按当前设置掰回来了（读的是设置不是快照）")
        if !snappedBack { bad += 1 }

        // 「关于」这排是版本号的**唯一**去处 —— 状态栏菜单瘦身时把「关于 Grabi」
        // 那一条删了（它占一行，而版本号一年变不了几次）。删掉的前提是这儿还在：
        // 系统那条关于面板会自己读 Info.plist，不用app 抄一份版本字符串，
        // 所以它天然没有"第二份真相"的问题。
        let about = app.items.first { $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) }
        let aboutOK = about?.title == "关于 Grabi" && about?.target == nil
        say("      \(aboutOK ? "✓" : "✗") 「\(about?.title ?? "（没有这一条）")」在应用菜单里，target 留 nil 走响应链"
            + "（版本号从这里问，菜单里不再单占一行）")

        say("  截图菜单命令 \(expected.count) 条　不对 \(bad) 条　\(bad == 0 ? "✓" : "✗")")
    }

    /// 菜单栏图标：一副四角括号 + 中心镜头环。三份状态都由像素说话。
    ///
    /// 这一组为什么值得单开：图标是整个 app 唯一"常驻在屏幕上"的东西，而它以前是
    /// 货架上的 `camera.viewfinder` —— 截图类 app 一半在用那枚符号。现在它自己画，
    /// 那就得回答"画对了吗"：括号真的在四个角上、四份一样重、中心有快门环，
    /// 而"拍到"那一档只是把中心填实（旧写法整枚符号换掉，
    /// 读起来像换了个 app）。这几件事光看代码看不出来。
    private static func printStatusIconCheck(in directory: String) {
        // 三份状态 + 一份同尺寸空图（反证用）。
        let states: [(String, StatusIcon.State)] = [("normal", .normal),
                                                    ("flashed", .flashed),
                                                    ("warning", .warning)]

        // 2× 是 Retina 菜单栏上真实落下的那点尺寸：1× 太薄，量不出四份配重；
        // 再大就是按放大图判，反而把"1px 的缝"藏掉了。
        func raster(_ image: NSImage, zoom: CGFloat) -> CGImage? {
            let side = Int(StatusIcon.side * zoom)
            guard side > 1, let ctx = pixelContext(width: side, height: side) else { return nil }
            ctx.scaleBy(x: zoom, y: zoom)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            image.draw(in: NSRect(x: 0, y: 0, width: StatusIcon.side, height: StatusIcon.side))
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }

        /// 一块矩形里有多少像素被画上了东西（alpha > 60）。
        func coverage(_ image: CGImage, x0: Int, y0: Int, w: Int, h: Int) -> Int {
            let full = image.width
            return withPixels(image, { px, _ in
                var count = 0
                for y in max(0, y0)..<min(full, y0 + h) {
                    for x in max(0, x0)..<min(full, x0 + w) {
                        if px[(y * full + x) * 4 + 3] > 60 { count += 1 }
                    }
                }
                return count
            }) ?? -1
        }

        // 大 12 倍的图两个通道各存一张（渲染清单按"每个通道各有一张"对账），
        // 也是给人眼看的那张：断言防得住配重和空芯，防不住"感叹号在 16pt 上糊成一坨"。
        for (name, state) in states {
            saveIcon(raster(StatusIcon.image(state), zoom: 12),
                     name: "status-icon-\(name).png", in: directory)
        }

        guard emitChecks else { return }
        say("── 菜单栏图标（四角取景框 + 中心镜头环）")
        var rasters: [(String, CGImage)] = []
        for (name, state) in states {
            guard let cg = raster(StatusIcon.image(state), zoom: 2) else {
                say("    ✗ 「\(name)」这张画不出来，这一组没跑成")
                return
            }
            rasters.append((name, cg))
        }
        func found(_ name: String) -> CGImage { rasters.first { $0.0 == name }!.1 }

        let side = Int(StatusIcon.side * 2)
        // 中间那 1/3：状态点该在这儿，括号一条都不该伸进来。
        let center = side / 3
        let centerBox = (x0: center, y0: center, w: side - center * 2, h: side - center * 2)
        let normalInk = coverage(found("normal"), x0: 0, y0: 0, w: side, h: side)
        let normalCenter = coverage(found("normal"), x0: centerBox.x0, y0: centerBox.y0,
                                    w: centerBox.w, h: centerBox.h)
        say("    \(normalInk > 0 ? "✓" : "✗") 常态有笔画（整枚图落上 \(normalInk) 个像素）")
        say("    \(normalCenter > 0 ? "✓" : "✗") 常态中心有快门环（读到 \(normalCenter) 个像素）"
            + "　·　这条同时是下面两档的反证：中心只要不是 0，就分不清哪一档画错了")

        let flashCenter = coverage(found("flashed"), x0: centerBox.x0, y0: centerBox.y0,
                                   w: centerBox.w, h: centerBox.h)
        let warnCenter = coverage(found("warning"), x0: centerBox.x0, y0: centerBox.y0,
                                  w: centerBox.w, h: centerBox.h)
        say("    \(flashCenter > normalCenter && warnCenter > 0 ? "✓" : "✗") "
            + "「拍到」把快门填实、「缺权限」在中心有感叹号"
            + "（\(flashCenter) / \(warnCenter) 个像素，常态 \(normalCenter)）")

        // 括号部分在三档之间不许动 —— 换掉整枚符号那种闪法就是这么露馅的。
        func outer(_ image: CGImage) -> Int {
            coverage(image, x0: 0, y0: 0, w: side, h: side)
                - coverage(image, x0: centerBox.x0, y0: centerBox.y0,
                           w: centerBox.w, h: centerBox.h)
        }
        let outerNormal = outer(found("normal"))
        let outerFlash = outer(found("flashed"))
        say("    \(abs(outerNormal - outerFlash) <= 4 ? "✓" : "✗") 闪一下的时候括号一动不动，"
            + "只有中心多了点东西（外面 \(outerNormal) vs \(outerFlash)，容差 4）")

        // 四份配重：四角括号按象限数，四个象限该一样重。
        let halves = side / 2
        let quadrants = [(0, 0), (halves, 0), (0, halves), (halves, halves)]
        let weights = quadrants.map { coverage(found("normal"), x0: $0.0, y0: $0.1,
                                               w: halves, h: halves) }
        let spread = (weights.max() ?? 0) - (weights.min() ?? 0)
        say("    \(spread <= 6 && weights.allSatisfy { $0 > 0 } ? "✓" : "✗") 四角一样重："
            + "左上/右上/左下/右下 = \(weights.map(String.init).joined(separator: "/"))（差 \(spread)，容差 6）")

        // 几何那几条是画布的硬约束：臂比笔画长、两条臂不许在一条边上撞到一起、
        // 边距不许小到把笔画切在画布外。这些数一旦被人调坏，图标会糊成一团，
        // 而糊成什么样的截图要人眼来看 —— 先把它们变成能红的断言。
        let box = StatusIcon.side - StatusIcon.inset * 2
        let geo: [(String, Bool)] = [
            ("臂长过一笔的宽（不然四个角糊成四个点）", StatusIcon.arm > StatusIcon.stroke),
            ("一条边放得下两端（2×臂 + 一笔 ≤ 方框边长）", 2 * StatusIcon.arm + StatusIcon.stroke <= box),
            ("边距够画完整根笔画（不然括号被裁在画布外）",
                StatusIcon.inset * 2 >= StatusIcon.stroke)
        ]
        for (label, ok) in geo { say("    \(ok ? "✓" : "✗") \(label)") }

        // 模板位和朗读名：菜单栏按它解算浅色/深色，读屏按它报名字。
        let templates = states.allSatisfy { StatusIcon.image($0.1).isTemplate }
        let names = Set(states.map { StatusIcon.image($0.1).accessibilityDescription ?? "" })
        say("    \(templates ? "✓" : "✗") 三份都是模板图（菜单栏自己配深浅底）")
        say("    \(names.count == states.count && !names.contains("") ? "✓" : "✗") "
            + "三份的朗读名各不相同且都非空　读到 \(names.sorted().joined(separator: " / "))")

        // 空图反证：什么也不画时，上面那把尺子必须读到 0。
        let blank = NSImage(size: NSSize(width: StatusIcon.side, height: StatusIcon.side),
                            flipped: false) { _ in true }
        let blankInk = raster(blank, zoom: 2).map { coverage($0, x0: 0, y0: 0, w: side, h: side) } ?? -1
        say("    \(blankInk == 0 ? "✓" : "✗") 反向对照：一张什么都不画的同尺寸图读到 \(blankInk) 个像素"
            + "（上面那些数不是把底色数进去了）")
    }

    /// 图标贴在一条浅灰底上存盘（菜单栏那种底），并把成败记进渲染清单。
    private static func saveIcon(_ image: CGImage?, name: String, in directory: String) {
        guard let image,
              let ctx = pixelContext(width: image.width, height: image.height) else {
            renderShots.append((passLabel, name, false))
            return
        }
        ctx.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: flat).representation(using: .png,
                                                                       properties: [:]) else {
            renderShots.append((passLabel, name, false))
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: "\(directory)/\(name)"))
            renderShots.append((passLabel, name, true))
        } catch {
            renderShots.append((passLabel, name, false))
            Log.ui.error("写 \(name) 失败：\(error.localizedDescription)")
        }
    }

    /// 标注工具那一组：**按下去得到的是眼睛看到的那一颗**，不是"下一种"。
    ///
    /// 这一组全部走 `performClick` / `target.perform(action:)` 那条真分发，
    /// 不直接给状态赋值 —— 属性和按钮写在一起不代表按钮接的是它。
    /// 上一版那颗"形状"按钮的毛病恰恰只有真点一下才看得出来：
    /// 图标画的是矩形，点第一下得到的是椭圆。
    private static func printInkToolCheck() {
        guard emitChecks else { return }
        say("── 标注工具（点哪颗就是哪颗 · 颜色一栏 · 光标）")
        let controller = InlinePreviewController()

        func buttons(_ stack: NSStackView) -> [NSButton] {
            stack.arrangedSubviews.compactMap { view in
                guard let button = view as? NSButton,
                      let tip = button.toolTip,
                      inkTooltipPrefixes.contains(where: { tip.hasPrefix($0) }) else { return nil }
                return button
            }
        }
        func button(named prefix: String) -> NSButton? {
            buttons(controller.toolbarStack(for: .normal, saved: false))
                .first { $0.toolTip?.hasPrefix(prefix) == true }
        }

        // ① 第一下 = 选中它。四颗各点一次，每次都必须得到它自己。
        var wrong: [String] = []
        for shape in Ink.Shape.allCases {
            let target = shape
            guard let button = button(named: target.name) else { wrong.append("\(target.name)：没这颗按钮"); continue }
            button.performClick(nil)
            if controller.inkToolForSelfTest != .shape(target) {
                wrong.append("\(target.name)：点第一下得到 \((controller.inkToolForSelfTest.map { "\($0)" } ?? "空"))")
            }
            // 再点同一颗 = 收起。不是换到下一种。
            button.performClick(nil)
            if controller.inkToolForSelfTest != nil { wrong.append("\(target.name)：再点一下没收起") }
        }
        say("      \(wrong.isEmpty ? "✓" : "✗") 四种形状各点第一下就选中它自己，再点收起"
            + (wrong.isEmpty ? "" : "　← " + wrong.joined(separator: "；")))

        guard let pen = button(named: "画笔") else {
            say("      ✗ 找不到画笔那颗，这一组剩下的没跑成")
            return
        }
        pen.performClick(nil)
        let penOK = controller.inkToolForSelfTest == .pen
        say("      \(penOK ? "✓" : "✗") 画笔第一下就是画笔（读到 \(String(describing: controller.inkToolForSelfTest))）")
        pen.performClick(nil)

        // ② 选中之后，那颗按钮的 tooltip 要改口说"已选中"：
        //    画着选中态却还写着"按住拖出矩形"，等于按钮上那句话是假的。
        button(named: "椭圆")?.performClick(nil)
        let selectedTip = button(named: "椭圆")?.toolTip ?? ""
        let tipOK = selectedTip.hasPrefix("椭圆已选中")
        say("      \(tipOK ? "✓" : "✗") 选中之后那颗自己说「已选中」（读到「\(selectedTip)」）")

        // ③ Esc 两段：**先停笔**，不是直接把面板收走。
        controller.pressEscape()
        let escKeepsPanel = controller.inkToolForSelfTest == nil
        say("      \(escKeepsPanel ? "✓" : "✗") 画着的时候按 Esc：只停笔，面板还在"
            + "（工具读到 \(String(describing: controller.inkToolForSelfTest))）")

        // ④ 颜色那一栏：候选色 + 线宽 + 调色盘，一次点开设完。
        let menu = controller.inkColorMenuForSelfTest()
        let colorItems = menu.items.filter { $0.action != nil
            && NSStringFromSelector($0.action!) == "pickInkColor:" }
        let widthItems = menu.items.filter { $0.action != nil
            && NSStringFromSelector($0.action!) == "pickInkWidth:" }
        let palette = menu.items.first { $0.action != nil
            && NSStringFromSelector($0.action!) == "openColorPalette" }
        let menuShape = colorItems.count == InlinePreviewController.inkColors.count
            && widthItems.count == Ink.widthChoices.count && palette != nil
            && colorItems.allSatisfy { $0.image != nil }
        say("      \(menuShape ? "✓" : "✗") 颜色一栏 \(colorItems.count) 档候选色（每档都带色块）"
            + "　线宽 \(widthItems.count) 档　·　「\(palette?.title ?? "没有")」在")
        let onCount = colorItems.filter { $0.state == .on }.count
        say("      \(onCount == 1 ? "✓" : "✗") 当前那一档带着勾，而且只有一档（读到 \(onCount)）")

        // 点菜单里的一档 = 真的改了笔色 / 线宽（走 target.perform，和系统弹菜单那条一样）。
        guard let blue = colorItems.first(where: { $0.title == "蓝" }) else {
            say("      ✗ 菜单里没有「蓝」，后面两条没跑成")
            return
        }
        if let action = blue.action { _ = blue.target?.perform(action, with: blue) }
        let picked = InlinePreviewController.isSameColor(controller.inkColorForSelfTest, .systemBlue)
        say("      \(picked ? "✓" : "✗") 点菜单里那档「蓝」，当前笔色真的变成蓝（读到 \(controller.inkColorForSelfTest)）")
        let thick = widthItems.first { $0.title.hasSuffix("粗") }
        if let thick, let action = thick.action { _ = thick.target?.perform(action, with: thick) }
        let widthOK = controller.inkWidthForSelfTest == 5
        say("      \(widthOK ? "✓" : "✗") 点「线宽：粗」，线宽读到 "
            + "\(controller.inkWidthForSelfTest)pt（菜单上那个 tag 和表里对得上）")
        let tagOK = widthItems.allSatisfy { item in
            Ink.widthChoices.contains { $0.points == CGFloat(item.tag) }
        }
        say("      \(tagOK ? "✓" : "✗") 反向对照：三档线宽的 tag 全是表里真有的值（不是拿 title 现编）")

        // ⑤ 光标：选中工具之后不许再画那只"能拖走"的手。
        let layer = InkLayer(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let cursorNoneOK = layer.cursorForSelfTest == nil
        layer.tool = .pen
        let penCursor = layer.cursorForSelfTest
        let shapeCursors = Ink.Shape.allCases.map { shape -> NSCursor? in
            layer.tool = .shape(shape)
            return layer.cursorForSelfTest
        }
        let penCursorOK = penCursor === InkLayer.cursor(for: .pen)
        let shapeCursorOK = shapeCursors.allSatisfy { $0 === NSCursor.crosshair }
        say("      \(cursorNoneOK ? "✓" : "✗") 没选工具时光标不主张（那块地方还是「按住拖走面板」）")
        say("      \(penCursorOK ? "✓" : "✗") 画笔那颗是自定义的笔尖光标（读到 "
            + "\(penCursor.map { "\($0.image.size.width)pt 的光标" } ?? "nil"))")
        say("      \(shapeCursorOK ? "✓" : "✗") 四种形状各点一次，光标全是十字　读到 "
            + shapeCursors.compactMap { $0 == nil ? "nil" : "十字" }.joined(separator: " "))
        // 一句里塞两条判据时，漏掉一条也照样绿 —— 上面那两条各查各的，
        // 这条再确认两支真的是两支（都返回同一只光标时前两条会一起变成一句谎）。
        let twoDifferent = penCursor !== NSCursor.crosshair
        say("      \(twoDifferent ? "✓" : "✗") 反向对照：笔尖和十字是两只不同的光标"
            + "（同一个对象的话上面那两条各说各的都不算数）")
        let hot = InkLayer.penCursor.hotSpot
        let side = InkLayer.penCursor.image.size.width
        let hotOK = abs(hot.x - side / 2) < 0.01 && abs(hot.y - side / 2) < 0.01
        say("      \(hotOK ? "✓" : "✗") 笔尖光标的热点在正中央"
            + String(format: "（%.0f, %.0f) / %.0fpt", hot.x, hot.y, side)
            + "　·　不然就是「看着圈的是这里、画上去差两像素」")
        if let cursorImage = InkLayer.penCursor.image.cgImage(forProposedRect: nil,
                                                             context: nil, hints: nil),
           let ink = withPixels(cursorImage, { px, count in
               var n = 0
               for index in stride(from: 0, to: count, by: 4) where px[index + 3] > 60 { n += 1 }
               return n
           }), let center = withPixels(cursorImage, { px, count in
               let w = Int((Double(count) / 4).squareRoot())
               return px[((w / 2 * w) + w / 2) * 4 + 3]
           }) {
            let ringOK = ink > 20 && center < 60
            say("      \(ringOK ? "✓" : "✗") 那枚光标画得出来是个环：整枚 \(ink) 个像素、正中心 alpha "
                + "\(center)（中心实心就盖住要圈的那点了）")
        } else {
            say("      ✗ 笔尖光标取不到位图，这一条没跑成")
        }
    }

    private static func printMenuCheck() {
        var problems: [String] = []
        var audited = 0

        func audit(_ menu: NSMenu, _ path: String, requiresTarget: Bool) {
            // 从 true 起算：开头就是一条分隔线，和连续两条一样多余。
            var previousWasSeparator = true
            // 撞车只按**当前这一层菜单**查。原本还想跨菜单共用一张表（主菜单的键是
            // 全 app 解析的），反向对照把它证伪了：AppKit 会在挂上菜单栏的那一刻
            // **静默清掉后出现的重复键**（给「查找下一个」也配 ⌘C，它的 keyEquivalent
            // 直接变成空；给 performMiniaturize: 配 ⌘C，它被改回标准的 ⌘M）。
            // 也就是说"跨菜单撞车"这个状态读菜单时已经不存在了，那张表永远查不到东西
            // —— 一条按构造不可能变红的检查比没有检查更糟，所以删掉。
            // 真正抓得住这类问题的是"逐条核对意图"那种写法，见 printFindMenuCheck。
            var seenKeys: [String: String] = [:]

            for (index, item) in menu.items.enumerated() {
                let place = "\(path) › 第 \(index + 1) 项"
                if item.isSeparatorItem {
                    if previousWasSeparator { problems.append("\(place) 分隔线重复（或开头就多一条）") }
                    previousWasSeparator = true
                    continue
                }
                previousWasSeparator = false
                audited += 1

                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = title.isEmpty ? (item.submenu?.title ?? "") : title
                if name.isEmpty { problems.append("\(place) 标题是空的") }

                if !item.keyEquivalent.isEmpty {
                    // 组合键要**连 ⇧ 一起算**：撤销 ⌘Z 和重做 ⇧⌘Z 是一对，
                    // 只看 ⌘Z 会把它们报成撞车。一条会误报的检查，很快就不有人信了。
                    var combo = ""
                    if item.keyEquivalentModifierMask.contains(.control) { combo += "⌃" }
                    if item.keyEquivalentModifierMask.contains(.option) { combo += "⌥" }
                    if item.keyEquivalentModifierMask.contains(.shift) { combo += "⇧" }
                    if item.keyEquivalentModifierMask.contains(.command) { combo += "⌘" }
                    combo += item.keyEquivalent.uppercased()
                    if let other = seenKeys[combo] {
                        problems.append("\(path) 里 \(combo) 同时挂在「\(other)」和「\(name)」上")
                    }
                    seenKeys[combo] = name
                }

                if let submenu = item.submenu {
                    audit(submenu, "\(path) › \(name)", requiresTarget: false)
                } else if item.action == nil {
                    // 没动作也没子菜单 = 一行说明文字。那它**必须**是禁用态，
                    // 否则用户会点到一个纹丝不动的条目上。
                    if item.isEnabled {
                        problems.append("\(place)「\(name)」可点，但没有任何动作")
                    }
                } else if requiresTarget, item.target == nil {
                    problems.append("\(place)「\(name)」有动作却没指定目标（响应链上大概率没人接）")
                }
            }

            if let last = menu.items.last, last.isSeparatorItem {
                problems.append("\(path) 末尾多一条分隔线")
            }
        }

        MainMenu.install()
        if let main = NSApp.mainMenu {
            // 主菜单里的编辑项**故意**不挂 target：靠响应链点亮/置灰。
            audit(main, "主菜单", requiresTarget: false)
        }
        let statusBar = StatusBarController()
        if let statusMenu = statusBar.menuForSelfTest {
            statusBar.menuWillOpen(statusMenu)
            audit(statusMenu, "菜单栏菜单", requiresTarget: true)
        } else {
            problems.append("菜单栏菜单没建起来，这一节没验到")
        }

        say("── 菜单体检（分隔线 / 空标题 / 可点却没动作 / 快捷键撞车）")
        say("    条目 \(audited)　问题 \(problems.count)　\(problems.isEmpty ? "✓" : "✗")")
        for problem in problems.prefix(12) { say("    · \(problem)") }
        if problems.count > 12 { say("    · 其余 \(problems.count - 12) 条略") }
        printFindMenuCheck()
    }

    /// 查找那一组菜单：标题、键、修饰键、tag 四样都得对上。
    ///
    /// `performFindPanelAction:` 是**一个** selector，靠 tag 分岔 —— tag 写错不会崩、
    /// 不会报错，只会让「查找下一个」弹出查找条。所以这里查的是 tag，不只是"有没有这一项"。
    private static func printFindMenuCheck() {
        // 这里**不**看 emitChecks：整节菜单体检只在两遍渲染跑完之后打印一次，
        // 跟着那个开关走会因为"外层已经把它关掉了"而一声不响地整节消失。
        MainMenu.install()
        let editMenu = NSApp.mainMenu?.items.first { $0.title == "编辑" }?.submenu
        guard let find = editMenu?.items.first(where: { $0.title == "查找" })?.submenu else {
            say("    ✗ 编辑菜单里没有「查找」子菜单（⌘F 那一组整个不存在）")
            return
        }
        let expected: [(String, String, NSEvent.ModifierFlags, Int)] = [
            ("查找…", "f", .command, 1),
            ("查找并替换…", "f", [.command, .option], 8),
            ("查找下一个", "g", .command, 2),
            ("查找上一个", "g", [.command, .shift], 3),
            ("使用划选内容查找", "e", .command, 7)
        ]
        say("    查找菜单（一个 selector + tag 分岔，所以 tag 必须逐条对）")
        var bad = 0
        for (title, key, modifiers, tag) in expected {
            guard let item = find.items.first(where: { $0.title == title }) else {
                say("      ✗ 缺「\(title)」")
                bad += 1
                continue
            }
            // 这个选择器属于 NSResponder 的查找面板那一套，Swift 侧没有对应的
            // `#selector` 可写，只能按名字比 —— 用 `NSSelectorFromString` 而不是
            // `Selector(("…"))`，后者编译器会当成手滑多打了一层括号。
            let selectorOK = item.action == NSSelectorFromString("performFindPanelAction:")
            let keyOK = item.keyEquivalent == key && item.keyEquivalentModifierMask == modifiers
            if !selectorOK || !keyOK || item.tag != tag {
                bad += 1
                let what = [selectorOK ? nil : "selector 不对",
                            keyOK ? nil : "组合键不对",
                            item.tag == tag ? nil : "tag 应为 \(tag) 实为 \(item.tag)"]
                    .compactMap { $0 }.joined(separator: "，")
                say("      ✗ 「\(title)」\(what)")
            } else {
                say("      ✓ 「\(title)」")
            }
        }
        say("    查找菜单 \(expected.count) 项　不对 \(bad) 项　\(bad == 0 ? "✓" : "✗")")
    }

    /// 纯图标按钮必须带 tooltip。
    ///
    /// 朗读名管的是 VoiceOver 用户，鼠标用户靠的是悬停那一下的解释 —— 一个只有
    /// 图标、既不说话也不提示的按钮，只能靠猜。
    private static func printTooltipCheck(roots: [(String, NSView)]) {
        var missing: [String] = []
        var iconOnly = 0
        // 带组合键的按钮：tooltip 里必须写得出**它自己那个**键。
        var keyed = 0
        var keyNotShown: [String] = []
        var keyWrongOrder: [String] = []
        var keyImpostor: [String] = []
        for (name, root) in roots {
            walkForAccessibility(root, depth: 0) { view in
                guard let button = view as? NSButton else { return }
                let tip = (button.toolTip ?? "").trimmingCharacters(in: .whitespaces)
                let sel = button.action.map { NSStringFromSelector($0) } ?? "（无动作）"
                if !button.keyEquivalent.isEmpty {
                    keyed += 1
                    let want = shortcutLabel(key: button.keyEquivalent,
                                             modifiers: button.keyEquivalentModifierMask)
                    if !tip.contains(want) {
                        keyNotShown.append("\(name) › \(sel) 能按 \(want)，提示却是「\(tip.isEmpty ? "（空）" : tip)」")
                    }
                    if let bad = HotKeySpec.modifierOrderViolation(in: tip) {
                        keyWrongOrder.append("\(name) › \(sel) 写法 \(bad)（Apple 顺序是 \(want)）")
                    }
                    for token in shortcutTokens(in: tip) where token != want {
                        keyImpostor.append("\(name) › \(sel) 提示里的 \(token) 按不出去（它自己是 \(want)）")
                    }
                }
                guard button.image != nil,
                      button.title.trimmingCharacters(in: .whitespaces).isEmpty
                else { return }
                iconOnly += 1
                if tip.isEmpty {
                    // 用动作名报身份：`NSImage` 没有 `symbolName`（那是 UIKit 的），
                    // 而"哪个按钮"要的是能一眼认出来的东西。
                    missing.append("\(name) › \(sel)")
                }
            }
        }
        say("── 纯图标按钮的悬停提示")
        say("    纯图标按钮 \(iconOnly)　缺提示 \(missing.count)　\(missing.isEmpty ? "✓" : "✗")")
        for item in missing.prefix(12) { say("    · \(item)") }
        if missing.count > 12 { say("    · 其余 \(missing.count - 12) 个略") }

        // 悬停那一下弹不弹出来，离屏验不到（所以上面那条只查内容）；
        // 但"写了什么"查得住，而这三条恰恰是文案最容易跟实现分家的地方。
        let keyOK = keyNotShown.isEmpty && keyWrongOrder.isEmpty && keyImpostor.isEmpty
        say("    带组合键的按钮 \(keyed)　没写键 \(keyNotShown.count)　顺序写反 \(keyWrongOrder.count)"
            + "　写了别人的键 \(keyImpostor.count)　\(keyOK ? "✓" : "✗")")
        for item in (keyNotShown + keyWrongOrder + keyImpostor).prefix(12) {
            say("    · \(item)")
        }
    }

    /// 组合键 → 界面上那种写法。修饰键的**顺序和字形**都取自 `HotKeySpec.modifierGlyphs`，
    /// 不在这里再抄一份 ⌃⌥⇧⌘。
    private static func shortcutLabel(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var out = ""
        for glyph in HotKeySpec.modifierGlyphs {
            let flag: NSEvent.ModifierFlags
            switch glyph {
            case "⌃": flag = .control
            case "⌥": flag = .option
            case "⇧": flag = .shift
            default: flag = .command
            }
            if modifiers.contains(flag) { out.append(glyph) }
        }
        return out + key.uppercased()
    }

    /// 一段文案里出现的组合键（连着的修饰键 + 紧跟一个字母/数字）。
    /// 单个 ⌘ 后面不接键（比如「⌘ 键」）不算，免得把散文当快捷键读。
    private static func shortcutTokens(in text: String) -> [String] {
        let glyphs = Set(HotKeySpec.modifierGlyphs)
        let chars = Array(text)
        var out: [String] = []
        var index = 0
        while index < chars.count {
            guard glyphs.contains(chars[index]) else { index += 1; continue }
            var run = ""
            while index < chars.count, glyphs.contains(chars[index]) {
                run.append(chars[index]); index += 1
            }
            if index < chars.count, chars[index].isLetter || chars[index].isNumber {
                run.append(Character(chars[index].uppercased()))
                out.append(run)
                index += 1
            }
        }
        return out
    }

    /// 整张图的平均亮度（0–1）：画进一张 64×64 的 RGBA 上下文再取均值，够用。
    private static func meanBrightness(_ image: CGImage) -> CGFloat? {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total: CGFloat = 0
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            total += (0.299 * CGFloat(pixels[pixel])
                      + 0.587 * CGFloat(pixels[pixel + 1])
                      + 0.114 * CGFloat(pixels[pixel + 2])) / 255
        }
        return total / CGFloat(side * side)
    }

    /// 排版跑完后对账三件事，数字比目测难糊弄得多：
    /// 1. 每一节有没有排出真实高度（塌成标题那 16pt 就是布局崩了的老毛病）；
    /// 2. 有没有行排到容器宽度以外（超宽 = 右边被切掉）；
    /// 3. 窗口给够高度没有（不够 = 底部内容看不见也滚不到）。
    private static func printPaneFit(in content: NSView, needed: CGFloat,
                                     visible: CGFloat, document: CGFloat,
                                     scroll: NSScrollView?) {
        guard emitChecks else { return }
        guard let stack = firstPaneStack(in: content) else {
            say("    找不到面板容器，跳过对账")
            return
        }
        // 可见高 / 文档高都从控制器要，不靠 `stack.superview?.superview?...` 那条链：
        // 面板现在住在滚动视图里，链子上多了一节 clip view，靠层数认路会悄悄量错对象。
        let hostWidth = stack.frame.width

        var crushed = 0, overflow = 0
        for row in stack.arrangedSubviews {
            if row.frame.height < 24 { crushed += 1 }
            if row.frame.width > hostWidth + 0.5 { overflow += 1 }
            say(String(format: "    · %14@ h=%3.0f w=%3.0f",
                         "\(type(of: row))" as NSString, row.frame.height, row.frame.width))
        }

        let slack = visible - needed
        // 内容比可见区高不再是"底部被裁"—— 前提是那一截真的能滚到。
        // 判据因此变成两条：差额有没有被滚动视图接住，以及接住它的到底是滚动视图还是错觉。
        let scrollable = scroll?.hasVerticalScroller == true && document > visible + 0.5
        var verdict: String
        if slack < -0.5 {
            verdict = scrollable
                ? "溢出 \(-slack)pt　✓ 交给滚动（文档 \(Int(document)) > 可见 \(Int(visible))）"
                : "✗ 溢出 \(-slack)pt 而没有被滚动视图接住 —— 那一截看不见也滚不到"
        } else {
            verdict = slack > 40 ? "△ 空白偏多" : "✓"
        }
        if crushed > 0 { verdict += "　✗ \(crushed) 节塌了" }
        if overflow > 0 { verdict += "　✗ \(overflow) 行超宽" }
        say(String(format: "    面板需要 %.0f　可见 %.0f　余量 %+0.0f　%@",
                     needed, visible, slack, verdict))
    }

    /// 面板容器的形状是确定的：一个只装了竖向 `NSStackView` 的普通 `NSView`。
    private static func firstPaneStack(in view: NSView) -> NSStackView? {
        for sub in view.subviews {
            if !(sub is NSControl), let stack = sub.subviews.first as? NSStackView,
               stack.orientation == .vertical {
                return stack
            }
            if let found = firstPaneStack(in: sub) { return found }
        }
        return nil
    }

    /// 整棵子树的 alpha 掰回 1。
    private static func forceVisible(_ view: NSView) {
        view.alphaValue = 1
        view.subviews.forEach { forceVisible($0) }
    }

    // MARK: 文案宽度的数值核对

    /// 渲染之外再量一遍：文字有没有超出可放的位置，数字比目测更难糊弄。
    /// 按「放得下几行」判定，而不是只看余量正负。
    ///
    /// 单行截断的文案，余量为负就是被切；允许折行的（角标说明）则算需要几行，
    /// 超过它实际能折的行数同样是被切 —— 只看"余量"会把两行的情况误判成通过。
    private static func printWidthChecks() {
        guard emitChecks else { return }
        func report(_ label: String, _ text: String, font: NSFont,
                    limit: CGFloat, maxLines: Int) {
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            let lines = max(1, Int((width / limit).rounded(.up)))
            let slack = limit * CGFloat(maxLines) - width
            say(String(format: "  %16@　限 %4.0f×%d 行　实测 %5.1f　需 %d 行　余量 %+6.1f %@",
                         label as NSString, limit, maxLines, width, lines, slack,
                         lines <= maxLines ? "✓" : "✗"))
        }

        let card = toastRenderWidth
        let checks: [(String, String, CGFloat, CGFloat, Int)] = [
            ("角标标题行", "Grabi-20261005-013940.jpg",
             12.5, card - 24 - 54 - 10, 1),
            ("角标说明行", "已保存　·　存到 ~/Pictures/Grabi　·　已复制",
             11, card - 24 - 54 - 10, 2),
            ("角标引导行", "先点菜单栏的 Grabi 图标授权「屏幕录制」，之后按 ⌃⌥A 截图",
             11, card - 24, 2),
            ("角标就绪行", "按 ⌃⌥A 截图　·　图存到 ~/Pictures/Grabi",
             11, card - 24, 2),
            // 提示条量的是 `OverlayView.hintText` 那一份真字，不是这里抄的：
            // 抄的那份会永远量到旧字，改了产品这边宽度检查还一路绿灯。
            ("截图提示条", OverlayView.hintText,
             13, 1200, 1),
            // 拖拽那组现在画在选区角标第三行（10pt）。这里**按 13pt 量**：
            // 拿比实际更大的字号量是刻意收紧，宽度真出问题时它先红。
            ("拖拽修饰键行", OverlayView.dragHintText,
             13, 1200, 1),
            // 复制失败那两句从 `PasteboardWrite` 的真措辞取，不另抄一份
            ("角标标题(复制失败)", PasteboardWrite.textFailureTitle,
             12.5, card - 24 - 54 - 10, 1),
            ("角标详情(复制失败)", PasteboardWrite.textFailureDetail(characters: 1200),
             11, card - 24 - 54 - 10, 2)
        ]
        say("── 文案宽度（按可折行数判定，超出 = 会被截断）")
        for (label, text, size, limit, maxLines) in checks {
            report(label, text, font: NSFont.systemFont(ofSize: size), limit: limit, maxLines: maxLines)
        }

        // 快捷键框那三行以前是手抄的：文案、字号、框宽各抄了一份。于是框加宽到 170
        // 之后表里还写着 150，新的拒收文案也没进表 —— 手抄的表不会自己承认过期。
        // 现在全部从真源头取（`boxText` / `hintTextFont` / `intrinsicContentSize`），
        // 限宽再扣掉左右各 6pt：文字是居中的，顶到边框也算挤。
        let boxFont = HotKeyRecorderView.hintTextFont
        let boxLimit = HotKeyRecorderView().intrinsicContentSize.width - 12
        let cmdC = HotKeySpec.make(HotKeySpec.Key.c, HotKeySpec.Mod.cmd)
        let boxTexts: [(String, String)] = [
            ("快捷键框(录制)", HotKeyRecorderView.boxText(recording: true, spec: .none, rejectHint: nil)),
            ("快捷键框(未设置)", HotKeyRecorderView.boxText(recording: false, spec: .none, rejectHint: nil)),
            ("快捷键框(零修饰键)", HotKeyRecorderView.boxText(recording: true, spec: .none,
                                                           rejectHint: HotKeyRecorderView.noModifierHint)),
            ("快捷键框(单修饰键)", HotKeyRecorderView.boxText(recording: true, spec: .none,
                                                           rejectHint: cmdC.modifierRejection)),
            ("快捷键框(已设)", HotKeyRecorderView.boxText(
                recording: false,
                spec: .make(HotKeySpec.Key.a, HotKeySpec.Mod.ctrl | HotKeySpec.Mod.opt),
                rejectHint: nil))
        ]
        for (label, text) in boxTexts {
            report(label, text, font: boxFont, limit: boxLimit, maxLines: 1)
        }
    }

    // MARK: 渲染

    /// 把视图装进一个从不显示的窗口里 `cacheDisplay` 成 PNG。
    /// 背景刻意铺一张"有明有暗"的图：组件在亮内容和暗内容上都得看得清。
    private static func save(_ view: NSView, to path: String, backdrop: Bool = true) {
        let size = view.frame.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false

        let canvas = BackdropView(frame: NSRect(origin: .zero, size: size))
        canvas.drawsBackdrop = backdrop
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        canvas.addSubview(view)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()

        // 这个出口原先是静默 return，而写失败那句又不带 ✗ —— 少一张图既不进清点
        // 也不进退出码。两个出口一起接上。
        let shotName = (path as NSString).lastPathComponent
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            renderShots.append((passLabel, shotName, false)); return
        }
        withAppearance {
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            renderShots.append((passLabel, shotName, false)); return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            renderShots.append((passLabel, shotName, true))
        } catch {
            renderShots.append((passLabel, shotName, false))
            say("    ✗ 写入失败 \(path)：\(error.localizedDescription)")
        }
    }

    private final class BackdropView: NSView {
        var drawsBackdrop = true

        override func draw(_ dirtyRect: NSRect) {
            guard drawsBackdrop else { return }
            if let image = backdropImage(width: Int(bounds.width), height: Int(bounds.height)) {
                NSImage(cgImage: image, size: .zero).draw(in: bounds)
            }
        }
    }

    /// 一张"像真实屏幕内容"的合成图：左半亮、右半暗，中间几道色块。
    private static func backdropImage(width: Int, height: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                                         pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width / 2, height: height).fill()
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSRect(x: CGFloat(width) / 2, y: 0, width: CGFloat(width) / 2, height: CGFloat(height)).fill()
            NSColor.systemTeal.setFill()
            NSRect(x: 20, y: CGFloat(height) * 0.6, width: CGFloat(width) * 0.18,
                   height: CGFloat(height) * 0.2).fill()
            NSColor.systemOrange.setFill()
            NSRect(x: CGFloat(width) * 0.62, y: CGFloat(height) * 0.2,
                   width: CGFloat(width) * 0.2, height: CGFloat(height) * 0.16).fill()
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
