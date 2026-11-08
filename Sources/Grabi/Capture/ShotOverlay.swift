import AppKit
import ScreenCaptureKit

/// 一次截图选择的结果。
///
/// 每个 case 都带上「选区在屏幕上的位置」——截图完成后的预览面板要**就地**
/// 盖在原来的选区上，所以坐标必须一路传下去。
enum SelectionOutcome {
    /// 窗口截图。`frameInScreenCoords` 是窗口在屏幕坐标系（原点主屏左下）中的矩形。
    case window(SCWindow, frameInScreenCoords: CGRect)
    /// 整屏截图。
    case display(NSScreen)
    /// 区域截图。`rectInScreenCoords` 是选区在屏幕坐标系中的矩形。
    case region(rectInScreenCoords: CGRect, screen: NSScreen)
    case cancelled
}

/// 统一的截图选择覆盖层。
///
/// 一个快捷键进入，不需要用户先选模式——候选框跟着鼠标走：
///
/// | 鼠标位置 | 实时候选框 | 单击结果 |
/// |---|---|---|
/// | 落在某个窗口上 | 该窗口的边框 | 截该窗口 |
/// | 落在桌面 / 屏幕空隙 | 整块屏幕 | 截全屏 |
/// | 按住并拖动 | 拖出来的矩形 | 截该区域 |
///
/// 也就是说「单击」是采用当前候选，「拖拽」是画自定义区域，两种意图靠
/// 松手时是否产生位移来自动区分（阈值 `dragThreshold`）。
/// Esc 随时取消。
///
/// 键盘那一轨（不用碰鼠标也能完成一次截图）：
///
/// | 键 | 作用 |
/// |---|---|
/// | 空格 | 切到整屏候选 |
/// | ⏎ | 采用当前候选（和单击同一段判断） |
/// | Esc | 取消 |
///
/// 方向键微调这一轨做过又拆了，原因写在 `OverlayKey` 上：调好的那一格会被下一次
/// 鼠标移动吞掉，而鼠标几乎一定在动。要精确框选走拖动（`⇧` 锁正方形、`⌥` 从中心）。
final class ShotOverlayController {

    private var windows: [OverlayWindow] = []
    private var completion: ((SelectionOutcome) -> Void)?
    private var candidates: [CaptureEngine.WindowCandidate] = []
    private var isPresenting = false
    private var didFinish = false

    /// 覆盖层当前是否开着（用于避免热键重复触发）。
    var isActive: Bool { isPresenting }

    /// 覆盖层当前的窗口号。抓图时交给 `SCContentFilter` 排除——
    /// 正常截图时覆盖层要一直留到抓完，屏幕上才不会先亮一下实时桌面。
    var windowIDs: [CGWindowID] { windows.map { CGWindowID($0.windowNumber) } }

    /// 操作提示是否还该画。
    ///
    /// 提示必须**持续显示**到用户第一次按下鼠标（或过一会儿自己收），
    /// 而不是"画一次就没了"：遮罩每动一下鼠标就重绘一次，
    /// 画一次就消失等于只闪了一帧，用户根本来不及读。
    private var isHintVisible = false
    /// 提示只挂在鼠标所在的那块屏上，多屏同时挂三份就是三份噪音。
    private weak var hintScreen: NSScreen?
    /// 5 秒后自动收提示的排程。上一轮的定时器必须在新一轮开始时取消：
    /// 否则用户 5 秒内连截两张，第二张的提示会被第一张的定时器提前收掉。
    private var hintHideWorkItem: DispatchWorkItem?

    // MARK: - 开始 / 结束

    func begin(completion: @escaping (SelectionOutcome) -> Void) {
        guard !isPresenting else { return }
        self.completion = completion
        self.isPresenting = true
        self.didFinish = false
        self.isHintVisible = false
        self.hintHideWorkItem?.cancel()
        self.hintHideWorkItem = nil
        self.hintScreen = nil

        // 先取窗口列表，再铺覆盖层 —— 否则会把覆盖层自己也算成候选窗口。
        Task { @MainActor in
            do {
                self.candidates = try await CaptureEngine().windowCandidates()
            } catch {
                Log.capture.error("获取窗口列表失败: \(error.localizedDescription)")
                self.candidates = []
            }
            // 取窗口列表是异步的；这期间可能已经被取消（退出、或调用方收尾）。
            // 已经结束的这一次不能再把覆盖层铺上来。
            guard self.isPresenting, !self.didFinish else { return }
            self.presentOverlays()
        }
    }

