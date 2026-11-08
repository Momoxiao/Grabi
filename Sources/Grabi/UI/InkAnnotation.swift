import AppKit

/// 就地预览上的标注：画笔与形状。
///
/// 为什么画在预览面板上：截图的人九成是"截完就要在上面圈一下"，那一下必须
/// 发生在图还在眼前的地方。为标注专门开一次窗，等于让用户先做一次导航才敢说
/// "这里不对"。
enum Ink {

    /// 四种形状。**全部摆在工具栏上**，各占一段 —— 以前是一个按钮循环切四种，
    /// 第一下点下去切到的不是眼睛看到的那个，而且想画第四种要点三下。
    /// 现在点哪个就是哪个，`Ink.Shape.allCases` 的顺序就是按钮从左到右的顺序。
    enum Shape: CaseIterable {
        case rectangle, ellipse, arrow, line

        var symbol: String {
            switch self {
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .arrow: return "arrow.up.right"
            case .line: return "line.diagonal"
            }
        }

        var name: String {
            switch self {
            case .rectangle: return "矩形"
            case .ellipse: return "椭圆"
            case .arrow: return "箭头"
            case .line: return "直线"
            }
        }
    }

    enum Tool: Equatable {
        case pen
        case shape(Shape)

        var isShape: Bool {
            if case .shape = self { return true }
            return false
        }
    }

    /// 一条画完（或正在画）的标注。
    ///
    /// 坐标一律是**图内归一化**（0…1，y 向上），不是视图点：预览面板会被拖走、
    /// 改选区会换一张图，用视图坐标的话每一刀都得跟着重算；归一化坐标对
    /// "画在屏幕上"和"合成进图里"是同一份，两个去处不会一个对一个错。
    struct Stroke {
        var tool: Tool
        var points: [CGPoint]
        var color: NSColor
        /// 线宽，同样是图宽的归一化比例（见 `normalizedWidth`）。
        var width: CGFloat
    }

    /// 屏幕上 3pt 的笔，换成图内比例。
    ///
    /// 收在这里而不是各处写 3：画笔和形状必须一样粗，而"一样粗"这件事
    /// 一旦有两个出处就会分家。用户可以在颜色那一栏里改这个默认值（`InkLayer.screenWidth`），
    /// 但**改的是一处**，画笔和形状一起跟着变。
    static let onScreenWidth: CGFloat = 3

    /// 线宽那三档（屏幕 pt）。名字和值只在这里定义一次：菜单上的标签、
    /// 自检摆的那张表都从它读。
    static let widthChoices: [(name: String, points: CGFloat)] = [
        ("细", 2), ("中", onScreenWidth), ("粗", 5)
    ]

    /// 按住 ⇧ 拖动时给形状"上规矩"：矩形 / 椭圆锁成正方形，直线 / 箭头吸到 45° 的整数倍。
    ///
    /// 用的是截图覆盖层那个 ⇧ 的同一个意思（那边锁正方形）—— 一个键在两个地方
    /// 干两件不同的事，比让用户记两套修饰键好。
    ///
    /// ⚠️ 坐标是**图内归一化**的，而"正方形 / 45°"是眼睛看到的事：
    /// 一张 16:9 的图上归一化的 0.2×0.2 是个扁的。所以先换算到视觉空间
    /// （`aspect = 宽 / 高`，以高为单位）上规矩，再换算回去。
    /// 不带 `aspect` 的那版实现会在非正方形的图上把 ⇧ 变成一个"看着没生效"的键。
    static func constrained(first: CGPoint, to point: CGPoint, tool: Tool,
                            shift: Bool, aspect: CGFloat) -> CGPoint {
        guard shift else { return point }
        let dx = point.x - first.x, dy = point.y - first.y
        let safe = aspect > 0 ? aspect : 1
        switch tool {
        case .pen:
            // 画笔没有"第二个点"要对齐，自由圈画本来就是手抖的。
            return point
        case .shape(let shape):
            let vx = dx * safe, vy = dy          // 视觉空间里的增量
            let signX: CGFloat = vx < 0 ? -1 : 1
            let signY: CGFloat = vy < 0 ? -1 : 1
            switch shape {
            case .rectangle, .ellipse:
                let side = max(abs(vx), abs(vy))
                return CGPoint(x: first.x + signX * side / safe, y: first.y + signY * side)
            case .line, .arrow:
                let length = hypot(vx, vy)
                let step = Double.pi / 4
                let snapped = (atan2(vy, vx) / step).rounded() * step
                return CGPoint(x: first.x + cos(snapped) * length / safe,
                               y: first.y + sin(snapped) * length)
            }
        }
    }

