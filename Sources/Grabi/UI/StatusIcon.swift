import AppKit

/// 菜单栏那枚图标：四角取景框 + 中心快门环。
///
/// 为什么不用 `camera.viewfinder`：那枚符号是公共货架上的，截图类 app 一半在用它，
/// 装在菜单栏上认不出是谁；而 Grabi 的图形语言就是「取景框里的快门」——
/// 四条括号对应截图选区，中心的镜头环对应 app 图标里的光圈。
///
/// 三份状态共用同一副括号，只换中心那点东西。以前"闪一下"是换成一枚
/// `checkmark.circle.fill`：整枚符号换掉读起来像换了个 app，
/// 而不是"这一下拍到了"。
enum StatusIcon {

    enum State {
        case normal, flashed, warning

        var readingName: String {
            switch self {
            case .normal: return "Grabi 截图"
            case .flashed: return "Grabi：这一张拍到了"
            case .warning: return "Grabi：缺少屏幕录制权限"
            }
        }
    }

    /// 画布边长。菜单栏高约 22，符号的视觉高落在 14~16 之间最顺眼。
    static let side: CGFloat = 16
    /// 括号那一方框离画布边的距离 —— 框正好 `side - 2*inset` 见方。
    static let inset: CGFloat = 2.35
    /// 一条臂的长度。**比例按这块画布单独定过**：照搬覆盖层那条 `minSide × 0.2`
    /// 在这儿只会得到 2.4pt 的臂，比笔画本身还短，四个角糊成四个点。
    /// 唯一的硬约束写在下面那条 `arm > stroke` 的自检里：臂必须长过一笔的宽。
    static let arm: CGFloat = 3.7
    /// 笔画宽度用的就是全 app 那根细线。
    static let stroke: CGFloat = Design.hairline
    /// 中心的镜头环比外框轻一档，避免 16pt 下中心和四角抢重量。
    static let markStroke: CGFloat = 1.25

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            for path in brackets(in: rect) {
                path.lineWidth = stroke
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            mark(state, in: rect)
            return true
        }
        // 模板图：菜单栏自己按浅/深底和"是否用强调色"解算颜色。
        image.isTemplate = true
        image.accessibilityDescription = state.readingName
        return image
    }

    /// 四条 L 形括号。几何单独一个函数，自检数的是**同一份**路径。
    static func brackets(in rect: NSRect) -> [NSBezierPath] {
        let box = rect.insetBy(dx: inset, dy: inset)
        let lengths: [(x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat)] = [
            (box.minX, box.maxY, 1, -1),   // 左上
            (box.maxX, box.maxY, -1, -1),  // 右上
            (box.minX, box.minY, 1, 1),    // 左下
            (box.maxX, box.minY, -1, 1)    // 右下
        ]
        return lengths.map { corner in
            let path = NSBezierPath()
            let origin = NSPoint(x: corner.x, y: corner.y)
            path.move(to: origin)
            path.line(to: NSPoint(x: origin.x + corner.dx * arm, y: origin.y))
            path.move(to: origin)
            path.line(to: NSPoint(x: origin.x, y: origin.y + corner.dy * arm))
            return path
        }
    }

    /// 括号中间那点东西：常态 = 一枚空的镜头环；拍到 = 环心亮起；
    /// 缺权限 = 一个感叹号。
    private static func mark(_ state: State, in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        switch state {
        case .normal:
            let radius: CGFloat = 2.25
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius,
                                                   y: center.y - radius,
                                                   width: radius * 2,
                                                   height: radius * 2))
            ring.lineWidth = markStroke
            ring.lineJoinStyle = .round
            ring.stroke()
        case .flashed:
            let radius: CGFloat = 2.25
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius,
                                                   y: center.y - radius,
                                                   width: radius * 2,
                                                   height: radius * 2))
            ring.lineWidth = markStroke
            ring.stroke()

            // 环心填到几乎接上镜圈：轮廓仍是同一枚图标，但"拍到了"能在一眼之内
            // 和常态分开。旧版 1.35pt 的点在菜单栏里只多出两三个像素，实机上像没变。
            let dot: CGFloat = 1.75
            NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2,
                                        y: center.y - dot / 2,
                                        width: dot,
                                        height: dot)).fill()
        case .warning:
            let bar = NSRect(x: center.x - markStroke / 2, y: center.y - 0.35,
                             width: markStroke, height: 4.3)
            let path = NSBezierPath(roundedRect: bar,
                                    xRadius: markStroke / 2,
                                    yRadius: markStroke / 2)
            path.fill()
            let dot: CGFloat = 1.55
            NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: center.y - 3.35,
                                        width: dot, height: dot)).fill()
        }
    }
}