    private func presentOverlays() {
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame,
                                       styleMask: .borderless,
                                       backing: .buffered,
                                       defer: false,
                                       screen: screen)
            window.setFrame(screen.frame, display: false)
            window.animationBehavior = .none
            window.level = ShotLevels.overlay
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                         .stationary, .ignoresCycle]
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true

            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.controller = self
            view.screenRef = screen
            view.candidates = candidates

            window.contentView = view
            // 覆盖层从透明里落下来：快捷键按下去时屏幕不是"啪"地换了一张脸，
            // 而是先出现一层浅压暗，再让候选框接管视觉。只进行一次，鼠标移动不会重跑。
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.makeKey()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.set()

        // 让鼠标所在屏幕拿到 key，Esc 才能被它接住
        let mouse = NSEvent.mouseLocation
        if let target = windows.first(where: { $0.frame.contains(mouse) }) {
            target.makeKey()
            (target.contentView as? OverlayView)?.refreshHover(atScreenPoint: mouse)
        }

        Motion.run(duration: Design.Timing.fade, curve: Motion.Curve.enter) {
            for window in windows { window.animator().alphaValue = 1 }
        }

        hintScreen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        isHintVisible = true
        hintHideWorkItem?.cancel()
        let hide = DispatchWorkItem { [weak self] in self?.hideHint() }
        hintHideWorkItem = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: hide)
    }

    /// 某块屏上是否还要画操作提示。
    fileprivate func drawsHint(on screen: NSScreen?) -> Bool {
        isHintVisible && screen != nil && screen === hintScreen
    }

    /// 离屏渲染自检用：摆出「提示条正在显示」的状态（真实路径由 `present` 打开）。
    func showHintForSelfTest(on screen: NSScreen?) {
        hintScreen = screen
        isHintVisible = true
    }

    fileprivate func hideHint() {
        guard isHintVisible else { return }
        hintHideWorkItem?.cancel()
        hintHideWorkItem = nil
        isHintVisible = false
        for window in windows {
            (window.contentView as? OverlayView)?.fadeHintOut()
        }
    }

    func dismiss() {
        hintHideWorkItem?.cancel()
        hintHideWorkItem = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        isPresenting = false
        NSCursor.arrow.set()
    }

    fileprivate func finish(_ outcome: SelectionOutcome) {
        guard !didFinish else { return }
        didFinish = true

        let callback = completion
        completion = nil

        // 只有取消才立刻撤。正常截图把覆盖层留到调用方抓完图——
        // 先撤的话，松手到预览出现之间会露出实时桌面，就是「松手闪一下」。
        // 抓图时用 `windowIDs` 把覆盖层排除在画面之外。
        if case .cancelled = outcome { dismiss() }
        callback?(outcome)
    }

    func cancel() { finish(.cancelled) }

    /// 鼠标点（屏幕坐标）下的候选窗口，取最上层那个。
    fileprivate func candidateWindow(at screenPoint: CGPoint) -> CaptureEngine.WindowCandidate? {
        candidates.first { $0.frameInScreenCoords.contains(screenPoint) }
    }
}

// MARK: - 覆盖窗口

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        (contentView as? OverlayView)?.controller?.cancel()
    }

    /// ⌘W 和 Esc 一样是"这次不截了"。主菜单现在有了「关闭」项，
    /// 不接住的话它会对着一个无边框窗口空转，用户以为按了没反应。
    override func performClose(_ sender: Any?) {
        (contentView as? OverlayView)?.controller?.cancel()
    }
}

// MARK: - 覆盖视图

final class OverlayView: NSView {

    /// 位移小于这个值就当作单击（采用候选），而不是画了个很小的区域。
    private static let dragThreshold: CGFloat = 5

    weak var controller: ShotOverlayController?
    var screenRef: NSScreen?
    var candidates: [CaptureEngine.WindowCandidate] = []

    /// 当前候选框（视图坐标）。单击时采用它。
    private var hoverRect: NSRect?
    private var hoverWindow: SCWindow?
    private var hoverIsDisplay = false

    /// 候选框的**屏幕呈现位置**。鼠标从一个窗口移到另一个窗口时，这个矩形会
    /// 从旧候选滑到新候选；`hoverRect` 仍然是"最终命中"的唯一真相。
    /// 只动画候选框，拖拽选区始终 1:1 跟手。
    private var hoverPresentationRect: NSRect?
    private var hoverTween: Timer?
    private var hoverTweenFrom: NSRect = .zero
    private var hoverTweenTo: NSRect = .zero
    private var hoverTweenStartedAt: CFTimeInterval = 0
    private var hoverTweenDuration: TimeInterval = 0