    static func normalizedWidth(viewWidth: CGFloat,
                                screenWidth: CGFloat = onScreenWidth) -> CGFloat {
        guard viewWidth > 0 else { return 0 }
        return screenWidth / viewWidth
    }

    /// 归一化坐标 → 某个矩形里的点。
    static func denormalize(_ points: [CGPoint], in box: NSRect) -> [CGPoint] {
        points.map { NSPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }
    }

    /// 一条标注在给定矩形里的路径。形状由**按下点和当前点**两个角确定，
    /// 所以往哪个方向拖都是同一个矩形（这里负责翻正）。
    static func path(for stroke: Stroke, in box: NSRect) -> NSBezierPath? {
        let pts = denormalize(stroke.points, in: box)
        guard let first = pts.first else { return nil }
        let path = NSBezierPath()
        path.lineWidth = stroke.width * box.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch stroke.tool {
        case .pen:
            guard pts.count > 1 else { return nil }
            path.move(to: first)
            for point in pts.dropFirst() { path.line(to: point) }
            return path

        case .shape(let shape):
            guard let last = pts.last, pts.count > 1 else { return nil }
            let rect = NSRect(x: min(first.x, last.x), y: min(first.y, last.y),
                              width: abs(last.x - first.x), height: abs(last.y - first.y))
            switch shape {
            case .rectangle, .ellipse:
                // 矩形 / 椭圆的面积靠两个方向都有跨度；零宽或零高的框没有可画的边界，
                // 单击误触也不该留下一笔。
                guard rect.width > 0.5, rect.height > 0.5 else { return nil }
                if shape == .rectangle {
                    path.appendRect(rect)
                } else {
                    path.appendOval(in: rect)
                }
            case .line, .arrow:
                // 直线 / 箭头只需要**长度**，不需要宽高都非零：水平线和垂直线是
                // 最常画的两种（下划线、指引），以前共用矩形那条「宽高都 > 0.5」的
                // 门槛，导致它们被当成"没拖动"直接丢掉，用户怎么拖都画不出来。
                guard hypot(last.x - first.x, last.y - first.y) > 0.5 else { return nil }
                path.move(to: first)
                path.line(to: last)
                if shape == .arrow {
                    // 箭头那两条须：`angle + π` 是从尖头往回指，±0.45 张开。
                    // 须长跟着**线宽**走而不是跟着线长走 —— 线拉得再长也该是那个粗细的须，
                    // 按比例缩的话一根长箭头会拖出两把扇子。
                    let angle = atan2(last.y - first.y, last.x - first.x)
                    let barb = max(8, path.lineWidth * 4)
                    for spread in [Double.pi - 0.45, Double.pi + 0.45] {
                        path.move(to: last)
                        path.line(to: NSPoint(x: last.x + cos(angle + spread) * barb,
                                              y: last.y + sin(angle + spread) * barb))
                    }
                }
            }
            return path
        }
    }
}

/// 画在预览图上的那一层。
///
/// 只在**有工具按下时**才接管鼠标：平时 `hitTest` 一律放行，
/// 压在下面的文字层还能划选、图还能按住拖动面板。
final class InkLayer: NSView {

