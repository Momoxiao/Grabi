import AppKit

/// 识别结果的可视化层：极淡的整行底框提示"这里能选"，按住左键拖过去即按阅读
/// 顺序整段选中，选中区间用**琥珀色**画一条连续色带。
///
/// 刻意不画"每个字一个高亮框"、也不做 hover 高亮：那些是我们自己发明的观感，
/// 叠在原图上很吵。色带不加圆角、不描边，和文本选区一致。
///
/// 不用 macOS 的蓝色选中色：那个蓝和系统里"文字被选中"完全同色，压在截图原图上
/// 很难分清哪一层是 Grabi、哪一层是系统；琥珀色同样醒目，但不会和系统选择混淆。
///
/// 不做隐形文字层：NSTextView 的 glyph 位置要和我们识别出来的框严格对齐很难，
/// 对不齐的话拖选出来的色带会盖错地方，反而更糟。自绘色带位置来自识别框本身，
/// 天然对齐。
///
/// 命中分两级：先找精确落在字框里的，找不到就退到"同一行里最近的那个字"。
/// 后者很关键：字框紧贴笔画，点偏一点就落空，进而被当成"拖面板"，用起来会很难受。
///
/// 另一个关键设计是 `hitTest`：只有落在文字块上才接管鼠标事件，
/// 空白处一律放行给下层视图——这样"点空白拖动面板"和"点文字选字"不会打架。
class OCRHighlightView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("识别出的文字，按住拖动可划选复制")
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("不支持归档加载") }

    /// 每行文字 + 位置（归一化坐标，原点左下）。
    var lines: [OCRRecognizer.Line] = [] {
        didSet {
            rebuildUnits()
            selectedIndices.removeAll()
            dragAnchor = nil
            needsDisplay = true
        }
    }

    /// 选中内容变化时回调，传出当前选中的文本。
    var onSelectionChanged: ((String) -> Void)?

    /// 一个可选单元：某一行里的一个字 / 词。
    private struct SelectionUnit {
        let text: String
        /// 归一化坐标，原点左下。
        let box: CGRect
        /// 属于第几行。
        let line: Int
        /// 在该行内的序号，判断两个单元在原文里是否相邻时用。
        let positionInLine: Int
        /// 这个单元在原文里前面是否隔着空白。全选时靠它把词间的空格拼回来，
        /// 否则 "Grabi OCR probe" 会被拼成 "GrabiOCRprobe"，
        /// 用户就会觉得"全选复制出来的和看到的不一样"。
        let precededBySpace: Bool
    }

    private var units: [SelectionUnit] = []
    private var selectedIndices: Set<Int> = []
    /// 拖选的起点。拖动时按阅读顺序选中「起点 → 当前」之间的**整段**，
    /// 这样划得快也不会漏字——逐点收集只能拿到鼠标恰好经过的那几个字。
    private var dragAnchor: Int?

    /// 当前选中的文本（按行序、行内按字序拼接）。
    var selectedText: String {
        let picked = selectedIndices.sorted()
        guard !picked.isEmpty else { return "" }

        var result = ""
        var previous: Int?

        for index in picked {
            guard units.indices.contains(index) else { continue }
            let unit = units[index]

            if let previous {
                let before = units[previous]
                if unit.line != before.line {
                    result += "\n"
                } else if unit.precededBySpace {
                    // 原文里这个词前面就是空格，还原它
                    result += " "
                } else if unit.positionInLine == before.positionInLine + 1 {
                    // 原文里相邻且没有空白（汉字连排、词内字符），直接接上
                } else if let last = before.text.last, let first = unit.text.first,
                          isCJK(last) || isCJK(first) {
                    // 跳着选，但两端是中日韩：不加空格
                } else {
                    result += " "
                }
            }

            result += unit.text
            previous = index
        }
        return result
    }

    /// 全部文本。
    var allText: String { lines.map(\.text).joined(separator: "\n") }

    var hasSelection: Bool { !selectedIndices.isEmpty }
    var hasLines: Bool { !lines.isEmpty }

    /// 某个命中单元是不是已经在当前选区里。
    /// 右键复制前用它区分“点在已选文字上”和“点了另一处文字”。
    func isSelected(unit index: Int) -> Bool {
        selectedIndices.contains(index)
    }

    override var isFlipped: Bool { false }

    // MARK: 单元

    /// 把行展开成扁平的字 / 词序列。行拿不到字级坐标时退化成"整行一个单元"。
    private func rebuildUnits() {
        var flat: [SelectionUnit] = []
        for (lineIndex, line) in lines.enumerated() {
            let source = line.units.isEmpty
                ? [OCRRecognizer.Unit(text: line.text, boundingBox: line.boundingBox)]
                : line.units
            for (offset, unit) in source.enumerated() {
                flat.append(SelectionUnit(text: unit.text,
                                          box: unit.boundingBox,
                                          line: lineIndex,
                                          positionInLine: offset,
                                          precededBySpace: unit.precededBySpace))
            }
        }
        units = flat
    }

    // MARK: 坐标

    /// 归一化 box → 本视图坐标。`inset` 用来把命中范围放宽一点。
    private func rect(of unit: SelectionUnit, inset: CGFloat = 2) -> NSRect? {
        let rect = NSRect(x: unit.box.minX * bounds.width,
                          y: unit.box.minY * bounds.height,
                          width: unit.box.width * bounds.width,
                          height: unit.box.height * bounds.height)
        guard rect.width > 0.5, rect.height > 0.5 else { return nil }
        return rect.insetBy(dx: -inset, dy: -inset * 0.75)
    }

    /// 整行的框，用来画"这里能点"的提示底。
    private func lineRect(_ line: OCRRecognizer.Line) -> NSRect? {
        let box = line.boundingBox
        let rect = NSRect(x: box.minX * bounds.width,
                          y: box.minY * bounds.height,
                          width: box.width * bounds.width,
                          height: box.height * bounds.height)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return rect.insetBy(dx: -2, dy: -1.5)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !lines.isEmpty else { return }

        // 1) 整行的提示底：告诉用户"这块地方能点"，但不喧宾夺主
        for line in lines {
            guard let box = lineRect(line) else { continue }
            let path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.addPath(path)
            context.setFillColor(NSColor.systemOrange.withAlphaComponent(0.08).cgColor)
            context.fillPath()
        }

        // 2) 选中的区间：按行把选中单元的框合成**一条连续色带**。
        //    用琥珀色、不加圆角、不描边——观感是文本选区，但不和系统蓝撞色。
        //    位置直接来自识别框，所以色带一定盖在真正的字上。
        context.setFillColor(NSColor.systemOrange.withAlphaComponent(0.38).cgColor)
        for lineIndex in lines.indices {
            var band: NSRect?
            for index in units.indices where selectedIndices.contains(index) {
                guard units[index].line == lineIndex, let box = rect(of: units[index], inset: 0) else {
                    continue
                }
                band = band.map { $0.union(box) } ?? box
            }
            // 纵向撑开一点：色带要像"选中了一行字"，而不是紧贴笔画的窄条
            guard var band else { continue }
            band = band.insetBy(dx: -1, dy: -1.5)
            context.fill(band)
        }
    }

    // MARK: 命中

    /// 命中的单元序号。先精确命中，再退到"同一行里最近的那个字"。
    private func index(at point: NSPoint) -> Int? {
        var candidates: [(index: Int, distance: CGFloat)] = []

        for index in units.indices {
            guard let box = rect(of: units[index], inset: 1.5) else { continue }
            if box.contains(point) { return index }
            let dx = max(box.minX - point.x, 0, point.x - box.maxX)
            let dy = max(box.minY - point.y, 0, point.y - box.maxY)
            candidates.append((index, dx * dx + dy * dy))
        }

        // 落在整行范围内就取最近的那个字，避免"点偏一点就落空"
        for (lineIndex, line) in lines.enumerated() {
            guard let box = lineRect(line), box.insetBy(dx: -6, dy: -4).contains(point) else { continue }
            let nearest = candidates
                .filter { units[$0.index].line == lineIndex }
                .min { $0.distance < $1.distance }
            if let nearest { return nearest.index }
        }
        return nil
    }

    /// 只有落在文字块上才接管事件；空白处放行，交给下层处理拖动。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return index(at: local) != nil ? self : nil
    }

    /// 这个点落在哪个可选单元上（`nil` = 落在字块之外）。
    ///
    /// 右键落在字块里时要先知道"点的是哪一处"，才能照着那一处复制 ——
    /// 所以命中的这一步得能从外面问得到，自检也拿它量。
    func unitIndex(at point: NSPoint) -> Int? { index(at: point) }

    /// 预览面板浮出来的时候并不是 key window。若不接受 "first mouse"，
    /// 用户的第一下点击会被系统拿去激活窗口、**直接丢弃**——
    /// 表现就是"点文字块没反应，得点第二下才选中"。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 鼠标

    /// 划选文字用 I-beam，空白处（父视图）才是手掌。
    ///
    /// 这里**必须**给出自己的光标矩形：父视图 `ImagePreviewView` 给整片区域铺了
    /// `openHand`，没有这一层的话可选择的文字上也显示手掌，分不清哪里能划选。
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = index(at: point)
        selectedIndices = hit.map { [$0] } ?? []
        dragAnchor = hit
        needsDisplay = true
        onSelectionChanged?(selectedText)
    }

    /// 拖动时按**阅读顺序**选中「起点 → 当前」之间的整段。
    ///
    /// 早期实现是"鼠标经过哪个字就加哪个字"，划快了会漏——`mouseDragged`
    /// 的采样点很稀，中间的字根本不会被经过。整段选更符合文本选区的直觉，
    /// 也和 `selectedText` 的拼接规则（相邻直接连、跨行补换行）对得上。
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let anchor = dragAnchor, let current = index(at: point) else { return }
        let lo = min(anchor, current)
        let hi = max(anchor, current)
        guard selectedIndices != Set(lo...hi) else { return }
        selectedIndices = Set(lo...hi)
        needsDisplay = true
        onSelectionChanged?(selectedText)
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
        onSelectionChanged?(selectedText)
    }

    // MARK: 选择控制

    func selectAll() {
        selectedIndices = Set(units.indices)
        dragAnchor = nil
        needsDisplay = true
        onSelectionChanged?(selectedText)
    }

    func clearSelection() {
        selectedIndices.removeAll()
        dragAnchor = nil
        needsDisplay = true
        onSelectionChanged?(selectedText)
    }

    /// 把选区收缩成某一个单元（右键点在字块上时用）。
    ///
    /// 右键点的是"这一处"，那菜单里的「复制文字」就该复制这一点 ——
    /// 而不是上一次拖选留下的那一片。用户点哪儿、复制哪儿。
    func selectUnit(at index: Int) {
        guard units.indices.contains(index) else { return }
        selectedIndices = [index]
        dragAnchor = nil
        needsDisplay = true
        onSelectionChanged?(selectedText)
    }

    // MARK: 文本判定

    private func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,   // CJK 标点
             0x3040...0x30FF,   // 假名
             0x3400...0x4DBF,   // 扩展 A
             0x4E00...0x9FFF,   // 基本区
             0xF900...0xFAFF,   // 兼容汉字
             0xAC00...0xD7AF,   // 谚文
             0xFF00...0xFFEF:   // 全角
            return true
        default:
            return false
        }
    }
}