    /// 拖拽状态（视图坐标）。
    private var anchor: NSPoint?
    private var current: NSPoint?
    private var isDragging = false
    /// ⌥ 拖拽中：按下点是选区的**中心**而不是角（见 `selectionRect`）。
    private var dragFromCenter = false
    /// 按下瞬间锁定的候选，用于判断这次是「单击候选」还是「画区域」。
    private var pendingWindow: SCWindow?
    private var pendingIsDisplay = false
    /// 按下瞬间候选框的位置（视图坐标），要一路带到预览面板做"就地显示"。
    private var pendingRect: NSRect?

    private var trackingAreaRef: NSTrackingArea?
    /// 提示条的局部透明度。5 秒后让它淡出，而不是在用户读到一半时整块消失。
    private var hintAlpha: CGFloat = 1
    private var hintFadeTimer: Timer?
    private var isHintFading = false

    /// 覆盖层认的键。抽成数据是为了让「按下的是什么键」和「该做什么」
    /// 两件事能各自被查：`key(forKeyCode:)` 是纯函数，自检不用造 `NSEvent`。
    ///
    /// 方向键微调这一轨做过又拆掉了：调好的那一格会被下一次鼠标移动吞掉，
    /// 而鼠标几乎一定在动（触控板挪一毫米就是 `mouseMoved`）—— 一个"按了会被撤销"的键
    /// 比没有这个键更让人以为坏了。要精确框选走拖动，要换候选走 `空格` / `Esc`。
    enum OverlayKey: Equatable {
        case adopt
        case cancel
        case fullscreen
        case other
    }

    static func key(forKeyCode code: Int) -> OverlayKey {
        // 36 = 回车，76 = 小键盘回车。
        if code == 36 || code == 76 { return .adopt }
        if code == 53 { return .cancel }
        if code == 49 { return .fullscreen }
        return .other
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 整块屏都是这一个视图画的：不给名字的话 VoiceOver 用户点上去只听到"组"，
        // 而这恰恰是一个纯键盘/读屏用户最需要知道"这里能干什么"的地方。
        setAccessibilityLabel("截图选区：移动鼠标选窗口或整屏，按住拖动可自由框选，"
                              + "按 ⏎ 截取当前候选，按空格切到整屏，按 Esc 取消")
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("不支持归档加载") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    deinit {
        hoverTween?.invalidate()
        hintFadeTimer?.invalidate()
    }

    // MARK: 追踪

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: 候选框计算

    /// 根据鼠标的屏幕坐标刷新候选框。
    ///
    /// - 鼠标下有窗口 → 候选该窗口
    /// - 否则（桌面、窗口之间的空隙）→ 候选整块屏幕
    func refreshHover(atScreenPoint point: CGPoint) {
        guard !isDragging else { return }

        let next: NSRect?
        if let hit = controller?.candidateWindow(at: point) {
            let local = viewRect(fromScreenRect: hit.frameInScreenCoords)
            next = local
            hoverWindow = hit.window
            hoverIsDisplay = false
        } else if let screen = screenRef {
            next = viewRect(fromScreenRect: screen.frame)
            hoverWindow = nil
            hoverIsDisplay = true
        } else {
            next = nil
            hoverWindow = nil
            hoverIsDisplay = false
        }

        let old = hoverRect
        hoverRect = next
        guard !rectsAlmostEqual(old, next) else {
            needsDisplay = true
            return
        }
        animateHover(to: next)
    }

    private func clearHover() {
        hoverTween?.invalidate()
        hoverTween = nil
        hoverPresentationRect = nil
        hoverRect = nil
        hoverWindow = nil
        hoverIsDisplay = false
        needsDisplay = true
    }

    private func rectsAlmostEqual(_ a: NSRect?, _ b: NSRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
                && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
        default: return false
        }
    }