    private(set) var strokes: [Ink.Stroke] = []
    var tool: Ink.Tool? {
        didSet {
            guard tool != oldValue else { return }
            if tool == nil { inProgress = nil }
            needsDisplay = true
            // 光标那圈矩形是 AppKit 缓存的：改了工具不喊它重算，
            // 屏幕上就会一直顶着上一个光标（画着十字却拖得动面板，或反过来）。
            if let window { window.invalidateCursorRects(for: self) }
        }
    }
    var color: NSColor = .systemRed
    /// 当前线宽（屏幕 pt）。画笔和形状共用这一支"笔"，所以只有一个出处。
    var screenWidth: CGFloat = Ink.onScreenWidth
    /// 画完一笔 / 撤销 / 清空之后要重画别的东西（工具栏那颗「撤销」的可点状态）。
    var onChange: (() -> Void)?

    private var inProgress: Ink.Stroke?
    private var width: CGFloat = 0
    /// 「清空」撤掉的那一批。留着它，⌘Z 才能把整批还回来 —— 没有退路的动作不许存在。
    private var lastCleared: [Ink.Stroke]?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 选中工具之后，这块地方就是"在这里画"，不是"按住拖走"。
    ///
    /// 底下那张图平时报的是 `openHand`（能拖着面板走）。工具一选中，`hitTest`
    /// 改由这一层接下来，拖面板这件事当下确实做不了了 —— 那光标就不该继续画那只手。
    /// 画着能拖的手、按下去却在圈画，是这一层在撒谎（同一类事在选区那八颗点上栽过）。
    /// 这一层在当前状态下会主张哪个光标。nil = 不主张（让底下那张图的 `openHand` 说话）。
    ///
    /// 单独抽一个出处，而不是让自检去读 `window.cursorRects`：后者要窗口真走一趟
    /// `updateCursorRects`，而无头面板从没上过屏，读出来永远是空的 ——
    /// 一条按构造不可能变红的检查比没有检查更糟。
    var cursorForSelfTest: NSCursor? { tool.map(Self.cursor(for:)) }

    override func resetCursorRects() {
        guard let cursor = cursorForSelfTest else { return }
        addCursorRect(bounds, cursor: cursor)
    }

    /// 画笔是一枚跟着笔尖走的小圆圈，形状是十字。
    ///
    /// 为什么不都用十字：十字说的是"从这个角拖到那个角"，那正是形状那四个动作；
    /// 画笔没有第二个点，它要说的是"笔尖在这儿"。
    static func cursor(for tool: Ink.Tool) -> NSCursor {
        switch tool {
        case .pen: return penCursor
        case .shape: return .crosshair
        }
    }

