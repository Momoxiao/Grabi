import AppKit

/// 全 app 共用的视觉常量。
///
/// 为什么要有这个文件：五块界面是五个时期分别画的，同一个意思在代码里留着好几个数 ——
/// 角标画法是两份（覆盖层一份、预览压暗层一份，内边距一份 6 一份 5），HUD 底板是两份
/// （浮条黑 0.92、结果角标黑 0.82），圆角有 4/5/6/7/8/12 六种，字号 11 和 12 各出现十几次。
/// 用户说的"不统一"就是这些数字差落在屏幕上看得见的地方：截图遮罩 0.32、预览遮罩 0.45，
/// 于是松手那一下屏幕会自己再暗一档，像是换了个 app。
///
/// 这里只放**跨面共用**的东西。某一界面独有的尺寸（工具栏高 42、缩略图 54×40、
/// 结果栏宽 330）留在原地 —— 把它们也搬进来，这个文件就会变成没人敢改的杂物间。
enum Design {

    /// 圆角。四档，按"这块东西有多大"分。
    enum Radius {
        static let chip: CGFloat = 6      // 小胶囊：拖放提示、缩放倍率
        static let badge: CGFloat = 7     // 角标
        static let card: CGFloat = 8      // 卡片、图片
        static let hud: CGFloat = 12      // 浮条 / 结果角标那种大块
    }

    /// 压在真实内容上的那几层。
    enum Ink {
        /// 截图进行中的遮罩。**故意比 `dimFocus` 浅**：这时候用户还要隔着它判断屏幕上
        /// 的内容，深了就选不准。两档是设计，不是漂移 —— 所以各有一个名字。
        static let dimSelect = NSColor.black.withAlphaComponent(0.32)
        /// 截完之后的压暗（就地预览、调整选区覆盖层）。
        static let dimFocus = NSColor.black.withAlphaComponent(0.45)
        /// 角标底。
        static let badge = NSColor.black.withAlphaComponent(0.75)
        /// 浮条与结果角标的底。以前一份 0.92 一份 0.82，同一种东西两种深浅。
        static let hud = NSColor.black.withAlphaComponent(0.92)
        /// HUD 上那圈几乎看不见的描边：只负责把边界从背景里分出来。
        static let hudEdge = NSColor.white.withAlphaComponent(0.16)
        /// 细线外面那圈深晕（选区框、手柄描边共用）。
        static let halo = NSColor.black.withAlphaComponent(0.45)
    }

    enum Fonts {
        /// 浮条 / 角标 / 结果角标的主行。
        static let title = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        /// 截图时那条操作提示：它是这一屏上唯一要读清楚的一行字。
        static let lead = NSFont.systemFont(ofSize: 13, weight: .medium)
        /// 识别结果正文。
        static let content = NSFont.systemFont(ofSize: 13)
        static let body = NSFont.systemFont(ofSize: 12, weight: .medium)
        static let caption = NSFont.systemFont(ofSize: 11)
        static let captionBold = NSFont.systemFont(ofSize: 11, weight: .semibold)
        static let micro = NSFont.systemFont(ofSize: 10)
    }

    /// HUD 上文字的三档亮度。以前是散在各处的 `white.withAlphaComponent(0.8 / 0.65 / 0.9)`，
    /// 差 0.05 没人看得出，但同一层字在两个面上就是不一样灰。
    enum TextInk {
        static let primary = NSColor.white
        static let secondary = NSColor.white.withAlphaComponent(0.8)
        static let tertiary = NSColor.white.withAlphaComponent(0.65)
    }

    /// 细线：选区框、手柄描边、分隔条都用它。
    static let hairline: CGFloat = 1.5

    enum Space {
        static let tight: CGFloat = 3     // 角标行距
        static let gap: CGFloat = 6       // 同一组控件之间
        static let row: CGFloat = 8       // 表单行距、角标离选区的距离
        static let group: CGFloat = 16    // 分组之间、窗口边距
    }

    enum Timing {
        static let fade = 0.14
        static let rise = 0.2
    }
}

/// 一块圆角黑底 + 一到三行字。
///
/// **覆盖层的尺寸角标和预览压暗层那条走的是这一个函数。**以前是两份几乎一样的代码，
/// 内边距一份 9×6、一份 9×5，圆角都是 7，摆位规则各写一半（一份夹上下、一份夹左右）——
/// 于是同一个 app 里两种角标，而且修一处忘另一处是必然的。
enum HUDBadge {
    struct Row {
        let text: String
        var font = Design.Fonts.title
        var ink = Design.TextInk.primary
    }

    static let padding = NSSize(width: 9, height: 6)
    static let rowGap: CGFloat = Design.Space.tight
    /// 角标离它标注的那个矩形的距离。
    static let outsideGap: CGFloat = Design.Space.row
    /// 离屏幕边的最小距离。
    static let screenMargin: CGFloat = 6

    static func size(of rows: [Row]) -> NSSize {
        var width: CGFloat = 0, height: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let measured = measure(row)
            width = max(width, measured.width)
            height += measured.height + (index > 0 ? rowGap : 0)
        }
        return NSSize(width: width + padding.width * 2, height: height + padding.height * 2)
    }

    /// 摆在 `rect` 左下方外面；下方放不下就翻到上方；最后整块夹回屏内。
    static func draw(_ rows: [Row], below rect: NSRect, in bounds: NSRect,
                     context: CGContext) {
        guard !rows.isEmpty else { return }
        let boxSize = size(of: rows)
        var origin = NSPoint(x: rect.minX, y: rect.minY - boxSize.height - outsideGap)
        if origin.y < bounds.minY + screenMargin { origin.y = rect.maxY + outsideGap }
        // 角标比整块画布还宽 / 高时，`maxX - boxSize.width - margin` 会小于左边距。
        // 那种情况下 `min(max(...))` 会把原点推到画布外，整条文字从左边被裁掉；
        // 贴住左上角至少保证开头那几个字看得见（内容本身不做截断）。
        if boxSize.width > bounds.width - screenMargin * 2 {
            origin.x = bounds.minX + screenMargin
        } else {
            origin.x = min(max(origin.x, bounds.minX + screenMargin),
                           bounds.maxX - boxSize.width - screenMargin)
        }
        if boxSize.height > bounds.height - screenMargin * 2 {
            origin.y = bounds.minY + screenMargin
        } else {
            origin.y = min(max(origin.y, bounds.minY + screenMargin),
                           bounds.maxY - boxSize.height - screenMargin)
        }

        let box = NSRect(origin: origin, size: boxSize)
        context.setFillColor(Design.Ink.badge.cgColor)
        context.addPath(CGPath(roundedRect: box,
                               cornerWidth: Design.Radius.badge,
                               cornerHeight: Design.Radius.badge, transform: nil))
        context.fillPath()

        var lineTop = box.maxY - padding.height
        for row in rows {
            let measured = measure(row)
            lineTop -= measured.height
            attributed(row).draw(at: NSPoint(x: box.minX + padding.width, y: lineTop))
            lineTop -= rowGap
        }
    }

    private static func attributed(_ row: Row) -> NSAttributedString {
        NSAttributedString(string: row.text,
                           attributes: [.font: row.font, .foregroundColor: row.ink])
    }

    private static func measure(_ row: Row) -> NSSize { attributed(row).size() }
}