    /// 候选框换目标时用一小段减速曲线接上去。直接跳会让"扫过一排窗口"的
    /// 过程看起来像界面在抽搐；拖拽仍然不经过这里，所以不会牺牲框选精度。
    private func animateHover(to target: NSRect?) {
        hoverTween?.invalidate()
        hoverTween = nil

        guard !Motion.isReduced, hoverPresentationRect != nil, let target else {
            hoverPresentationRect = target
            needsDisplay = true
            return
        }

        hoverTweenFrom = hoverPresentationRect ?? target
        hoverTweenTo = target
        hoverTweenStartedAt = CACurrentMediaTime()
        hoverTweenDuration = Motion.duration(0.16)

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - self.hoverTweenStartedAt
            let progress = self.hoverTweenDuration > 0
                ? min(1, elapsed / self.hoverTweenDuration) : 1
            let eased = 1 - pow(1 - progress, 3)
            self.hoverPresentationRect = NSRect(
                x: self.hoverTweenFrom.minX
                    + (self.hoverTweenTo.minX - self.hoverTweenFrom.minX) * eased,
                y: self.hoverTweenFrom.minY
                    + (self.hoverTweenTo.minY - self.hoverTweenFrom.minY) * eased,
                width: self.hoverTweenFrom.width
                    + (self.hoverTweenTo.width - self.hoverTweenFrom.width) * eased,
                height: self.hoverTweenFrom.height
                    + (self.hoverTweenTo.height - self.hoverTweenFrom.height) * eased)
            self.needsDisplay = true
            if progress >= 1 {
                timer.invalidate()
                self.hoverTween = nil
                self.hoverPresentationRect = self.hoverTweenTo
            }
        }
        hoverTween = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 压暗整屏
        ctx.setFillColor(Design.Ink.dimSelect.cgColor)
        ctx.fill(bounds)

        let rect = activeRect
        if let rect, rect.width > 1, rect.height > 1 {
            // 挖空：用 .clear 混合模式擦掉已填充的暗色，直接看到底下真实画面
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.fill(rect)
            ctx.restoreGState()

            Self.drawFrame(rect, context: ctx, active: isDragging)
            drawBadge(for: rect, context: ctx)
        }