    /// 画笔光标：一个空心小圆圈，中心就是笔尖落点。
    ///
    /// 热点放在正中间 —— 放偏了就是"看着圈的是这里、画上去差两像素"，
    /// 那种错只有真机上手能发现。
    static let penCursor: NSCursor = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let body = NSRect(x: 4, y: 4, width: 10, height: 10)
            NSColor.black.withAlphaComponent(0.55).setStroke()
            let halo = NSBezierPath(ovalIn: body.insetBy(dx: -1, dy: -1))
            halo.lineWidth = 3
            halo.stroke()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: body)
            ring.lineWidth = 1.5
            ring.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 自绘 + 自接鼠标的视图，AppKit 给不出任何有意义的默认朗读名。
        // 这一句必须说清"平时它不接管鼠标"，否则读屏用户会以为整张图都点不得。
        setAccessibilityLabel("标注层：选中画笔或形状之后，按住就能在这张图上画；"
                              + "没选工具时它不接管鼠标")
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("不支持归档加载") }

    /// 没选工具时一律放行：压在下面的文字层还要划选、图还要能按住拖走面板。
    override func hitTest(_ point: NSPoint) -> NSView? {
        tool == nil ? nil : self
    }

    /// 归一化到**这张图**：本视图铺满图片区域，所以 bounds 就是那张图的矩形。
    private func normalized(_ point: NSPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: (point.x - bounds.minX) / bounds.width,
                       y: (point.y - bounds.minY) / bounds.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard let tool else { return }
        let point = convert(event.locationInWindow, from: nil)
        width = Ink.normalizedWidth(viewWidth: bounds.width, screenWidth: screenWidth)
        inProgress = Ink.Stroke(tool: tool, points: [normalized(point)], color: color, width: width)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var stroke = inProgress else { return }
        let raw = normalized(convert(event.locationInWindow, from: nil))
        // ⇧ 上规矩：正方形 / 45°。放在**记点之前**，所以拖动手柄时看到的就是
        // 约束之后的形状，不是"松手才跳一下"。
        let point = Ink.constrained(first: stroke.points[0], to: raw, tool: stroke.tool,
                                    shift: event.modifierFlags.contains(.shift),
                                    aspect: bounds.height > 0 ? bounds.width / bounds.height : 1)
        switch stroke.tool {
        case .pen:
            stroke.points.append(point)
        case .shape:
            // 形状只记两个角：按下点 + 当前点。记一堆点的话，一个矩形会被画成
            // 一叠抖动的矩形（鼠标手抖是常态，矢量形状不该继承它）。
            if stroke.points.count > 1 { stroke.points.removeLast() }
            stroke.points.append(point)
        }
        inProgress = stroke
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let stroke = inProgress else { return }
        inProgress = nil
        // 单击一下没拖动：画笔留下一个点（画不出东西），形状两个角重合（也画不出）——
        // 两种都别收进历史，否则「撤销」要点两下才看得见反应。
        if stroke.points.count > 1, let box = boundsOrNull(),
           Ink.path(for: stroke, in: box) != nil {
            accept(stroke)
        }
        needsDisplay = true
    }

    /// 收下画完的一笔。**`mouseUp` 和自检的 `addStrokeForSelfTest` 都走这里**：
    /// "新画的一笔盖掉「清空」那批的还账机会"这件事只有一个出处，
    /// 自检那条才不会走进一条产品代码里根本不存在的分支。
    private func accept(_ stroke: Ink.Stroke) {
        strokes.append(stroke)
        lastCleared = nil
        onChange?()
    }

    private func boundsOrNull() -> NSRect? { bounds.width > 0 ? bounds : nil }

    /// 撤一步：**先还「清空」那一整批，再一笔一笔撤**。
    ///
    /// 顺序反过来就是坑：清空之后按 ⌘Z 只回来最后一笔，用户看到的是
    /// "撤销只撤回了十笔里的一笔"，而那十笔是他一次点击没的。
    func undo() {
        if let cleared = lastCleared {
            lastCleared = nil
            strokes = cleared
            onChange?()
            needsDisplay = true
            return
        }
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        onChange?()
        needsDisplay = true
    }

    func clearAll() {
        guard !strokes.isEmpty else { return }
        lastCleared = strokes
        strokes = []
        onChange?()
        needsDisplay = true
    }

    var canUndo: Bool { !strokes.isEmpty || lastCleared != nil }
    var canClear: Bool { !strokes.isEmpty }

    /// 自检用：直接放一笔进去（走的是和 `mouseUp` 收笔**同一个** `accept`）。
    /// 自检不模拟鼠标是因为它要量的是**合成结果**，手势那一层另有判据。
    func addStrokeForSelfTest(_ stroke: Ink.Stroke) {
        accept(stroke)
        needsDisplay = true
    }

    /// 把这一层画过的东西叠到给定矩形上。预览里画自己、合成进图时也调它 ——
    /// **两处共用一份**，否则"屏幕上看到的标注"和"存出去的那张"会各画各的。
    func strokePaths(in box: NSRect) -> [(color: NSColor, path: NSBezierPath)] {
        var done = strokes
        if let inProgress { done.append(inProgress) }
        return done.compactMap { stroke in
            Ink.path(for: stroke, in: box).map { (stroke.color, $0) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (color, path) in strokePaths(in: bounds) {
            color.setStroke()
            path.stroke()
        }
    }
}
