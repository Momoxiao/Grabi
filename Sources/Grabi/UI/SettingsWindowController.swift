import AppKit

/// 设置窗口。纯 AppKit 手写布局 —— 不为一个设置面板引入 SwiftUI，
/// 省下的是启动时几十 MB 的运行时开销。
///
/// 顶部是一排分段切换（`NSSegmentedControl`），下面是切换出来的内容。
/// 之前用的是 `NSTabView` 的 `.topTabsBezelBorder`：那套标签页是 macOS 10 时代的
/// 观感，边框重、和窗口标题栏之间还隔一道横线，看着像插件面板。
/// 设置窗里"看得见的字"最低用 `secondaryLabelColor`：`tertiaryLabelColor` 在浅色卡片上
/// 实测只有 1.7~1.9:1（`--ui-render` 的逐面对比会红），而这里那些脚注是**信息**
/// —— 占位符清单、保存位置的像素说明、权限为什么要给。
/// tertiary 只留给"此刻不适用"的东西：禁用态的数值、没要求自启时的那个灰点。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let settings = SettingsStore.shared
    /// internal 而不是 private：自检要临时换上自己的计数闭包，
    /// 好证明「按了取消」真的不会去重新注册全局热键。
    var onSettingsChanged: (() -> Void)?

    /// 每个面板的高度**由内容自己算**（见 `pane(_:)`），切过去的时候窗口跟着伸缩。
    private struct Pane {
        let title: String
        /// 顶部分段控件上的图标。放在结构体里而不是另开一个平行数组：
        /// 加面板时漏了图标会直接编译不过，平行数组漏一项是静默错位。
        let symbol: String
        let view: NSView
    }

    private var panes: [Pane] = []
    private var switcher: NSSegmentedControl!
    private var paneScroll: NSScrollView!
    private var contentHost: NSView!

    private var pathLabel: NSTextField!
    private var namePatternField: NSTextField!
    private var nameExampleLabel: NSTextField!
    private var formatPopup: NSPopUpButton!
    private var qualitySlider: NSSlider!
    private var qualityLabel: NSTextField!
    private var saveOCRTextCheck: NSButton!
    private var autoCopyOCRCheck: NSButton!
    private var languageChecks: [String: NSButton] = [:]
    /// 面板上真出现过的语言 code，按显示顺序。`languageChecks` 是字典，顺序不可依赖。
    private var languageCodes: [String] = []
    private var languageStatusLabel: NSTextField?
    private var hotKeyViews: [String: HotKeyRecorderView] = [:]
    private var autoStartCheck: NSButton!
    private var hideIconCheck: NSButton!
    private var soundCheck: NSButton!
    private var cursorCheck: NSButton!
    private var hotKeyStatusLabel: NSTextField?
    private var hotKeyResetButton: NSButton?
    private var runStateLabel: NSTextField!
    private var runStateIcon: NSImageView!
    private var runStateButton: NSButton!
    private var runStateAction: AutoStartManager.RunStateAdvisory.Action = .none
    private var permissionLabel: NSTextField!
    private var permissionIcon: NSImageView!

    init(onSettingsChanged: @escaping () -> Void) {
        self.onSettingsChanged = onSettingsChanged

        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
                                    styleMask: [.titled, .closable, .resizable],
                                    backing: .buffered,
                                    defer: false)
        window.title = "Grabi 设置"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        // 不给最小尺寸的话，用户可以把它缩到只剩标题栏。200 这个下限比四个面板里
        // 最矮的那个还矮 —— 之所以敢这么小，是因为面板现在装在滚动视图里（见 `buildUI`），
        // 缩窗口只会让内容变可滚，不会再像以前那样把最后一节裁到看不见的地方。
        window.minSize = NSSize(width: 520, height: 200)
        // 系统偏好「优先使用标签页」会把同 app 后开的有标题窗口并进前一个窗口的
        // 标签页里。工具型 app 的独立面板一律禁掉自动合并。
        window.tabbingMode = .disallowed

        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("不支持归档加载") }

    func present() {
        // 「恢复默认快捷键」的结果行说的是"刚刚那次操作"；重新打开设置时它已经
        // 不是刚发生了。`refresh()` 会清语言那行，这一行也得在开场时归零。
        hotKeyStatusLabel?.stringValue = ""
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        guard isWindowLoaded else { return }
        pathLabel.stringValue = NSString(string: settings.saveDirectory).abbreviatingWithTildeInPath
        namePatternField.stringValue = settings.fileNamePattern
        formatPopup.selectItem(at: ImageFormat.allCases.firstIndex(of: settings.imageFormat) ?? 0)
        qualitySlider.doubleValue = settings.jpegQuality
        qualityLabel.stringValue = String(format: "%.0f%%", settings.jpegQuality * 100)
        saveOCRTextCheck.state = settings.saveOCRText ? .on : .off
        autoCopyOCRCheck.state = settings.autoCopyOCRText ? .on : .off

        let languages = Set(settings.ocrLanguages)
        for (code, button) in languageChecks {
            button.state = languages.contains(code) ? .on : .off
        }
        // 那行话术说的是"刚刚那次改动"，重新打开窗口时它已经不是刚发生了。
        languageStatusLabel?.stringValue = ""

        hotKeyViews["capture"]?.spec = settings.hotKeyCapture

        // 先归位不变式，再显示：这一条勾选框代表两个偏好，读的是 `launchAtLogin`。
        // 老库里存着「保活开、自启关」（拆着摆那阵子允许）的话，不归位就会显示成"没开"，
        // 而系统里其实登记着登录项 —— 勾和状态行说的两件事。
        settings.normalizeAutoStart()
        autoStartCheck.state = settings.launchAtLogin ? .on : .off
        hideIconCheck.state = settings.hideStatusBarIcon ? .on : .off
        soundCheck.state = settings.playSound ? .on : .off
        cursorCheck.state = settings.showCursor ? .on : .off

        updateQualityEnabled()
        updateNameExample()
        updatePermissionLabel()
        updateRunStateLabel()
    }

    // MARK: - 布局

    private func buildUI() {
        guard let window else { return }

        panes = [
            Pane(title: "保存", symbol: "folder", view: buildSavePane()),
            Pane(title: "文字识别", symbol: "text.viewfinder", view: buildOCRPane()),
            Pane(title: "快捷键", symbol: "command", view: buildHotKeyPane()),
            Pane(title: "运行", symbol: "power", view: buildRuntimePane())
        ]

        switcher = NSSegmentedControl(labels: panes.map(\.title),
                                       trackingMode: .selectOne,
                                       target: self,
                                       action: #selector(paneSwitched))
        switcher.selectedSegment = 0
        switcher.translatesAutoresizingMaskIntoConstraints = false
        switcher.segmentStyle = .automatic
        switcher.controlSize = .regular
        // 每段带上图标。纯文字的偏好切换器是"能用的表单"，图标 + 文字才是
        // macOS 设置窗的样子 —— 眼睛扫图标比读中文标题快，而且四段一眼能记住位置。
        for (index, pane) in panes.enumerated() {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            if let image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)?
                .withSymbolConfiguration(config) {
                image.isTemplate = true
                switcher.setImage(image, forSegment: index)
                switcher.setImageScaling(.scaleProportionallyDown, forSegment: index)
            }
        }
        // 每段带上自己的 ⌘ 键。分段控件不会像 NSTabView 那样把这些键显示出来，
        // 而只在后台接了键、界面上一个字都不提，等于这个功能对不知道它的人不存在。
        for (index, pane) in panes.enumerated() {
            switcher.setToolTip("\(pane.title)（⌘\(index + 1)）", forSegment: index)
        }

        contentHost = NSView()
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.wantsLayer = true

        // 面板装在滚动视图里：**上限只压窗口，不压内容**。
        // 以前窗口被矮屏的 ceiling 压矮、或者用户自己把设置窗缩到 `minSize` 那 200pt 时，
        // 多出来的那一节是裁在窗口外的 —— 看不见也滚不到。建窗口时那句
        // 「不给最小尺寸就会被缩到只剩标题栏」的注释说明这个风险早知道，
        // 只是选了个还不够用的下限：200 比四个面板里最矮的那个还矮一截。
        paneScroll = NSScrollView()
        paneScroll.translatesAutoresizingMaskIntoConstraints = false
        paneScroll.documentView = contentHost
        paneScroll.hasVerticalScroller = true
        paneScroll.autohidesScrollers = true
        paneScroll.drawsBackground = false
        paneScroll.automaticallyAdjustsContentInsets = false
        do {
            let clip = paneScroll.contentView
            clip.drawsBackground = false
            // 文档宽度跟着可见宽度走；高度由内容自己撑（见 `showPane` 里那条底边约束）。
            contentHost.widthAnchor.constraint(equalTo: clip.widthAnchor).isActive = true
        }

        let container = NSView()
        container.addSubview(switcher)
        container.addSubview(paneScroll)
        NSLayoutConstraint.activate([
            switcher.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            switcher.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            paneScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            paneScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            paneScroll.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 16),
            paneScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])

        window.contentView = container
        // 最小宽度**从四个面板自己的 fitting 宽算出来**，不手写常数。
        // 手写的那版是 520，而面板是按 588 的内容宽排的 —— 等于允许用户把窗口拖到
        // 比布局需要的还窄，而那一档从来没量过（越界体检只在默认宽度上跑）。
        // 和高度那条一样：写死的常数会漂，从内容读就不会。
        //
        // 四个面板各真挂进窗口量一次（`showPane` 里那条），量完切回 0 号：
        // 只量当前面板的话，用户第一次切到「快捷键」才把窗口下限撑开，
        // 而在那之前他已经能把窗口拖到比它需要的窄。
        minContentWidth = measureMinimumWidth()
        window.minSize = NSSize(width: minContentWidth, height: window.minSize.height)
        showPane(at: 0, animate: false)
        // 位置：第一次按排版完的真实高度居中（建窗口时按 470 高居中，真正排出来只有
        // 290 左右，不在长高/缩完之后重新定位一次，第一次打开就是「偏上挂着」的，很
        // 廉价）；之后回到用户上次放的地方 —— 每次开设置都弹回正中，用过一次就烦了。
        if !WindowFrameMemory.restore(window, name: "settings") {
            window.center()
        }
        refresh()
    }

    /// 切换面板。内容区淡入，窗口高度跟着内容走。
    @objc private func paneSwitched() {
        showPane(at: switcher.selectedSegment)
    }

    /// ⌘1…⌘4 切面板。macOS 设置窗的惯例 —— 用 `NSTabView` 的偏好窗口自带这套键，
    /// 而这里为了观感换成分段控件之后就得自己接上。不接的代价是：想换个面板必须
    /// 把手从键盘上抬起来去点顶上那一排，而设置窗里最常做的动作就是在面板间来回跳。
    ///
    /// 纯函数，自检直接给参数就能判：`isRecordingHotKey` 那一条是真会撞的 ——
    /// 用户点进录制框就是为了录一个新组合键，⌘1 完全合法，抢了它就是把「录制」
    /// 变成「切面板」，那比没有这套键更糟。
    static func paneIndex(characters: String?, modifiers: NSEvent.ModifierFlags,
                          isRecordingHotKey: Bool, paneCount: Int) -> Int? {
        guard !isRecordingHotKey else { return nil }
        // 只认裸 ⌘：⌥⌘1、⌃⌘1 留给系统和其它用途，别在这里越权。
        guard modifiers.intersection([.command, .option, .control, .shift]) == .command else { return nil }
        guard let text = characters, text.count == 1,
              let digit = text.first?.wholeNumberValue, (1...9).contains(digit) else { return nil }
        let index = digit - 1
        return index < paneCount ? index : nil
    }

    /// 这个窗口的按键入口（由 `SettingsWindow.sendEvent` 在分发给响应链之前调用）。
    /// 返回 true 表示键已被吃掉，不用再往下走。
    @discardableResult
    func handleKeyDown(characters: String?, modifiers: NSEvent.ModifierFlags,
                       isRecordingHotKey: Bool) -> Bool {
        guard let index = Self.paneIndex(characters: characters, modifiers: modifiers,
                                         isRecordingHotKey: isRecordingHotKey,
                                         paneCount: panes.count),
              index != switcher.selectedSegment else { return false }
        switcher.selectedSegment = index
        showPane(at: index)
        return true
    }

    /// 自检用：当前选中的面板。
    var selectedPaneIndexForSelfTest: Int { switcher.selectedSegment }

    /// 自检用：某一段的悬停提示（用来核对 ⌘ 键有没有写在界面上，而不只是代码里）。
    func paneTooltipForSelfTest(_ index: Int) -> String? {
        switcher.toolTip(forSegment: index)
    }

    /// 自检用：顶部分段控件里**真的带图标**的段数。
    /// 数的是控件当前状态而不是 `panes` 里那个字符串 —— 常量还在、图标没贴上
    /// 去（拼错符号名会静默返回 nil）才是这里真正要防的错。
    var segmentsWithIconForSelfTest: Int {
        (0..<panes.count).count { switcher.image(forSegment: $0) != nil }
    }

    /// 自检用：第 index 个面板**自己**的那棵视图树（不是窗口）。
    /// 收进清单时必须用它 —— 用 `window.contentView` 的话四个条目是同一个对象，
    /// 事后遍历时数到的全是最后挂载的那一个面板，既翻倍又漏面。
    func paneViewForSelfTest(_ index: Int) -> NSView? {
        panes.indices.contains(index) ? panes[index].view : nil
    }

    /// 自检用：四个面板拼起来的全部文字（按视图树里的顺序，逐段补换行）。
    ///
    /// 判"说明文案有没有真贴到窗上"要用这个，而不是逐个标签比。图例那种排版会把
    /// 一段说明拆成一行一个标签，逐标签比就变成"谁敢改排版谁先红"；而它本来要防的是
    /// "自检在查一份没人看的副本"（常量还在、面板改回内联硬编码）—— 拼起来比同样防得住。
    func paneJoinedTextForSelfTest() -> String {
        panes.map { pane in
            var out: [String] = []
            Self.collectStrings(in: pane.view, into: &out)
            return out.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// 自检用：四个面板里所有文字。
    ///
    /// 存在的理由：说明文案一旦抽成常量，自检就可以只读常量而永远不看窗口 ——
    /// 面板改回内联硬编码也照样全绿。这一句把常量对着**真贴上去的**文字比一遍。
    func paneStringsForSelfTest() -> [String] {
        var out: [String] = []
        for pane in panes { Self.collectStrings(in: pane.view, into: &out) }
        return out
    }

    static func collectStrings(in view: NSView, into out: inout [String]) {
        if let field = view as? NSTextField { out.append(field.stringValue) }
        if let button = view as? NSButton { out.append(button.title) }
        for sub in view.subviews { Self.collectStrings(in: sub, into: &out) }
    }

    /// 自检用：造一个真的 ⌘N 按键事件丢给**窗口**，看它有没有走到第 N 个面板。
    /// 直接调 `handleKeyDown` 证明不了接线 —— 决策函数可以写得很对，但没人调用它，
    /// 用户按下去照样什么也不发生。
    func selectPaneViaKeyEventForSelfTest(digit: Int) -> Bool {
        guard let window, panes.count > 1 else { return false }
        // 先把自己挪到**不是**目标的那一段：不然「已经停在第 1 个面板上按 ⌘1」
        // 也算命中，而那条断言在任何版本里都不会红 —— 键完全没接上时它照样给个 ✓。
        switcher.selectedSegment = (digit - 1 + 1) % panes.count
        let text = String(digit)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                               modifierFlags: .command, timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: text, charactersIgnoringModifiers: text,
                                               isARepeat: false, keyCode: UInt16(17 + digit)) else { return false }
        window.sendEvent(event)
        return switcher.selectedSegment == digit - 1
    }

    /// 切到第 index 个面板。
    ///
    /// internal 是给离屏渲染自检用的：设置面板是纯代码拼的，间距、截断、
    /// 新加的示例名标签这些都得看一眼才算验过。
    func showPane(at index: Int, animate: Bool = true) {
        guard panes.indices.contains(index), let window else { return }

        let content = attachPane(index)
        content.alphaValue = 0

        // 高度不写死：先把这棵树真的排一遍，读它排出来的高，再让窗口长成这个高。
        // 之前是四个手调常量（250/330/360/430），改一次排版就得回来对表；
        // 而且系统字体调大一号就会把最后一行裁到窗口外 —— 现在内容多高窗口就多高。
        let needed = content.frame.height
        lastPaneHeight = needed

        // 窗口除了内容还得装分段控件和上下留白。这笔账从当前布局里读
        // （整棵树的高 减 **滚动视图可见区的高**），不写死常数：写死过一次，少了 56pt，
        // 四个面板的最后一行全卡在窗口外。
        // 注意减的是 `paneScroll` 而不是 `contentHost`：后者现在是文档高 = 内容高，
        // 拿它算 chrome 会得出 0，等于把内容高重复计了一遍。
        window.contentView?.layoutSubtreeIfNeeded()
        let chrome = (window.contentView?.bounds.height ?? 0) - paneScroll.bounds.height
        let desired = needed + max(chrome, 0)
        let plan = Self.windowHeight(desired: desired,
                                     screenVisibleHeight: window.screen?.visibleFrame.height ?? 900)
        lastPaneOverflow = plan.overflow

        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.duration(0.18)
                content.animator().alphaValue = 1
            }
        } else {
            content.alphaValue = 1
        }

        window.setFrame(Self.frame(forContentHeight: plan.height, of: window),
                        display: true, animate: animate && !Motion.isReduced)
        // 换面板回到顶部：从最长的「快捷键」切回短的「保存」时，若停在原来的滚动位置，
        // 窗口会开在一片空白上。
        //
        // `contentHost` 是普通 NSView（非 flipped），所以文档坐标的 `.zero` 是**底边**
        // 不是顶边 —— 直接 `scroll(to: .zero)` 会让切换后停在内容底部。这里按文档高
        // 和可见高算出顶边；文档比可见区矮时 top = 0（没有可滚的）。
        window.contentView?.layoutSubtreeIfNeeded()
        let clip = paneScroll.contentView
        // 用目标高度算可见区，而不是读 clip 的当前高度：换页动画还没跑完时
        // 后者还是上一页的尺寸，会把顶部算歪。
        let visibleHeight = max(1, plan.height - max(chrome, 0))
        let top = contentHost.isFlipped ? 0 : max(0, needed - visibleHeight)
        clip.scroll(to: NSPoint(x: 0, y: top))
        paneScroll.reflectScrolledClipView(clip)
    }

    /// 把第 index 个面板挂上文档视图、排一遍，返回那块视图。
    ///
    /// 抽出来是因为两处需要**同一棵排好的树**：切面板要它的高，建窗口量最小宽要它的
    /// fitting 宽。两处各写一遍挂载，量到的就不是排出来的那个东西了。
    @discardableResult
    private func attachPane(_ index: Int) -> NSView {
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let content = panes[index].view
        content.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentHost.topAnchor),
            // 底边一起钉：文档高 = 内容高。不钉的话文档只有窗口那么高，
            // 多出来的那一节会被滚动视图当成"没有内容"直接丢掉。
            content.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        return content
    }

    /// 四个面板挨个挂上窗口，量出 `minimumWidth(...)` 要的两组数。
    ///
    /// 必须挂上窗口量（不是建窗口时量游离的面板）：游离状态没有"可见宽"这条约束，
    /// 排出来的树和用户在窗口里看到的不是同一棵。摊到 1200 是为了让说明标签
    /// 都按自己那行排完，读到的是控件固有宽，而不是被当时的窗口宽压出来的数。
    private func measureMinimumWidth() -> CGFloat {
        guard let window else { return 0 }
        let keep = window.frame
        defer { window.setFrame(keep, display: false) }
        window.setContentSize(NSSize(width: 1_200,
                                     height: max(window.contentLayoutRect.height, 200)))
        var fitting: [CGFloat] = []
        var wrap: [CGFloat] = []
        for index in panes.indices {
            fitting.append(attachPane(index).fittingSize.width)
            wrap.append(widestTextWrap(in: panes[index].view))
        }
        return Self.minimumWidth(paneFittingWidths: fitting, designTextWidths: wrap,
                                 cardInsets: cardHorizontalInsets)
    }

    /// 窗口最小宽度：从**两样东西**算，取大的那个。
    ///
    /// 1. 控件这棵树真占的宽（摊到 1200 量：那时候谁都不折行，读到的是固有宽）；
    /// 2. 说明文字自己定的折行上限 `preferredMaxLayoutWidth`。
    ///
    /// 为什么第 2 条不能省，也不能用 1 的不动点代替：窗口一旦比那个上限窄，这些
    /// 标签就要改行，而"改行之后要多少"这个映射在临界的 1pt 上是**不连续**的 ——
    /// 实测给定 523 时布局要 523，给定 524 时要 542（那 1pt 让一条说明从"折两行"
    /// 翻成"再挤一行"）。迭代这个映射收在哪一格取决于起点，而自检复查的是
    /// 「拖到最窄会不会切」—— 把窗口下限建在一个会抖 19pt 的数上就是上一版红的那条。
    /// 直接把下限压到"谁都不必额外折行"那一格，抖不抖就与结果无关了。
    static func minimumWidth(paneFittingWidths: [CGFloat], designTextWidths: [CGFloat],
                             cardInsets: CGFloat, contentInsets: CGFloat = 32) -> CGFloat {
        let widestControl = (paneFittingWidths.max() ?? 0) - cardInsets
        let widestText = designTextWidths.max() ?? 0
        return max(360, max(widestControl, widestText) + cardInsets + contentInsets)
    }

    /// 卡片左右内边距从**真卡片**读，不抄 `section()` 里那对 edgeInsets：
    /// 抄的那份会漂，而它一漂窗口下限就跟着算错。读不到时退回 24（就是现在那份）。
    private var cardHorizontalInsets: CGFloat {
        guard let first = panes.first,
              let card = firstCardView(in: first.view),
              let stack = card.subviews.first as? NSStackView else { return 24 }
        return stack.edgeInsets.left + stack.edgeInsets.right
    }

    private func firstCardView(in root: NSView) -> NSView? {
        for sub in root.subviews {
            if sub is SettingsCardView { return sub }
            if let hit = firstCardView(in: sub) { return hit }
        }
        return nil
    }

    /// 一棵子树里最大的 `preferredMaxLayoutWidth`（说明文字自己规定的折行上限）。
    private func widestTextWrap(in root: NSView) -> CGFloat {
        var best = (root as? NSTextField)?.preferredMaxLayoutWidth ?? 0
        for sub in root.subviews { best = max(best, widestTextWrap(in: sub)) }
        return best
    }

    /// 由面板内容算出来的最小窗口宽（自检拿它对账"窗口还能不能比布局需要的更窄"）。
    private(set) var minContentWidth: CGFloat = 0

    /// 窗口该长多高，以及**有多少内容放不下**。
    ///
    /// 上限说的是"窗口不能高过可见区"，它不该顺带把内容裁掉 —— 所以溢出量原样报出去，
    /// 让自检能判"溢出有没有被滚动视图接住"。以前这个决定是 `showPane` 里一行
    /// `min(max(desired, 240), ceiling)`，溢出多少、有没有人接，全都没地方问。
    static func windowHeight(desired: CGFloat, screenVisibleHeight: CGFloat,
                             lowerBound: CGFloat = 240) -> (height: CGFloat, overflow: CGFloat) {
        let ceiling = max(screenVisibleHeight - 160, 320)
        let height = min(max(desired, lowerBound), ceiling)
        return (height, max(0, desired - height))
    }

    /// 最近一次排版算出的「窗口装不下的那一截」。
    private(set) var lastPaneOverflow: CGFloat = 0

    /// 自检用：面板是不是真的住在滚动视图里（溢出的内容只有被它接住才算看得见）。
    var paneScrollForSelfTest: NSScrollView? { paneScroll }

    /// 自检用：当前面板的文档高 / 可见高。
    var paneHeightsForSelfTest: (document: CGFloat, visible: CGFloat) {
        (contentHost.bounds.height, paneScroll.contentView.bounds.height)
    }

    /// 自检用：面板容器**真的**挂在滚动视图里吗。
    ///
    /// 这条要单独判，因为在这台 1600 高的屏上任何面板都"放得下"，
    /// 于是"溢出有没有人接"这件事在渲染自检里永远是绿的 ——
    /// 把滚动视图拆掉也不会有半行红。它得按结构判，不按当次的高度差判。
    var paneIsScrollableForSelfTest: Bool {
        paneScroll.documentView === contentHost && paneScroll.hasVerticalScroller
    }

    /// 最近一次排版量出的面板高度。离屏渲染自检用它对账「窗口有没有长够」。
    private(set) var lastPaneHeight: CGFloat = 0

    /// 离屏渲染自检用：把模板填成某个值并走一遍**用户改模板时同一条路径**
    /// （**不写进偏好**：这里只改输入框，不落到 settings）。
    func setPatternForSelfTest(_ text: String) {
        namePatternField?.stringValue = text
        updateNameExample()
        showPane(at: switcher.selectedSegment, animate: false)
    }

    /// 自检用：走用户提交文件名格式的**同一条路径**，返回真正写进偏好的值。
    /// 先垫一个非空哨兵，避免"本来就存的是空串"让清空测试变成恒真；结束后
    /// 字段和偏好都还原，自检不该改用户的设置。
    func persistedNamePatternForSelfTest(_ text: String) -> String {
        let oldPattern = settings.fileNamePattern
        let oldText = namePatternField.stringValue
        settings.fileNamePattern = "Grabi-selftest-before"
        namePatternField.stringValue = text
        namePatternChanged()
        let persisted = settings.fileNamePattern
        settings.fileNamePattern = oldPattern
        namePatternField.stringValue = oldText
        updateNameExample()
        showPane(at: switcher.selectedSegment, animate: false)
        return persisted
    }

    /// 离屏渲染自检用：示例标签**按当前宽度**需要多高、实际给了多高。
    ///
    /// 第一版量的是宽度，结果是个永远通过的假检查：这行允许折行，
    /// `fittingSize` 于是把"给了多宽"原样还回来，永远 `余量 +0`。
    /// 折行的文案要被截断只可能是**竖向**不够，所以量高度。
    var nameExampleFitForSelfTest: (needed: CGFloat, given: CGFloat, lines: Int, width: CGFloat)? {
        guard let label = nameExampleLabel else { return nil }
        label.superview?.layoutSubtreeIfNeeded()
        let width = max(label.frame.width, 1)
        let rect = (label.stringValue as NSString).boundingRect(
            with: NSSize(width: width, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: label.font ?? NSFont.systemFont(ofSize: 11)])
        let lineHeight = (label.font ?? NSFont.systemFont(ofSize: 11)).boundingRectForFont.height
        return (ceil(rect.height), label.frame.height,
                max(1, Int((rect.height / lineHeight).rounded())), width)
    }

    /// 按内容高度算出窗口 frame。**保持顶边不动**——不然切页时窗口会往下长，
    /// 看起来像"跳了一下"。
    private static func frame(forContentHeight contentHeight: CGFloat, of window: NSWindow) -> NSRect {
        var frame = window.frame
        let titleBar = frame.height - window.contentLayoutRect.height
        let newHeight = contentHeight + titleBar
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        return frame
    }

    /// 一屏内容的容器：垂直排列，左对齐，高度完全由内容决定。
    ///
    /// 分节的高度是算出来的（标题 + 内容栈各自的 intrinsic 高），所以窗口必须
    /// 跟着这个高长 —— 写死四个常量的结果是排版一改就对不上，字体调大一号
    /// 最后一行直接被裁到窗口外。
    private func pane(_ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            // 底边一起钉：容器高度 = 内容高度，窗口再跟着这个高度走。
            // 这样系统字体调大、文案变长都不会把内容裁到窗口外面。
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        // 每一节拉满内容宽。不拉的话每节的卡片按自己的文字收着，四张卡片
        // 右边缘参差不齐 —— 分组框一旦不等宽，"分组"这个信号就没了。
        // 只钉宽度、不动 `alignment`：节内的横向行仍然按内容收，不会被撑稀。
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return container
    }

    /// 带小标题的分组：标题在卡片外，内容在圆角卡片里。
    ///
    /// 刻意**不用 `NSBox`**：把自定义 view 塞进 `NSBox.contentView` 之后，
    /// box 的高度能不能跟着内容算出来取决于系统版本，塌成一条是常有的事。
    /// 自己拼「标题 + 卡片 + 缩进的内容栈」是确定能算对高度的写法。
    ///
    /// `fillRows`：让横向行拉满卡片内宽。快捷键那两行需要它 —— 左边标签定宽、
    /// 右边录制框跟着卡片走，才有"这是一整条设置项"的对齐感。
    /// 只认 `NSStackView`：按钮和说明标签拉满会变成一条通栏的灰按钮 / 一行到头的字。
    private func section(_ title: String, rows: [NSView], fillRows: Bool = false) -> NSView {
        let header = label(title, size: 12, weight: .semibold, color: .labelColor)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)

        let card = SettingsCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        if fillRows {
            // 24 = 左右内边距各 12；按这个数拉满正好贴着卡片的内容区
            for row in stack.arrangedSubviews where row is NSStackView {
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        container.addSubview(card)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),

            card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    // MARK: 保存

    private func buildSavePane() -> NSView {
        pathLabel = label("—", size: 12, color: .secondaryLabelColor)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pathRow = NSStackView(views: [pathLabel,
                                          button("选择…", action: #selector(chooseDirectory)),
                                          button("打开", action: #selector(openDirectory))])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8

        namePatternField = NSTextField(string: settings.fileNamePattern)
        namePatternField.placeholderString = "Grabi-{date}-{time}"
        namePatternField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        // 回车 / 失焦即提交。原来要等关掉窗口才落盘，中间点「打开」去目录里看，
        // 新名字还没生效，看起来就像"没保存上"。
        namePatternField.target = self
        namePatternField.action = #selector(namePatternChanged)

        nameExampleLabel = statusLabel("文件名示例：按当前模板算出来的样子",
                                       color: .secondaryLabelColor)

        // 示例**单独一行**。和 250pt 的输入框挤在一行里时，它要么把整行往上顶宽
        // （实测整个设置窗被撑到 894pt —— 折行交给 `label()` 工厂的统一设置，
        // 但同一行里没人给它一个可以折进去的宽度），要么被压到只剩几十 pt、
        // 最坏情况折 7 行放不下。两条路都是离屏自检量出来的：
        // `✗ 窗口宽 894` 和 `✗ 竖向被切`。
        let nameRow = NSStackView(views: [label("文件名格式"), namePatternField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8

        formatPopup = NSPopUpButton()
        for format in ImageFormat.allCases { formatPopup.addItem(withTitle: format.displayName) }
        formatPopup.selectItem(at: ImageFormat.allCases.firstIndex(of: settings.imageFormat) ?? 0)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        formatPopup.widthAnchor.constraint(equalToConstant: 190).isActive = true

        qualitySlider = NSSlider(value: settings.jpegQuality, minValue: 0.3, maxValue: 1.0,
                                 target: self, action: #selector(qualityChanged))
        qualitySlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        qualityLabel = label("90%", size: 11, color: .secondaryLabelColor)

        let formatRow = NSStackView(views: [label("图片格式"), formatPopup,
                                            label("质量", size: 11), qualitySlider, qualityLabel])
        formatRow.orientation = .horizontal
        formatRow.spacing = 8

        saveOCRTextCheck = checkbox("保存截图时同时保存识别文本",
                                    on: settings.saveOCRText, action: #selector(saveOCRTextToggled))

        // 三节压成两节，一节里的"条"按用户做几个决定算，不按源码传了几项算：
        // 落盘时机那两行是一条说明（组内 3pt），文件名 + 示例 + 占位符是同一件事的
        // 三段，格式 + 那句"按原生像素保存"也是一件事。
        // 原来 9 行读起来像 9 条设置项，而这里其实只有 5 个可动的东西。
        return pane([
            section("保存位置", rows: [
                pathRow,
                legend(Self.saveTimingLines.joined(separator: "\n"))
            ]),
            section("文件", rows: [
                grouped(nameRow, nameExampleLabel,
                        label("可用占位符：" + SettingsStore.knownPlaceholders.joined(separator: "　"),
                              size: 11, color: .secondaryLabelColor)),
                grouped(formatRow,
                        legend("图片按显示器原生像素保存（Retina 屏为 2×），不会降采样。")),
                saveOCRTextCheck
            ])
        ])
    }

    /// 「到底什么时候才会写出文件」那两行。放在「保存位置」那一节，因为这一节其余
    /// 控件回答的是"存成什么样"，而这一条回答的是"有没有这个东西"—— 用户找不着
    /// 文件时最先翻的就是这一栏。
    ///
    /// 抽成常量而不是内联字面量：`--logic-selftest` 要拿它跟真实规则
    /// （`ShotCoordinator.savesImmediately`）对账，话和事分家就是骗人。
    static let saveTimingLines = [
        "截图默认不落盘、不进剪贴板。",
        "「复制图片」后预览保持打开；「保存」写出文件并关闭预览。"
    ]

    // MARK: 文字识别

    /// 识别语言面板的两段说明。抽成常量是给自检一份"用户实际看到的那份"可以读的东西：
    /// 面板里的话必须和代码真保证的事对得上，所以它不能是内联字面量。
    static let languageSectionTitle = "识别语言（可多选）"
    static let languageHelpText = "中英文混排建议同时勾选中文和英文。"

    /// 一次改动之后那行话术。
    ///
    /// 只说机制不说进度：`warmUp` 是异步的，写"正在准备…"就迟早会变成一句谎话
    /// （准备早就完了，字还挂在那儿）。而"这期间第一次识别可能慢一些"任何时候都成立。
    static func languageStatus(fallbackName: String?, available: Bool) -> String {
        if !available { return "没有可用的识别语言。"; }
        if let fallbackName { return "至少保留一种语言，已留下「\(fallbackName)」。"; }
        return "改动会在后台准备语言模型，第一次识别可能稍慢。";
    }

    /// 一次勾选的全部后果：界面上该勾哪些、写进偏好的是哪些、要不要兜底。
    ///
    /// 「一个都不留」必须兜底，否则偏好变成空列表，Vision 退回自动检测，中文会被认错。
    /// 兜底挑的是**面板上真有的第一个**，不是硬编码的 `en-US`：硬编码那版在系统没有
    /// 英文可勾时，框子一个都没点亮、偏好里却悄悄存着 en-US —— 用户看到的和存的
    /// 从此分家。这里让 `stored` 恒等于 `displayed ∩ checked`，两边就不可能分家。
    struct LanguageToggle: Equatable {
        let checked: [String]
        let stored: [String]
        let fallbackName: String?
        let available: Bool
    }

    static func languageToggle(displayed: [String], selected: Set<String>,
                               code: String, on: Bool) -> LanguageToggle {
        func kept(_ set: Set<String>) -> [String] { displayed.filter { set.contains($0) } }
        guard !displayed.isEmpty else {
            return LanguageToggle(checked: [], stored: [], fallbackName: nil, available: false)
        }
        guard displayed.contains(code) else {
            // 点了面板上不存在的语言：一个字节都不该动。
            return LanguageToggle(checked: kept(selected), stored: kept(selected),
                                  fallbackName: nil, available: true)
        }
        var next = selected
        if on { next.insert(code) } else { next.remove(code) }
        var fallbackName: String?
        if next.isEmpty {
            let first = displayed[0]
            next.insert(first)
            fallbackName = OCRLanguage.common.first { $0.code == first }?.name ?? first
        }
        let list = kept(next)
        return LanguageToggle(checked: list, stored: list, fallbackName: fallbackName, available: true)
    }

    private func buildOCRPane() -> NSView {
        autoCopyOCRCheck = checkbox("识别后自动复制全文",
                                    on: settings.autoCopyOCRText, action: #selector(autoCopyOCRToggled))

        var languageRows: [NSView] = []
        var current: [NSView] = []
        for language in OCRLanguage.common where OCRRecognizer.supportedLanguages.contains(language.code) {
            let check = checkbox(language.name,
                                 on: settings.ocrLanguages.contains(language.code),
                                 action: #selector(languageToggled(_:)))
            check.identifier = NSUserInterfaceItemIdentifier(language.code)
            check.widthAnchor.constraint(equalToConstant: 150).isActive = true
            languageChecks[language.code] = check
            languageCodes.append(language.code)
            current.append(check)
            if current.count == 3 {
                let row = NSStackView(views: current)
                row.orientation = .horizontal
                row.spacing = 4
                languageRows.append(row)
                current = []
            }
        }
        if !current.isEmpty {
            let row = NSStackView(views: current)
            row.orientation = .horizontal
            row.spacing = 4
            languageRows.append(row)
        }
        languageStatusLabel = statusLabel("识别语言改动后的说明")

        // 8 行压成 6 行，两处折叠都是"说的是同一件事"：
        // 「怎么开始识别」那句说明和它下面那条勾选框同属一个决定，钉成一组；
        // 语言网格底下那行建议，和它下面那行动态回读，读的是同一栏。
        return pane([
            section("识别后", rows: [
                grouped(legend("截图预览中点「识别文字」，再划选复制。"),
                        autoCopyOCRCheck)
            ]),
            section(Self.languageSectionTitle, rows: languageRows + [
                grouped(legend(Self.languageHelpText), languageStatusLabel!)
            ])
        ])
    }

    // MARK: 快捷键

    /// 快捷键面板那段说明。抽成常量是为了让自检能拿它和 `displayString` 对一遍
    /// 修饰键顺序：界面框里显示 ⇧⌘4、说明文字里写 ⌘⇧4，这种不一致没人会去对，
    /// 而用户只会以为是两条不同的快捷键。
    static let hotKeyHelpText = """
    点右侧框录制组合键；Delete 清空。
    至少两个修饰键：单个 ⌘ / ⌃ / ⌥ 会抢走所有 app 的 ⌘C、⌃A。
    ⇧⌘3 / ⇧⌘4 / ⇧⌘5 / ⇧⌘6 是 macOS 自带截图在用的，录到它会先问一句再决定。
    """

    // MARK: 恢复默认快捷键

    /// 一条组合键的"要变什么"：名字 + 旧写法 + 新写法，全部用 `displayString` 的
    /// 同款拼法（界面上出现的就是那一种顺序）。
    struct HotKeyChange: Equatable { let name: String; let from: String; let to: String }

    enum HotKeyReset: Equatable {
        case nothingToRestore
        case restore([HotKeyChange])
    }

    enum HotKeyResetOutcome: Equatable {
        case nothingToRestore
        case cancelled
        case restored([HotKeyChange])
    }

    /// 决策：纯函数，把「本来就是默认」和「要改哪几条」分开。
    ///
    /// 分开是有原因的：原先这个按钮无条件 `settings.resetHotKeys()`，用户在默认状态
    /// 按一下也"成功"，而实际什么都没发生 —— 和这仓库早就立过的规矩（提示只说真做过
    /// 的事）正好相反。更要紧的是它会悄悄丢掉用户自己选的俩全局热键，一句都不问。
    static func resetDecision(capture: HotKeySpec) -> HotKeyReset {
        var changes: [HotKeyChange] = []
        if capture != .defaultCapture {
            changes.append(.init(name: "截图", from: capture.displayString,
                                 to: HotKeySpec.defaultCapture.displayString))
        }
        return changes.isEmpty ? .nothingToRestore : .restore(changes)
    }

    static func resetDetail(_ changes: [HotKeyChange]) -> String {
        changes.map { "· \($0.name)：\($0.from) → \($0.to)" }.joined(separator: "\n")
    }

    static let resetTitle = "恢复默认快捷键？"
    static let resetCancelTitle = "取消"
    static let resetRestoreTitle = "恢复默认"

    static func resetPrompt(_ changes: [HotKeyChange])
        -> (title: String, detail: String, cancelTitle: String, restoreTitle: String) {
        (resetTitle,
         resetDetail(changes) + """
         
         这是全局快捷键，改完之后 Grabi 会在任何 app 里接管它。
         按「取消」不会改动任何设置。
         """,
         resetCancelTitle, resetRestoreTitle)
    }

    static func resetAlert(_ changes: [HotKeyChange]) -> NSAlert {
        let plan = resetPrompt(changes)
        let alert = NSAlert()
        alert.messageText = plan.title
        alert.informativeText = plan.detail
        // 默认按钮必须是「取消」：这是丢弃用户选择的操作，回车误碰一次就不该生效
        // （和撞系统截图那台询问同一套规矩）。
        alert.addButton(withTitle: plan.cancelTitle)
        alert.addButton(withTitle: plan.restoreTitle)
        return alert
    }

    /// 问句 + 副作用都注入：控制器走真弹窗真写盘，自检走假答复假写入。
    /// 两边共用同一个函数，所以"决策对了但没人调用"这种错在这儿同样会红。
    static func runReset(capture: HotKeySpec,
                         write: () -> Void,
                         confirm: ([HotKeyChange]) -> Bool) -> HotKeyResetOutcome {
        guard case let .restore(changes) = resetDecision(capture: capture) else {
            return .nothingToRestore
        }
        guard confirm(changes) else { return .cancelled }
        write()
        return .restored(changes)
    }

    static func resetStatus(_ outcome: HotKeyResetOutcome) -> String {
        switch outcome {
        case .nothingToRestore:
            return "本来就是默认组合（\(HotKeySpec.defaultCapture.displayString)），没改任何东西"
        case .cancelled:
            return "按了「取消」　·　快捷键保持原样"
        case .restored(let changes):
            return "已恢复：" + changes.map { "\($0.name) \($0.to)" }.joined(separator: "　·　")
        }
    }

    /// 「截图时的操作」那一栏的说明。
    ///
    /// 抽成常量是因为它整栏都在讲快捷键，而自检原先只查 `hotKeyHelpText` 一个常量 ——
    /// 同一种毛病（⌘ 写在 ⇧ 前面就是另一条键）在隔壁几行里照样成立，守卫却照不到。
    ///
    /// **一行一条，一行一个键**：这一栏现在按行渲染成图例（键名加粗），
    /// 一行里塞两个键时第二个就漏了加粗；而长行折行会把「复制文字」这种词劈成两半。
    static let captureHelpTexts: [String] = [
        """
        · 移动鼠标：候选框跟随，落在窗口上选窗口，落在桌面/空隙选整屏
        · 单击：截取当前候选
        · 按住拖动：自由框选区域（⇧ 锁正方形，⌥ 从中心向外扩）
        · 空格：强制切到整屏候选
        · Esc：取消
        """,
        """
        截完之后：
        · 回车：保存并关闭预览
        · ⌘C：普通预览复制图片；OCR 模式复制选中文字
        · 滚轮：调整预览大小（不改截图内容）
        · Esc / ⌘W：关闭预览，不保存
        · 按住图片：挪位置
        · 拖边缘：重选截图范围
        · 点图片外：关闭预览，不保存
        """,
        """
        这一排面板：⌘1 – ⌘4 直接切换　·　Esc 关闭设置
        """
    ]

    private func buildHotKeyPane() -> NSView {
        let definitions: [(String, String, HotKeySpec)] = [
            ("capture", "截图（窗口 / 区域 / 全屏）", settings.hotKeyCapture)
        ]

        var rows: [NSView] = []
        for (key, title, spec) in definitions {
            let recorder = HotKeyRecorderView()
            recorder.spec = spec
            recorder.identifier = NSUserInterfaceItemIdentifier(key)
            // 走闭包而不是字符串 selector 的 perform：那条通道断了没有任何症状，
            // 框里显示新组合、偏好里还是旧的。闭包接不上就编译不过。
            recorder.onChange = { [weak self] _ in self?.commitHotKey(key) }
            hotKeyViews[key] = recorder

            // 录制框保持自己那 170pt，靠右贴齐 —— 系统偏好里「标题 …… 控件」
            // 就是这么排的。把框本身拉宽反而不像设置项：一个能录三个组合键的
            // 空框看着像输入框坏了。
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [label(title, width: 220), spacer, recorder])
            row.orientation = .horizontal
            row.spacing = 10
            rows.append(row)
        }

        let status = statusLabel("恢复默认快捷键的结果提示")
        hotKeyStatusLabel = status
        let resetButton = button("恢复默认快捷键", action: #selector(resetHotKeys))
        hotKeyResetButton = resetButton

        return pane([
            section("快捷键", rows: rows + [
                legend(Self.hotKeyHelpText, base: .secondaryLabelColor),
                grouped(resetButton, status)
            ], fillRows: true),
            // 三条说明压成两组：第一条说的是"截的时候手上做什么"，后两条说的是
            // "截完之后"和"面板上的键"。
            //
            // 这里原本写的是 `prefix(2)` + `suffix(2)` —— 一共三条时两边都含中间那条，
            // 「截完之后」那一栏在窗上印了两遍，而所有断言照样绿（比的是"在不在"，
            // 不是"出现几次"）。改成不会重叠的一刀，并且自检现在数次数。
            section("截图时的操作", rows: [
                legend(Self.captureHelpTexts.prefix(1).joined(separator: "\n")),
                legend(Self.captureHelpTexts.dropFirst().joined(separator: "\n"))
            ])
        ])
    }

    // MARK: 运行

    private func buildRuntimePane() -> NSView {
        // 一条键管一对偏好，和菜单栏那条同名同义（`ToggleTitles.autoStartPair`）。
        //
        // 原来这里摆两个勾选框：第二个的标题得写「会一并开启开机自启」才能说清它和
        // 第一个的关系 —— 一句说明替不变式打工，正是"该并成一条"的信号。
        // 拆着摆还允许用户拧出一个自相矛盾的组合，再靠 `normalizeAutoStart`
        // 在他看不见的时候掰回来，那是界面在演一出戏。
        autoStartCheck = checkbox(ToggleTitles.autoStartPair, on: settings.launchAtLogin,
                                  action: #selector(autoStartToggled))
        hideIconCheck = checkbox(ToggleTitles.hideStatusBarIcon + "（热键仍可用，重开 app 可找回）",
                                 on: settings.hideStatusBarIcon, action: #selector(hideIconToggled))
        soundCheck = checkbox("截图后播放提示音", on: settings.playSound, action: #selector(soundToggled))
        // 窗口截图本来就不带指针（和系统 ⌘4+空格 一致），所以把适用范围写在标签里，
        // 免得有人勾了之后发现"截窗口怎么还是没有"，以为开关坏了。
        cursorCheck = checkbox("截图包含鼠标指针（整屏 / 区域）",
                               on: settings.showCursor, action: #selector(cursorToggled))

        runStateLabel = statusLabel("自启动与后台保活的当前状态")
        runStateLabel.maximumNumberOfLines = 0
        runStateLabel.lineBreakMode = .byWordWrapping
        // 左边要让出一个图标位，右边要并一个「重新登记 / 打开登录项设置」按钮
        runStateLabel.preferredMaxLayoutWidth = 396
        runStateIcon = statusIcon()

        runStateButton = button("", action: #selector(runStateActionClicked))
        runStateButton.isHidden = true
        let runStateRow = NSStackView(views: [runStateIcon, runStateLabel, runStateButton])
        runStateRow.orientation = .horizontal
        runStateRow.spacing = 8
        // 状态文字常常是三行，图标跟着垂直居中会掉在中间像个孤儿 —— 顶对齐才和
        // 第一行读在一起。
        runStateRow.alignment = .top

        permissionLabel = statusLabel("屏幕录制权限的状态提示", size: 12, color: .labelColor)
        permissionIcon = statusIcon()
        let permissionRow = NSStackView(views: [permissionIcon, permissionLabel,
                                                button("修复权限", action: #selector(fixPermission)),
                                                button("重置权限记录", action: #selector(resetPermission))])
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 8

        return pane([
            section("自动启动", rows: [autoStartCheck, runStateRow]),
            section("界面", rows: [hideIconCheck, soundCheck, cursorCheck]),
            section("屏幕录制权限", rows: [
                grouped(permissionRow,
                        legend("没有此权限时，截图只能得到桌面壁纸。"))
            ])
        ])
    }

    private func updatePermissionLabel() {
        let granted = Permissions.hasScreenRecording
        permissionLabel.stringValue = granted ? "已授权" : "未授权"
        // 字用最高对比的 labelColor，红 / 绿只留在图标上：
        // 中饱和的色字要想到 4.5:1 就得褪成粉彩色，既难看又等于把信息藏起来；
        // 而"红绿色盲看不出这是错还是对"本来就是纯靠颜色编码的第二重风险。
        permissionLabel.textColor = .labelColor
        applyStatus(permissionIcon,
                    symbol: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    color: granted ? StatusInk.success : StatusInk.problem)
    }

    /// 这一行是"要处理的问题"还是"对现状的陈述"。
    ///
    /// 单独抽出来是因为颜色这件事没法断言（动态色实例比不 equality），而分错行
    /// 才是真会发生的 bug：把陈述句涂橙、或把 ⚠ 行留在灰里，都是肉眼可见的错。
    static func isProblemLine(_ line: String, warning: Bool) -> Bool {
        guard warning else { return false }
        // 判据只能逐标量走，不能用 `hasPrefix("⚠")`：状态文案里那个警告符是
        // U+26A0 + 变体选择符 U+FE0E（强制文本字形），Swift 的标准等价比较认为
        // 带 VS15 的它和光一个 U+26A0 不相等，整条判据会静默地永远返回 false。
        // —— 这不是假想的坑，加这条断言时它真的红了。
        for scalar in line.unicodeScalars {
            switch scalar.value {
            case 0xFE0E, 0xFE0F, 0x20, 0x3000:   // 变体选择符 / 半角 / 全角空格不算"第一个字符"
                continue
            default:
                return scalar.value == 0x26A0
            }
        }
        return false
    }

    /// 状态行分轻重：不带 ⚠ 的那行是"现在是什么情况"（次级灰），带 ⚠ 的是"哪里不对"（最亮）。
    ///
    /// 问题行从前涂橙：中饱和的色字要够 4.5:1 就得褪成米色，既不好看也仍然不如白字；
    /// 而橙色的图标早就在这行左边把"这是警告"说清楚了 —— 色相交给图标，对比交给字。
    ///
    /// 整段刷橙的实际后果是一堵橙墙：三行里真正要用户动手的那一行被埋在中间，
    /// 而"当前机制：未启用"这种陈述句也跟着喊。这里一个字都不改文本，只改配色。
    static func advisoryAttributed(_ text: String, warning: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping
        let out = NSMutableAttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            out.append(NSAttributedString(
                string: index == 0 ? line : "\n" + line,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: isProblemLine(line, warning: warning)
                        ? NSColor.labelColor : NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph
                ]))
        }
        return out
    }

    /// 状态行上色的**唯一**入口：逐行前景色只由 `advisoryAttributed` 决定。
    ///
    /// 这里原来在 `attributedStringValue` 之后还跟了一句整段 `textColor = …`。
    /// 它盖不掉逐行的颜色（实测过，所以那不是 bug），但它是同一件事的第二份真相：
    /// 谁哪天把上面那句换成只设 `textColor`，分色就真的没了 —— 而像素实测那条会红。
    /// 自检要按真路径填文案，也需要这里只有一个入口。
    private func applyAdvisory(_ text: String, warning: Bool) {
        runStateLabel?.attributedStringValue = Self.advisoryAttributed(text, warning: warning)
    }

    /// 自检用：按**真路径**把状态行填成给定的几行（第一行是陈述，带 ⚠ 的那行是问题）。
    func setAdvisoryForSelfTest(lines: [String], warning: Bool) {
        applyAdvisory(lines.joined(separator: "\n"), warning: warning)
    }

    /// 自检用：状态行那块文字本体 —— 要按它在面板里的实际位置去量像素。
    var runStateLabelForSelfTest: NSTextField? { runStateLabel }

    /// 自检用：那条并起来的自动启动勾选框（标题 + 当前勾着的值）。
    ///
    /// 「一条键管两个偏好」这件事的全部风险是"框上写着两条、点下去只改一条"。
    /// 这里只读标题 —— 改动那半在 `--logic-selftest` 里按纯函数
    /// （`SettingsStore.autoStartPair`）查：真点下去会走到 `SMAppService` 登记登录项，
    /// 自检不该在用户机器上留下这种副作用。
    var autoStartCheckBoxForSelfTest: (title: String, checked: Bool)? {
        autoStartCheck.map { (title: $0.title, checked: $0.state == .on) }
    }

    private func updateRunStateLabel() {
        guard runStateLabel != nil else { return }
        let manager = AutoStartManager.shared
        let wanted = settings.launchAtLogin || settings.keepAlive
        let advisory = AutoStartManager.advisory(
            wanted: wanted,
            mechanism: manager.activeMechanism,
            statusText: manager.statusDescription,
            needsApproval: manager.needsUserApproval,
            locationWarning: manager.locationWarning)
        applyAdvisory(advisory.text, warning: advisory.isWarning)
        // 图标跟着结论走，但「没要求自启」和「已经登记好了」不是一回事：
        // 前者只是陈述（灰点），后者才是好消息（绿勾）。给反了就是界面在说谎。
        applyStatus(runStateIcon,
                    symbol: advisory.isWarning ? "exclamationmark.triangle.fill"
                        : (wanted ? "checkmark.circle.fill" : "circle"),
                    color: advisory.isWarning ? StatusInk.warning
                        : (wanted ? StatusInk.success : .tertiaryLabelColor))
        // 按钮只在真有出路时出现：没出路（比如 app 不在标准目录，得用户自己拖）
        // 还摆一个按钮，点了什么也不会变，那比没有按钮更糟。
        runStateAction = advisory.action
        runStateButton?.title = advisory.actionTitle ?? ""
        runStateButton?.isHidden = advisory.actionTitle == nil
    }

    @objc private func runStateActionClicked() {
        switch runStateAction {
        case .none:
            break
        case .reRegister:
            // force：先注销再注册，把签名/路径的旧记录刷掉。失败时让它自己说话
            // （apply 在非 .app 形态下会弹说明），别在这里替系统圆场。
            AutoStartManager.shared.apply(launchAtLogin: settings.launchAtLogin,
                                         keepAlive: settings.keepAlive, force: true)
            updateRunStateLabel()
        case .openLoginItems:
            AutoStartManager.openLoginItemsSettings()
        }
    }

    // MARK: - 控件工厂

    private func label(_ text: String,
                       size: CGFloat = 13,
                       weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor,
                       width: CGFloat? = nil) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        // ⚠️ 必须由工厂统一关掉自动转换。`section()` 里的小标题是直接 addSubview 的，
        // 不是 arranged subview —— NSStackView 只替它管子视图关这个开关。留着 true，
        // AppKit 会同时按「旧 frame」和「我们的约束」两套解，冲突时被静默 break，
        // 结果就是整节塌成标题那 16pt（四个面板一起糊在左上角，就是这个原因）。
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.preferredMaxLayoutWidth = 540
        // 垂直方向绝不让步：空间不够时宁可裁掉，也不要被压成重叠的文字
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return field
    }

    /// 图例里一行的排版：把「键名：」那截加粗提亮，说明留在常规灰。
    ///
    /// 12 行整段排下来读起来像说明书；键名加粗之后眼睛能顺着左边走，
    /// 找「空格是干什么的」从一次扫读变成一次定位。
    ///
    /// 只加粗 8 个字符以内的前缀：再长的多半不是键名，而是一句被冒号断开的说明
    /// （比如「至少两个修饰键：只按 ⌘…」这种倒是正好该加粗）。
    static func legendLine(_ line: String, size: CGFloat = 11,
                           base: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let out = NSMutableAttributedString(string: line, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: base
        ])
        guard let colon = line.firstIndex(of: "：") else { return out }
        let keyLength = line.utf16.distance(from: line.utf16.startIndex, to: colon)
        guard keyLength > 0, keyLength <= 8 else { return out }
        out.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                           .foregroundColor: NSColor.labelColor],
                          range: NSRange(location: 0, length: keyLength))
        return out
    }

    /// 一段多行说明 → 一行一个标签的紧凑列表。
    ///
    /// 拆行只是为了能逐行控距（段内 3pt、段间 8pt）；**每行的 `stringValue` 仍是
    /// 原文那一行**，所以"文案真贴在窗上"那条断言一个字都没放松。
    private func legend(_ text: String, base: NSColor = .secondaryLabelColor) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        for line in text.components(separatedBy: "\n") {
            let field = NSTextField(labelWithString: line)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.attributedStringValue = Self.legendLine(line, base: base)
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
            field.preferredMaxLayoutWidth = 520
            field.setContentCompressionResistancePriority(.required, for: .vertical)
            stack.addArrangedSubview(field)
        }
        return stack
    }

    /// 把一条设置项和它的回读行钉成**一行**。
    ///
    /// 一个控件 + 一句解释 + 一行动态回读，在卡片里各占一行时读起来像三条设置项，
    /// 而用户实际只做一个决定。组内 3pt、组间 8pt（和 `legend` 同一套间距），
    /// 于是"这几行说的是同一件事"由间距说话，不用再加一条分隔线或小标题。
    ///
    /// 自检按 `arrangedSubviews` 数行数，所以这一层折叠是真省掉了行，
    /// 不是把三行藏进一行里糊弄那个数字 —— 数出来的行数和眼睛扫到的行数一致。
    private func grouped(_ views: NSView...) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views { stack.addArrangedSubview(view) }
        return stack
    }
    ///
    /// 显式给朗读名是必须的 —— 读屏用户如果不知道有这一行，就永远听不到
    /// 「没写成功」「按了取消」这类提示，而这些恰恰是这套界面里唯一会说失败的地方。
    private func statusLabel(_ readingName: String,
                             size: CGFloat = 11,
                             color: NSColor = .secondaryLabelColor) -> NSTextField {
        let field = label("", size: size, color: color)
        field.setAccessibilityLabel(readingName)
        return field
    }

    private func checkbox(_ title: String, on: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.state = on ? .on : .off
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        return button
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        return button
    }

    /// 状态图标：只负责「这一行是好是坏」，具体说了什么由旁边的文字讲。
    ///
    /// 从可访问树里摘掉是有意的 —— 读屏念的是那句状态文字，图标再重复一遍就变成
    /// 「已授权 已授权」。
    private func statusIcon() -> NSImageView {
        let view = NSImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.imageScaling = .scaleProportionallyDown
        view.setAccessibilityElement(false)
        return view
    }

    /// 换图标 = 换结论，所以颜色和符号必须一起给，不能一处改了另一处忘。
    private func applyStatus(_ view: NSImageView, symbol: String, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        view.contentTintColor = color
    }

    // MARK: - 动作

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectoryURL
        panel.prompt = "选择"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.saveDirectory = url.path
        pathLabel.stringValue = NSString(string: url.path).abbreviatingWithTildeInPath
    }

    @objc private func openDirectory() {
        settings.ensureSaveDirectory()
        SystemOpen.open(settings.saveDirectoryURL, subject: .folder)
    }

    @objc private func formatChanged() {
        let index = formatPopup.indexOfSelectedItem
        guard ImageFormat.allCases.indices.contains(index) else { return }
        settings.imageFormat = ImageFormat.allCases[index]
        updateQualityEnabled()
        updateNameExample()
    }

    private func updateQualityEnabled() {
        let lossy = settings.imageFormat != .png
        qualitySlider.isEnabled = lossy
        qualityLabel.textColor = .secondaryLabelColor
    }

    @objc private func qualityChanged() {
        settings.jpegQuality = qualitySlider.doubleValue
        qualityLabel.stringValue = String(format: "%.0f%%", qualitySlider.doubleValue * 100)
    }

    @objc private func namePatternChanged() {
        let trimmed = namePatternField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 留空是一条**明确的选择**，不是"什么都没改"：示例行承诺了「退回默认名
        // Grabi」（`sanitize("")` 也确实给 Grabi），所以这里必须把空串写进偏好。
        // 以前用 `if !trimmed.isEmpty` 挡了一下，于是清空输入框后 label 说"会退回默认"，
        // 下一张截图却仍然按旧模板命名 —— 提示和实际行为分家。
        settings.fileNamePattern = trimmed
        updateNameExample()
        // 示例折行数变了 → 面板高度变了。不重新量一次，窗口还是旧高度，
        // 多出来的那几行就压在窗口外面（内容驱动高度这件事，改内容就得重算）。
        showPane(at: switcher.selectedSegment)
    }

    /// 实时示例名：告诉他这个模板最后会长成什么样（连扩展名一起）。
    /// 光给一串 `{date}` 占位符是不够的 —— 用户得看得见结果才知道值不值。
    private func updateNameExample() {
        guard let nameExampleLabel, let namePatternField else { return }
        let raw = namePatternField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            nameExampleLabel.stringValue = "留空会退回默认名 Grabi"
            nameExampleLabel.textColor = .labelColor
            return
        }
        let cleaned = SettingsStore.renderedName(raw, type: "region")
        let example = cleaned + "." + settings.imageFormat.fileExtension
        // 悄悄改用户的模板是最糟的一种"贴心"。改了什么、哪一处没看懂，当场说清楚。
        // 而且**只说真动了的那几刀**：以前只要结果不同就同时报「非法字符已换成 -，
        // 超长已截断」，一个只是超长的模板会被说成连字符都被改过。
        let issues = SettingsStore.templateIssues(pattern: raw, type: "region")
        if issues.isEmpty {
            nameExampleLabel.stringValue = "例如 \(example)"
            nameExampleLabel.textColor = .secondaryLabelColor
        } else {
            nameExampleLabel.stringValue = "例如 \(example)　·　" + issues.joined(separator: "，")
            nameExampleLabel.textColor = .labelColor
        }
    }

    @objc private func saveOCRTextToggled() { settings.saveOCRText = (saveOCRTextCheck.state == .on) }
    @objc private func autoCopyOCRToggled() { settings.autoCopyOCRText = (autoCopyOCRCheck.state == .on) }

    @objc private func languageToggled(_ sender: NSButton) {
        guard let code = sender.identifier?.rawValue else { return }
        let displayed = languageCodes
        let resolved = Self.languageToggle(displayed: displayed,
                                           selected: Set(settings.ocrLanguages),
                                           code: code,
                                           on: sender.state == .on)
        for (displayedCode, button) in languageChecks {
            button.state = resolved.checked.contains(displayedCode) ? .on : .off
        }
        settings.ocrLanguages = resolved.stored
        languageStatusLabel?.stringValue = Self.languageStatus(
            fallbackName: resolved.fallbackName, available: resolved.available)
        // 换识别语言不是"改个参数"那么便宜：实测切换 `recognitionLanguages`
        // 会让 Vision 重新加载另一套模型，首次要多花约 28 秒。
        // 所以改完立刻后台重新预热，别把这笔账留到用户下一次点「识别文字」。
        OCRRecognizer.warmUp(force: true)
    }

    /// 两个录制框是不是真的接上了提交通道。不接的症状很难发现：框里的字照样换、
    /// 点别处也不报错，只是偏好里永远还是旧的那条。
    var hotKeyRecordersWiredForSelfTest: Bool {
        hotKeyViews.count == 1 && hotKeyViews.values.allSatisfy { $0.onChange != nil }
    }

    private func commitHotKey(_ key: String) {
        guard let recorder = hotKeyViews[key] else { return }
        let newValue = recorder.spec
        let previous = settings.hotKeyCapture
        let decision = Self.commitDecision(for: key,
                                          newValue: newValue,
                                          capture: settings.hotKeyCapture)

        switch decision {
        case .accept:
            break
        case .takenByOtherField(let conflict):
            presentInfo("快捷键冲突", "\(newValue.displayString) 已被「\(conflict)」占用，请换一个组合。")
            recorder.spec = previous
            return
        case .asksAboutSystemScreenshot:
            guard Self.confirmSystemScreenshotTakeover(newValue) else {
                recorder.spec = previous   // 用户选了「换一个组合」，偏好没动过，框里得回到原来那条
                return
            }
        }

        switch key {
        case "capture": settings.hotKeyCapture = newValue
        default: break
        }
        onSettingsChanged?()
    }

    /// 一次热键提交的三种下场。
    ///
    /// 「先判哪个」这种顺序写错不会崩，只会让用户看到一条不相干的提示，
    /// 所以把判断抽成纯函数钉住：撞了 Grabi 自己另一条 field 时先说"已被占用"，
    /// 因为它比"系统也在这条上"更确定。
    enum HotKeyCommit: Equatable {
        case accept
        case takenByOtherField(String)
        case asksAboutSystemScreenshot
    }

    static func commitDecision(for key: String, newValue: HotKeySpec,
                               capture: HotKeySpec) -> HotKeyCommit {
        // 停用（.none）不参与冲突判断：两条都停用时不算"撞车"
        if !newValue.isDisabled {
            let others: [(String, String, HotKeySpec)] = [
                ("capture", "截图", capture)
            ]
            if let conflict = others.first(where: { $0.0 != key && !$0.2.isDisabled && $0.2 == newValue })?.1 {
                return .takenByOtherField(conflict)
            }
        }
        if newValue.conflictsWithSystemScreenshot { return .asksAboutSystemScreenshot }
        return .accept
    }

    /// 撞 macOS 自带截图时先问一句，用户坚持就让他坚持。
    ///
    /// 实测 `RegisterEventHotKey` 对 ⇧⌘4 返回 noErr，系统不会告诉我们"这条我占着"，
    /// 所以只能自己把话说清楚 —— 而不是默默收下、让用户以为换好了。
    @discardableResult
    static func confirmSystemScreenshotTakeover(_ spec: HotKeySpec) -> Bool {
        systemScreenshotAlert(spec).runModal() != .alertFirstButtonReturn
    }

    /// 单独拆出来是因为「哪个按钮是默认项」这件事只能从组装好的 alert 上读，
    /// 而按错默认项的后果是：用户按下回车就把自己坑了。自检不弹框，读按钮顺序。
    static func systemScreenshotAlert(_ spec: HotKeySpec) -> NSAlert {
        let plan = systemScreenshotPrompt(spec)
        let alert = NSAlert()
        alert.messageText = plan.title
        alert.informativeText = plan.detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: plan.swapTitle)
        alert.addButton(withTitle: plan.keepTitle)
        return alert
    }

    static func systemScreenshotPrompt(_ spec: HotKeySpec)
        -> (title: String, detail: String, swapTitle: String, keepTitle: String) {
        (
            title: "\(spec.displayString) 是 macOS 自带截图的组合键",
            detail: """
            Grabi 能把这条注册上，但系统那边它也是开着的 —— 按键到底哪边响应，\
            取决于谁后注册，重启之后还可能变。

            想稳妥地交给 Grabi：先去「系统设置 › 键盘 › 键盘快捷键 › 屏幕快照」\
            把系统那几条关掉，再回来录一次。
            不想动系统设置的话，换一条 ⌃⌥ 开头的组合最省事。
            """,
            swapTitle: "换一个组合",
            keepTitle: "仍要用 \(spec.displayString)"
        )
    }

    /// 自检缝：把真弹窗和真写盘临时换成假的，好让**按钮那条路**（`#selector` 派发）
    /// 也能被驱动。默认 nil = 生产行为。
    /// 没有它的话，把下面的方法体改回"无条件恢复"，自检照样全绿 —— 上一轮的对照
    /// 就是这么露馅的。
    var hotKeyResetOverridesForSelfTest: (write: (() -> Void)?, confirm: (([HotKeyChange]) -> Bool)?)?

    @objc private func resetHotKeys() {
        let ov = hotKeyResetOverridesForSelfTest
        performHotKeyReset(write: ov?.write ?? { [weak self] in self?.settings.resetHotKeys() },
                           confirm: ov?.confirm ?? { Self.confirmHotKeyReset($0) })
    }

    /// 自检用：按**真的 target/action 派发**点一次这个按钮，返回观察到的副作用。
    /// 走 `NSApp.sendAction` 而不是直接调方法，这样"方法存在但按钮没接上"也照样红。
    func clickResetButtonForSelfTest(write: @escaping () -> Void,
                                     confirm: @escaping ([HotKeyChange]) -> Bool) -> Bool {
        guard let button = hotKeyResetButton else { return false }
        hotKeyResetOverridesForSelfTest = (write, confirm)
        defer { hotKeyResetOverridesForSelfTest = nil }
        return NSApp.sendAction(#selector(resetHotKeys), to: button.target, from: button)
    }

    /// 真方法本体：写盘和问句都注入，所以自检能驱动**同一条路径**而不碰用户的偏好、
    /// 也不弹窗（模态框在自检里没法答，答错一次还把设置真改了）。
    @discardableResult
    func performHotKeyReset(write: () -> Void,
                            confirm: ([SettingsWindowController.HotKeyChange]) -> Bool)
        -> SettingsWindowController.HotKeyResetOutcome {
        performHotKeyReset(capture: settings.hotKeyCapture,
                           write: write, confirm: confirm)
    }

    /// 当前组合也从外面给：自检要能在"有东西可恢复"和"本来就是默认"两种状态下都走
    /// 一遍真路径。本机默认值本来就落在其中一种上，只读设置的话另一种永远测不到。
    @discardableResult
    func performHotKeyReset(capture: HotKeySpec,
                            write: () -> Void,
                            confirm: ([SettingsWindowController.HotKeyChange]) -> Bool)
        -> SettingsWindowController.HotKeyResetOutcome {
        let outcome = Self.runReset(capture: capture,
                                    write: write, confirm: confirm)
        hotKeyStatusLabel?.stringValue = Self.resetStatus(outcome)
        // 只有真改了才要重排窗口和重发热键：按了取消却去 refresh()，会把用户
        // 正在录的那一半状态也一起抹掉；而 `onSettingsChanged` 会重新注册全局热键，
        // 什么都没改也去重注册一遍，就是把用户的键再抢一次。
        guard case .restored = outcome else { return outcome }
        refresh()
        onSettingsChanged?()
        return outcome
    }

    /// 自检用：把状态行的文字也交出去，好证明那句"没改任何东西"是真显示在窗上的。
    var hotKeyStatusLabelTextForSelfTest: String { hotKeyStatusLabel?.stringValue ?? "" }

    /// 自检用：两个框当前显示的组合（用来证明按了取消之后它们一个像素都没动）。
    var hotKeyViewsSnapshotForSelfTest: [String: HotKeySpec] {
        hotKeyViews.mapValues { $0.spec }
    }

    @discardableResult
    static func confirmHotKeyReset(_ changes: [HotKeyChange]) -> Bool {
        resetAlert(changes).runModal() == .alertFirstButtonReturn
    }

    /// 自检用：按钮的接线（target/action/状态栏真在窗口里）。
    var hotKeyResetWiringForSelfTest: [String: Bool] {
        return ["action": hotKeyResetButton?.action == #selector(resetHotKeys),
                "target": hotKeyResetButton?.target === self]
    }

    /// 自检用：状态行落在第几个面板里（面板是切到那一段才挂进窗口的）。
    func paneIndexContainingForSelfTest(_ label: NSTextField) -> Int? {
        for (i, pane) in panes.enumerated() where Self.contains(view: pane.view, label) { return i }
        return nil
    }

    var hotKeyStatusLabelForSelfTest: NSTextField? { hotKeyStatusLabel }

    /// 自检用：把状态行抹成一个不可能的值，好让"方法体压根没设置它"的对照露出来。
    func hotKeyStatusLabelOverrideForSelfTest(_ text: String) { hotKeyStatusLabel?.stringValue = text }

    static func contains(view root: NSView?, _ view: NSView) -> Bool {
        guard let root else { return false }
        if root === view { return true }
        return root.subviews.contains { Self.contains(view: $0, view) }
    }

    @objc private func autoStartToggled() {
        // 一次改动写两条：它们本来就是同一个决定的两面（登录进来把 app 带起来，
        // 崩了再把它拉起来）。判断抽在 `SettingsStore.autoStartPair` 里，
        // 和菜单栏那条共用 —— 两处各写一遍就会有一处先漂。
        let pair = SettingsStore.autoStartPair(turningOn: autoStartCheck.state == .on)
        settings.launchAtLogin = pair.launchAtLogin
        settings.keepAlive = pair.keepAlive
        AutoStartManager.shared.apply(launchAtLogin: pair.launchAtLogin,
                                      keepAlive: pair.keepAlive)
        updateRunStateLabel()
        onSettingsChanged?()
    }

    @objc private func hideIconToggled() {
        settings.hideStatusBarIcon = (hideIconCheck.state == .on)
        onSettingsChanged?()
    }

    @objc private func soundToggled() { settings.playSound = (soundCheck.state == .on) }
    @objc private func cursorToggled() { settings.showCursor = (cursorCheck.state == .on) }

    @objc private func fixPermission() {
        if Permissions.hasScreenRecording {
            Permissions.openScreenRecordingSettings()
        } else {
            _ = Permissions.ensureScreenRecording(interactive: true, forcePrompt: true)
        }
        updatePermissionLabel()
    }

    @objc private func resetPermission() {
        if Permissions.resetScreenRecordingRecord() {
            Permissions.presentResetDone()
        } else {
            // 重置失败时不能什么都不发生：`ensureScreenRecording` 在"权限已经
            // 拿到"的机器上会直接返回 true，等于还是静默。这里必须明说失败，
            // 并给出下一步（手动去系统设置里删掉旧记录）。
            presentInfo("没能重置权限记录",
                        "系统没有接受这次重置。请打开「系统设置 › 隐私与安全性 › "
                            + "屏幕与系统音频录制」，手动移除 Grabi 后重新添加并授权。")
        }
        updatePermissionLabel()
    }

    private func presentInfo(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 窗口代理

    func windowWillClose(_ notification: Notification) {
        let trimmed = namePatternField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 和 `namePatternChanged` 同一条规则：清空 = 用默认名，不能因为窗口关闭
        // 这条兜底路径又把它当成"没改过"跳过。
        settings.fileNamePattern = trimmed
        if let window { WindowFrameMemory.save(window, name: "settings") }
    }

    /// 挪动之后就记，不等关窗：用户常常是拖一下、看完设置直接 ⌘Q 的。
    func windowDidMove(_ notification: Notification) {
        if let window { WindowFrameMemory.save(window, name: "settings") }
    }
}

/// 设置窗口：按 Esc 就能关。
///
/// 系统里几乎所有非模态面板都支持 Esc 关闭，不支持的那一个会被判成"半成品"；
/// 而在这个纯键盘可达的面板里，Esc 也是用户从「改设置」回到「继续干活」最自然的一条退路。
final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
    /// ⌘1…⌘4 的分发点。没走「注册一个全局按键监视器」那条路：监视器挂在进程上，
    /// 忘了在关窗时摘就每开一次漏一个，而重写 `sendEvent` 天生只作用于这个窗口，
    /// 「摘不摘」这件事根本不存在。
    ///
    /// 必须在 `super` 之前问：`sendEvent` 里接下来就是 `performKeyEquivalent` 和响应链，
    /// 录制框正是靠响应链拿到按键的 —— 所以这里得先看清是不是录制框在收键。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           let controller = delegate as? SettingsWindowController,
           controller.handleKeyDown(characters: event.charactersIgnoringModifiers,
                                    modifiers: event.modifierFlags,
                                    isRecordingHotKey: firstResponder is HotKeyRecorderView) {
            return
        }
        super.sendEvent(event)
    }
}

/// 分组卡片底：圆角 + 一条发丝描边，把「这几行是一组」画出来，而不是只靠缩进暗示。
///
/// 用 `draw` 每帧现解颜色，而不是 `layer.backgroundColor`：后者在建视图那一刻
/// 就把动态色冻成固定 RGBA，用户切深/浅色之后卡片会一直停在旧外观上。
final class SettingsCardView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 内缩 0.5：描边压在像素格子上而不是跨两格，1× 屏上才不会糊成一条灰边
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 8, yRadius: 8)
        NSColor.quaternaryLabelColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// 状态色（正文和小图标用）：按外观各解算一档，保证在卡片上够看清。
///
/// 为什么不直接用 `systemOrange` / `systemRed` / `systemGreen`：那三个是给大色块和
/// 强调设计的，拿来写 11pt 正文，在浅色卡片上只有 1.6:1（深色下也才 4.2:1）——
/// 最需要用户动手的那一行恰恰最看不清。这里每一档都是按 WCAG 相对亮度对
/// 「卡片底」量出来的：深浅两遍都 ≥4.5:1，`--ui-render` 里那条对比检查会盯着它。
enum StatusInk {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    private static func srgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
                alpha: 1)
    }

    /// 警示（橙）：要用户动手，但还没到出错那一步。
    static let warning = dynamic(light: srgb(140, 72, 0), dark: srgb(255, 178, 84))
    /// 出错 / 不可用（红）。
    static let problem = dynamic(light: srgb(176, 16, 22), dark: srgb(255, 152, 148))
    /// 已就绪（绿）。
    static let success = dynamic(light: srgb(10, 105, 25), dark: srgb(90, 225, 120))
}