        drawHintIfNeeded(context: ctx)
    }

    /// 当前要高亮的矩形：拖拽时是选区，否则是 hover 候选。
    private var activeRect: NSRect? {
        if isDragging { return selectionRect }
        return hoverPresentationRect ?? hoverRect
    }

    private var selectionRect: NSRect? {
        guard let anchor, let current else { return nil }
        if dragFromCenter {
            // ⌥：按下点是**中心**，位移是半宽半高（系统截图与「预览」的惯例）。
            // 之前这里只是把位移乘 2，按下点仍然是角 —— 提示条写着「⌥ 从中心」，
            // 实际做的却是"拖得更快"，属于说了没做。
            let halfWidth = abs(current.x - anchor.x)
            let halfHeight = abs(current.y - anchor.y)
            return NSRect(x: anchor.x - halfWidth, y: anchor.y - halfHeight,
                          width: halfWidth * 2, height: halfHeight * 2)
                .intersection(bounds)
        }
        return NSRect(x: min(anchor.x, current.x),
                      y: min(anchor.y, current.y),
                      width: abs(anchor.x - current.x),
                      height: abs(anchor.y - current.y))
    }

    /// 选区框：**一条贴边的强调色细线 + 四角白色括号**，不画手柄圆点。
    ///
    /// 以前这里在四边中点和四角画 8 个白点，而覆盖层压根没有手柄拖拽 ——
    /// `mouseDown` 一律重新开始画选区。那 8 个点就是本仓库一路在抓的「假把手」：
    /// 画出来的必须能操作。真正能拖的那一圈在预览面板上（`ResizeHandlesView`），
    /// 那里八个都是活的，形状也分开了（四角方块、四边短棒）。
    ///
    /// 括号为什么是白的、细线为什么留蓝：白色加一圈深色底，压在纯白窗口和近黑桌面上
    /// 都读得出来（旧版那颗白点正是靠这个），而自检可以只问一句"白色像素在哪儿" ——
    /// 四角有、别处没有，这一条同时钉住"括号画了"和"圆点没了"两件事。
    ///
    /// 所有描边都画在选区**以内**。画在外侧的话，候选一贴到屏幕边缘就被视图边界裁掉 ——
    /// 而「整屏」候选就是整个屏幕，四条线一条都不剩：离屏渲染里看到的就是
    /// "画面亮了但没有任何框"，用户完全不知道该状态点下去是截全屏。
    private static func drawFrame(_ rect: NSRect, context: CGContext, active: Bool) {
        let line: CGFloat = active ? 1.5 : 1
        let halo: CGFloat = line + 2.5

        context.setLineCap(.round)
        context.setStrokeColor(Design.Ink.halo.cgColor)
        context.setLineWidth(halo)
        context.stroke(rect.insetBy(dx: halo / 2, dy: halo / 2))
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(line)
        context.stroke(rect.insetBy(dx: line / 2, dy: line / 2))

        let arm = Self.cornerTick(minSide: min(rect.width, rect.height))
        guard arm > 0 else { return }
        let tick: CGFloat = active ? 3.5 : 3
        let box = rect.insetBy(dx: tick / 2, dy: tick / 2)
        for corner in Self.cornerTicks(in: box, arm: arm) {
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(tick + 2.5)
            context.addPath(corner)
            context.strokePath()
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(tick)
            context.addPath(corner)
            context.strokePath()
        }
    }

    /// 括号臂长：短边的两成，最长 30pt，并且**一条边上两只不许碰头**（至少留 4pt 缝）。
    ///
    /// 不夹后半句的话，一块 24×18 的小选区会被四对括号连成一整条实线 —— 那又变回
    /// "框"了，而括号要说的恰恰是"这四角定义了这一块"。夹到 0 也允许：小到放不下
    /// 就不画括号，细线还在。
    static func cornerTick(minSide: CGFloat) -> CGFloat {
        let wanted = min(30, max(8, minSide * 0.2))
        return min(wanted, max(0, minSide / 2 - 4))
    }

    /// 四个角的 L 形路径（同一份几何给绘制和自检用）。
    /// 传进来的 `rect` 就是括号拐角所在的那个矩形。
    static func cornerTicks(in rect: NSRect, arm: CGFloat) -> [CGPath] {
        var paths: [CGPath] = []
        for cornerXIsMin in [true, false] {
            for cornerYIsMin in [true, false] {
                let cx = cornerXIsMin ? rect.minX : rect.maxX
                let cy = cornerYIsMin ? rect.minY : rect.maxY
                let dx: CGFloat = cornerXIsMin ? 1 : -1
                let dy: CGFloat = cornerYIsMin ? 1 : -1
                let path = CGMutablePath()
                path.move(to: NSPoint(x: cx + dx * arm, y: cy))
                path.addLine(to: NSPoint(x: cx, y: cy))
                path.addLine(to: NSPoint(x: cx, y: cy + dy * arm))
                paths.append(path)
            }
        }
        return paths
    }

    /// 尺寸标签：同时给出像素尺寸和逻辑尺寸，避免用户以为截小了。
    private func drawBadge(for rect: NSRect, context: CGContext) {
        // 候选框在缓动时，边框跟着中间帧走；角标里的尺寸却应该直接说
        // "这一下会截到多大"。否则那串数字会在 0.16 秒里一路跳，
        // 像在倒计时，反而不安。位置仍跟着中间帧，读数用目标帧。
        let measured = isDragging ? rect : (hoverRect ?? rect)
        let scale = screenRef?.backingScaleFactor ?? 2
        let pixelWidth = Int((measured.width * scale).rounded())
        let pixelHeight = Int((measured.height * scale).rounded())

        var title = ""
        var subtitle = ""

        if isDragging {
            title = "\(pixelWidth) × \(pixelHeight)"
            subtitle = scale > 1 ? "\(Int(measured.width))×\(Int(measured.height)) pt @\(Int(scale))x" : ""
        } else if hoverIsDisplay {
            title = "整屏 \(pixelWidth) × \(pixelHeight)"
            subtitle = "单击或 ⏎ 截取全屏"
        } else {
            title = hoverWindow?.title ?? "窗口"
            subtitle = "\(pixelWidth) × \(pixelHeight)　单击或 ⏎ 截取该窗口"
        }

        var rows: [HUDBadge.Row] = [HUDBadge.Row(text: title)]
        if !subtitle.isEmpty {
            rows.append(HUDBadge.Row(text: subtitle,
                                     font: Design.Fonts.micro,
                                     ink: Design.TextInk.secondary))
        }
        if isDragging {
            rows.append(HUDBadge.Row(text: Self.dragHintText,
                                     font: Design.Fonts.micro,
                                     ink: Design.TextInk.tertiary))
        }
        // 量字、摆位、画框都在 `HUDBadge` 里 —— 预览压暗层那条角标用的是同一个函数。
        // 整屏候选上下都塞不下（选区就是整块屏），不夹回屏内标签会被裁没，
        // 而那是这个状态下唯一的文字反馈。
        HUDBadge.draw(rows, below: rect, in: bounds, context: context)
    }

    /// 提示条那句话。**唯一的一份**：自检的文案宽度量的就是这个常量，
    /// 在自检里再抄一份的话，改了这里的字而宽度检查还在量旧字 —— 那种绿是假的。
    ///
    /// 原来这条 116 字把 8 件事一次糊满屏幕，结果是每一条都记不住。静止态只需要知道
    /// 「怎么选、怎么定、怎么退」；修饰键那一组挪到选区角标上，等真的在拖的时候才说
    /// （见 `dragHintText`）。
    static let hintText = "移动鼠标选窗口　·　拖动选区域　·　⏎ 或单击截取　·　Esc 取消"

    /// 拖拽中挂在选区角标第三行的一组。**只在拖的时候画**：
    /// 提示条在 `mouseDown` 那一下就收掉了（这是对的，挡视线的东西该走），
    /// 可 ⇧ / ⌥ 恰恰是从这一秒开始才用得上的。
    ///
    /// 写「按住」而不是光一个符号：这两个是**持续键**，拖着的时候得一直压着，
    /// 按一下再松开是不生效的 —— 原来的写法看着像切换开关。
    static let dragHintText = "按住 ⇧ 锁成正方形　·　按住 ⌥ 从中心向外扩"

    private func drawHintIfNeeded(context: CGContext) {
        guard !isDragging else { return }
        let controllerWantsHint = controller?.drawsHint(on: screenRef) == true
        guard (controllerWantsHint || isHintFading), hintAlpha > 0.001 else { return }

        context.saveGState()
        context.setAlpha(hintAlpha)
        defer { context.restoreGState() }

        let text = Self.hintText
        let string = NSAttributedString(string: text, attributes: [
            .font: Design.Fonts.lead,
            .foregroundColor: NSColor.white
        ])
        let size = string.size()
        let box = NSRect(x: bounds.midX - size.width / 2 - 18,
                         y: bounds.maxY - size.height - 70,
                         width: size.width + 36,
                         height: size.height + 18)

        // 和工具栏 / 角标同一套 HUD 材质：提示条也是"压在真实内容上的浮层"，
        // 不该比它们更透、更灰。边缘补一圈 1pt 高光，白字在纯白窗口上也立得住。
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 10,
                          color: NSColor.black.withAlphaComponent(0.30).cgColor)
        context.setFillColor(Design.Ink.hud.cgColor)
        let path = CGPath(roundedRect: box, cornerWidth: Design.Radius.hud,
                          cornerHeight: Design.Radius.hud, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

        context.setStrokeColor(Design.Ink.hudEdge.cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()
        string.draw(at: NSPoint(x: box.minX + 18, y: box.minY + 9))
    }

    /// 提示条到点退场。只改这一条提示的透明度，不动压暗和候选框。
    fileprivate func fadeHintOut() {
        guard !isHintFading, hintAlpha > 0 else { return }
        isHintFading = true
        let duration = Motion.duration(0.18)
        guard duration > 0 else {
            hintAlpha = 0
            isHintFading = false
            needsDisplay = true
            return
        }

        let startedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (CACurrentMediaTime() - startedAt) / duration)
            self.hintAlpha = 1 - progress
            self.needsDisplay = true
            if progress >= 1 {
                timer.invalidate()
                self.hintFadeTimer = nil
                self.isHintFading = false
                self.hintAlpha = 0
            }
        }
        hintFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 离屏渲染自检用：把覆盖层摆成某个状态。
    ///
    /// 覆盖层是「每次截图都第一眼看到、却最难自查」的一层 —— 它铺满整屏、
    /// 只能截屏才能看见。给它一个可以直接摆状态的入口，才能在离屏里画出来看。
    func populateForSelfTest(hover: NSRect?, isDisplayCandidate: Bool,
                             drag: (start: NSPoint, at: NSPoint)?,
                             modifiers: NSEvent.ModifierFlags = []) {
        hoverTween?.invalidate()
        hoverTween = nil
        hoverRect = hover
        hoverPresentationRect = hover
        hoverIsDisplay = isDisplayCandidate
        hoverWindow = nil
        if let drag {
            // 走真实链路：⇧/⌥ 约束 → 夹进本屏 → 由两点确定矩形
            isDragging = true
            dragFromCenter = modifiers.contains(.option)
            anchor = drag.start
            current = clampedPoint(constrained(drag.at, from: drag.start, modifiers: modifiers))
        } else {
            isDragging = false
            anchor = nil
            current = nil
        }
        needsDisplay = true
    }

    /// 离屏渲染自检用：读排版后的选区矩形，用来断言 ⇧ / ⌥ 的几何行为。
    var selectionRectForSelfTest: NSRect? { selectionRect }

    /// 自检用：在视图坐标的 `point` 上**按下**（走的就是 `mouseDown` 那段状态），
    /// 再拖到 `other`，回报此刻的选区。
    ///
    /// 它要回答的问题是："那个看起来像手柄的东西，按下去真是手柄吗？"
    /// 覆盖层的答案永远是"按下点成了新选区的一个角" —— 因为这里压根没有手柄拖拽。
    /// 所以框上不许画任何暗示能抓的东西。
    func pressAtForSelfTest(_ point: NSPoint, thenDragTo other: NSPoint) -> NSRect? {
        beginDrag(at: point, option: false)
        current = other
        return selectionRect
    }

    /// 自检用：把选区框**单独**画到一张透明底位图上，量它到底画了什么。
    ///
    /// 为什么要透明底：真那一张压在桌面合成图上，而那块桌面左半是纯白的窗口 ——
    /// "框上有没有画白点"这种问题在混了背景的图里问不出答案（白的地方白点量不到，
    /// 灰的地方又像有白点）。单独画一遍，白色就只剩"框自己"这一个来源。
    /// 返回的图里，选区矩形摆在 (20, 20, rect.size)。
    static func renderFrameForSelfTest(rect: NSRect, active: Bool) -> CGImage? {
        let pad: CGFloat = 20
        let width = Int(rect.width + pad * 2), height = Int(rect.height + pad * 2)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        drawFrame(rect.offsetBy(dx: pad, dy: pad), context: context, active: active)
        return context.makeImage()
    }

    // MARK: 鼠标事件

    override func mouseMoved(with event: NSEvent) {
        refreshHover(atScreenPoint: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.hideHint()
        beginDrag(at: convert(event.locationInWindow, from: nil),
                  option: event.modifierFlags.contains(.option))
    }

    /// 按下那一下改的全部状态。**自检走的是这一个函数**，不是另写一份 ——
    /// 否则验的是"我以为按下会怎样"，不是"按下真的怎样"。
    private func beginDrag(at point: NSPoint, option: Bool) {
        // 拖拽一开始就停掉候选框的缓动：拖框必须逐点跟手，不能被上一段
        // 候选动画的计时器再重绘一帧。
        hoverTween?.invalidate()
        hoverTween = nil
        hoverPresentationRect = hoverRect
        anchor = point
        current = point
        isDragging = true
        dragFromCenter = option

        // 锁定此刻的候选：如果用户只是单击（松手时几乎没位移），就采用它
        pendingWindow = hoverWindow
        pendingIsDisplay = hoverIsDisplay
        pendingRect = hoverRect

        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let start = anchor else { return }
        dragFromCenter = event.modifierFlags.contains(.option)
        current = clampedPoint(constrained(convert(event.locationInWindow, from: nil),
                                            from: start, modifiers: event.modifierFlags))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging, let start = anchor else { return }
        dragFromCenter = event.modifierFlags.contains(.option)
        current = clampedPoint(constrained(convert(event.locationInWindow, from: nil),
                                           from: start, modifiers: event.modifierFlags))
        isDragging = false

        let rect = selectionRect ?? .zero
        let moved = rect.width >= Self.dragThreshold || rect.height >= Self.dragThreshold

        defer {
            anchor = nil
            current = nil
            needsDisplay = true
        }

        guard let screen = screenRef else {
            controller?.cancel()
            return
        }

        if moved {
            // 拖拽 → 区域截图
            guard rect.width >= 3, rect.height >= 3,
                  let global = screenRect(fromViewRect: rect) else {
                controller?.cancel()
                return
            }
            controller?.finish(.region(rectInScreenCoords: global, screen: screen))
            return
        }

        // 几乎没位移 → 单击，采用按下瞬间的候选（和 ⏎ 共用下面那一段判断）
        if let outcome = outcome(window: pendingWindow, isDisplay: pendingIsDisplay,
                                 viewRect: pendingRect) {
            controller?.finish(outcome)
        } else {
            controller?.cancel()
        }
    }

    /// 「采用这个候选」到底交出去什么。
    ///
    /// 鼠标单击和 ⏎ 走的是同一段判断 —— 两条路对同一个候选给出两种结果
    /// （一会儿按"那个窗口"截、一会儿按"一块区域"截）是查不出来的分家。
    private func outcome(window: SCWindow?, isDisplay: Bool, viewRect: NSRect?)
        -> SelectionOutcome? {
        guard let screen = screenRef else { return nil }
        let global = viewRect.flatMap { screenRect(fromViewRect: $0) }
        if let window { return .window(window, frameInScreenCoords: global ?? window.frame) }
        if isDisplay { return .display(screen) }
        guard let rect = global else { return nil }
        return .region(rectInScreenCoords: rect, screen: screen)
    }

    /// 覆盖层认的那些键都在这里落地。`keyDown` 和自检走的是同一个函数：
    /// 自检造不出真的 `NSEvent`，而"验的是另一份逻辑"等于没验。
    @discardableResult
    func apply(_ key: OverlayKey) -> Bool {
        switch key {
        case .cancel:
            controller?.cancel()
            return true
        case .fullscreen:
            guard let screen = screenRef else { return false }
            hoverRect = viewRect(fromScreenRect: screen.frame)
            hoverWindow = nil
            hoverIsDisplay = true
            needsDisplay = true
            return true
        case .adopt:
            guard let rect = hoverRect,
                  let outcome = outcome(window: hoverWindow, isDisplay: hoverIsDisplay,
                                        viewRect: rect) else { return false }
            controller?.finish(outcome)
            return true
        case .other:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if apply(Self.key(forKeyCode: Int(event.keyCode))) { return }
        super.keyDown(with: event)
    }

    // MARK: 自检用的那扇门

    /// 自检用：把一次**真的** `keyDown` 从窗口投进来，走生产那条路
    /// （`window.sendEvent` → firstResponder → `keyDown` → `apply`）。
    ///
    /// 为什么值得单独开这个口：`applyKeyForSelfTest` 是直接调判断那一步的，
    /// 它绿着只能证明"键映射与决策对"，证明不了"键进得来这个视图"。
    /// Esc 走的是 `OverlayWindow.cancelOperation`（响应链的另一条路），
    /// 所以"Esc 能用"带不出"⏎ 能用"。断点可能就在投递这一环：
    /// 窗口成不了 key、或者 firstResponder 不是这个视图。
    ///
    /// 投的是 `空格`：它不截屏、只把候选换成整屏，所以效果在 `hoverRect` 上看得见
    /// （⏎ 要经 controller，自检里不接真控制器，免得真去抓一次屏）。
    ///
    /// 三样分开返回，因为三种坏法要能分辨：没成 key / 键没落到本视图 / 落到了但状态没变。
    func deliverKeyForSelfTest(keyCode: Int)
        -> (keyWindow: Bool, landedHere: Bool, changed: Bool) {
        guard let window else { return (false, false, false) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self)
        let before = hoverRect
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: UInt16(keyCode))
        else { return (window.isKeyWindow, false, false) }
        window.sendEvent(event)
        return (window.isKeyWindow, window.firstResponder === self, hoverRect != before)
    }

    /// 自检用：把一次按键走完真实那条路，返回接住没有。
    @discardableResult
    func applyKeyForSelfTest(_ key: OverlayKey) -> Bool { apply(key) }
    /// 自检用：此刻的候选框。
    var hoverRectForSelfTest: NSRect? { hoverRect }
    /// 自检用：⏎ 会交出去的那个东西 —— 只看判断，不真的去截屏。
    var outcomeForSelfTest: SelectionOutcome? {
        outcome(window: hoverWindow, isDisplay: hoverIsDisplay, viewRect: hoverRect)
    }
    /// 自检用：此刻是不是整屏候选。
    var isDisplayCandidateForSelfTest: Bool { hoverIsDisplay }

    /// ⇧ 锁正方形（边长取位移更大的那条轴，和 Photoshop / Sketch 的画法一致）。
    /// ⌥ 不在这里处理：它改变的是"矩形怎么由两点确定"，见 `selectionRect`。
    private func constrained(_ point: NSPoint,
                             from anchor: NSPoint,
                             modifiers: NSEvent.ModifierFlags) -> NSPoint {
        var dx = point.x - anchor.x
        var dy = point.y - anchor.y
        guard dx != 0 || dy != 0 else { return point }

        if modifiers.contains(.shift) {
            let side = max(abs(dx), abs(dy))
            dx = dx >= 0 ? side : -side
            dy = dy >= 0 ? side : -side
        }
        return NSPoint(x: anchor.x + dx, y: anchor.y + dy)
    }

    /// 拖拽点限制在本屏内，避免拖到别的屏幕后选区横跨两块屏（暂不支持拼接）。
    private func clampedPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    // MARK: 坐标换算

    /// 屏幕坐标 → 本视图坐标。
    private func viewRect(fromScreenRect rect: CGRect) -> NSRect? {
        guard let window else { return nil }
        let inWindow = window.convertFromScreen(rect)
        return convert(inWindow, from: nil)
    }

    /// 本视图坐标 → 屏幕坐标。
    private func screenRect(fromViewRect rect: NSRect) -> CGRect? {
        guard let window else { return nil }
        let inWindow = convert(rect, to: nil)
        return window.convertToScreen(inWindow)
    }
}
