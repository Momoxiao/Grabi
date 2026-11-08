import AppKit

/// 「这张图来自哪块屏、倍率是多少」的唯一算法。
///
/// 以前散成两半：写盘时取 `NSScreen.main`，而那是**当前有键盘焦点**的那块屏，
/// 不是被截的那块 —— 在外接 1x 显示器上截一张图，会被打上 144dpi，
/// 插进文档就凭空放大一倍；角标算像素尺寸时用的是「选区中心落在哪块屏」，
/// 那个是对的。同一个问题两份写法，迟早漂移，所以收到一处。
enum ScreenGeometry {

    struct Display {
        var frame: NSRect
        var scale: CGFloat
    }

    static func displays(_ screens: [NSScreen] = NSScreen.screens) -> [Display] {
        screens.map { Display(frame: $0.frame, scale: $0.backingScaleFactor) }
    }

    /// 选区的倍率：中心点归哪块屏就用哪块；中心点谁也不在（跨屏拉选区、
    /// 或者那块屏已经拔掉）就按重叠面积取最大的一块；一块屏都没有退回 2。
    static func scale(of rect: NSRect, among displays: [Display]) -> CGFloat {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        if let hit = displays.first(where: { $0.frame.contains(center) }) {
            return hit.scale
        }
        var best: (area: CGFloat, scale: CGFloat)?
        for display in displays {
            let overlap = display.frame.intersection(rect)
            guard !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area { best = (area, display.scale) }
        }
        return best?.scale ?? 2
    }

    static func scale(of rect: NSRect) -> CGFloat {
        scale(of: rect, among: displays())
    }

    /// 写进文件头的 DPI。72 是「未标注」的默认值，倍率 2 就该是 144。
    static func dpi(scale: CGFloat) -> Int {
        Int((72 * scale).rounded())
    }
}
