import AppKit

/// 动效开关：统一尊重系统的「减弱动态效果」。
///
/// 为什么要有这一层：淡入淡出和位移动画在这个软件里到处都在用
/// （预览面板、工具栏换档、压暗层、结果角标、设置面板换页）。开了 Reduce Motion 的人
/// ——前庭障碍患者，也包括大量只是讨厌"界面在动"的用户——应该看到
/// **同样的状态变化，只是没有过渡**。逐个调用点各写各的 if 一定会漏，
/// 所以只把"时长"这一个数收进来：动画结构、completionHandler 的时序都不变。
enum Motion {

    static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 过渡时长；系统要求减弱动效时返回 0（`animator()` 在 0 时长下等于直接落终值，
    /// `completionHandler` 照样会跑，所以调用点不需要分叉）。
    static func duration(_ value: TimeInterval) -> TimeInterval {
        isReduced ? 0 : value
    }
}
