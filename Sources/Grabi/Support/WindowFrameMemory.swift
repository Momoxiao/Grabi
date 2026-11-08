import AppKit

/// 窗口位置记忆：只记**左上角**，不记大小。
///
/// 两个反直觉但都要命的细节：
///
/// 1. **记左上角而不是 `frame.origin`。** AppKit 的窗口原点在**左下**，而设置窗口
///    的高度是按当前面板内容现算的（`showPane` 换页时会保持顶边不动、往下长）。
///    存左下原点的结果是：上次停在「快捷键」那页（更高），原点就更低；下次打开
///    落在「保存」那页（更矮），窗口会整体往下掉一截 —— 用户眼里就是"记错了位置"。
///
/// 2. **恢复之前必须问一句"这个位置现在还在屏幕上吗"。** 上次把窗口放在副屏上，
///    今天拔掉副屏再打开，窗口会落在一片不存在的坐标里：标题栏看不见、抓不着，
///    用户只会觉得"设置打不开了"。所以原点要能被现存某块屏幕的可见区接住，
///    接不住就退回居中。
enum WindowFrameMemory {

    /// 标题栏那一条「还抓得住」的高度：窗口顶部这块还在屏内，就算可达。
    private static let titleBarGrab: CGFloat = 28
    /// 贴屏幕边时留的余量，免得窗口顶到两块屏的接缝里。
    private static let edgeMargin: CGFloat = 16

    private static func key(_ name: String) -> String { "windowOrigin.\(name)" }

    /// 把窗口放回上次的位置；没存过、或存的位置已经不在任何屏幕上，就居中。
    /// 返回是否用上了存过的位置。
    ///
    /// `visibleFrames` 默认取真显示器，自检时传一套合成的进来。
    @discardableResult
    static func restore(_ window: NSWindow, name: String,
                        visibleFrames: [NSRect] = NSScreen.screens.map(\.visibleFrame)) -> Bool {
        guard let saved = read(name),
              let origin = visibleOrigin(x: saved.x, top: saved.top,
                                         size: window.frame.size, in: visibleFrames) else {
            window.center()
            return false
        }
        window.setFrameOrigin(origin)
        return true
    }

    /// 记下当前位置。关窗前和每次挪动后都调，退出时窗口还开着也不会漏。
    static func save(_ window: NSWindow, name: String) {
        let frame = window.frame
        UserDefaults.standard.set(["x": frame.minX, "top": frame.maxY], forKey: key(name))
    }

    /// 纯函数：给定「上次左上角 + 窗口大小 + 现在有哪些屏幕可见区」，
    /// 算出该把窗口放在哪个原点；接不住就返回 nil（调用方去居中）。
    ///
    /// 之所以抽成不吃 `NSScreen` 的版本：`NSScreen` 要真显示器才造得出来，
    /// 而"拔掉副屏之后别把窗口丢到不存在的坐标上"这条恰恰最需要能自动验。
    static func visibleOrigin(x: CGFloat, top: CGFloat, size: NSSize,
                              in visibleFrames: [NSRect]) -> NSPoint? {
        let grab = NSPoint(x: x + edgeMargin, y: top - titleBarGrab)
        guard let visible = visibleFrames.first(where: { $0.contains(grab) }) else { return nil }

        // 左右：整块塞得下就塞下，塞不下贴着左边（`clamp` 的退化分支）。
        let clampedX = clamp(x, low: visible.minX + edgeMargin,
                             high: visible.maxX - edgeMargin - size.width)
        // 上下：以**顶边**为准。标题栏必须一直露在可见区里 —— 窗口比屏幕还高时
        // 宁可底下溢出，也不能让用户抓不到它。按"整块都在屏内"夹会把顶边压到
        // 菜单栏底下，那是更糟的错。
        let topLimit = visible.maxY - edgeMargin
        let lowestTop = visible.minY + edgeMargin + min(size.height, topLimit - visible.minY - edgeMargin)
        let clampedTop = clamp(top, low: lowestTop, high: topLimit)

        return NSPoint(x: clampedX, y: clampedTop - size.height)
    }

    /// 窗口比屏幕还宽时 `high < low`，这时贴着左边放比乱弹好。
    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        high < low ? low : min(max(value, low), high)
    }

    private static func read(_ name: String) -> (x: CGFloat, top: CGFloat)? {
        guard let stored = UserDefaults.standard.dictionary(forKey: key(name)),
              let x = stored["x"] as? CGFloat,
              let top = stored["top"] as? CGFloat else { return nil }
        return (x, top)
    }
}
