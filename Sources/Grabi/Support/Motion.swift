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

    /// 用同一条曲线解释同一种动作。
    ///
    /// - `enter`：东西出现、展开。起步快、收尾慢，像 macOS 的浮层。
    /// - `move`：已经有东西在屏幕上，只改变位置 / 尺寸。比 enter 更克制。
    /// - `exit`：离开。比进入更快，避免用户等一个已经决定要消失的东西。
    enum Curve {
        static let enter = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.30, 1)
        static let move = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1)
        static let exit = CAMediaTimingFunction(controlPoints: 0.40, 0, 1, 1)
    }

    /// 过渡时长；系统要求减弱动效时返回 0（`animator()` 在 0 时长下等于直接落终值，
    /// `completionHandler` 照样会跑，所以调用点不需要分叉）。
    static func duration(_ value: TimeInterval) -> TimeInterval {
        isReduced ? 0 : value
    }

    /// 统一入口：一次设置时长和曲线，所有调用点别再各写一份默认 ease。
    static func run(duration: TimeInterval,
                    curve: CAMediaTimingFunction = Curve.enter,
                    animations: () -> Void,
                    completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = self.duration(duration)
            context.timingFunction = curve
            animations()
        }, completionHandler: {
            completion?()
        })
    }

    /// 让一块已经排好版的视图淡入，并可带一点点位移 / 缩放。
    ///
    /// 位移只走 `CALayer.transform`，不碰 frame 和约束：按钮、面板、设置页都能用，
    /// 不会在动画结束后把 Auto Layout 的账算歪。Reduce Motion 下直接落到终态。
    static func reveal(_ view: NSView,
                       offset: CGSize = .zero,
                       scale: CGFloat = 1,
                       duration: TimeInterval = Design.Timing.rise,
                       completion: (() -> Void)? = nil) {
        let length = self.duration(duration)
        guard length > 0 else {
            view.alphaValue = 1
            view.layer?.transform = CATransform3DIdentity
            completion?()
            return
        }

        view.wantsLayer = true
        guard let layer = view.layer else {
            view.alphaValue = 1
            completion?()
            return
        }

        let finalTransform = layer.transform
        let translation = CATransform3DMakeTranslation(offset.width, offset.height, 0)
        let scaling = CATransform3DMakeScale(scale, scale, 1)
        let startTransform = CATransform3DConcat(scaling, translation)

        view.alphaValue = 0
        layer.transform = startTransform

        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = NSValue(caTransform3D: startTransform)
        slide.toValue = NSValue(caTransform3D: finalTransform)
        slide.duration = length
        slide.timingFunction = Curve.enter
        layer.transform = finalTransform
        layer.add(slide, forKey: "motion.reveal.transform")

        run(duration: length, curve: Curve.enter) {
            view.animator().alphaValue = 1
        } completion: {
            completion?()
        }
    }

    /// 动一层 CALayer 的属性（阴影、颜色、位置），不替调用点决定时长曲线。
    static func animate(_ layer: CALayer,
                        keyPath: String,
                        from: Any?,
                        to: Any,
                        duration: TimeInterval,
                        curve: CAMediaTimingFunction = Curve.enter,
                        key: String? = nil) {
        let length = self.duration(duration)
        guard length > 0 else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = length
        animation.timingFunction = curve
        layer.add(animation, forKey: key ?? keyPath)
    }
}
