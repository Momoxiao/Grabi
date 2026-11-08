import AppKit

/// 角标卡片宽度。要装得下「已保存 · 存到 ~/Pictures/Grabi · 已复制」这一整行，
/// 而且得留点余量 —— 系统开「更大字体」时字会变宽，卡得太死就会看到省略号。
let toastCardWidth: CGFloat = 360

/// 截图结果的浮动角标（右下角、几秒后自动淡出）。
///
/// 为什么需要它：静默截图（以及「不弹就地预览」的偏好）原本的反馈只有
/// **一声提示音**。响过之后文件躺在哪里、有没有真的存下来，用户完全不知道，
/// 只能去访达里翻 —— 成熟截图工具（CleanShot、Snipaste）都在这里给一个
/// 带缩略图的瞬时角标，点一下直接跳到文件。
///
/// 刻意做得很轻：不抢焦点（`nonactivatingPanel`）、不接收键盘、自动消失、
/// 同一时刻只有一个（新的替换旧的），绝不变成一个需要用户"处理"的弹窗。
final class ToastHUDController {

    static let shared = ToastHUDController()

    private var panel: ToastPanel?
    private var hideWorkItem: DispatchWorkItem?

    private let inset: CGFloat = 18
    private let cardWidth: CGFloat = toastCardWidth

    private init() {}

    /// - Parameters:
    ///   - detail: 次要说明（如「已保存 · 点击在访达中显示」）。
    ///   - onClick: 点击卡片时执行；nil 时卡片不响应点击。
    func show(title: String,
              detail: String? = nil,
              thumbnail: CGImage? = nil,
              screen: NSScreen? = nil,
              duration: TimeInterval = 3.4,
              onClick: (() -> Void)? = nil) {
        hideWorkItem?.cancel()

        let card = ToastCardView(title: title, detail: detail, thumbnail: thumbnail)
        card.onClick = onClick

        let size = NSSize(width: cardWidth,
                          height: max(56, card.fittingSize.height))
        card.frame = NSRect(origin: .zero, size: size)

        let panel = self.panel ?? makePanel(size: size)
        // 先记下它是不是正挂在屏幕上，再动 alpha。顺序反了的话，下面那个
        // `replacing` 会永远读到 0，换内容的角标就会重新从透明淡入。
        let replacing = panel.isVisible && panel.alphaValue > 0.01
        panel.contentView = card
        panel.setContentSize(size)
        self.panel = panel

        let target = screen ?? Self.screenUnderMouse()
        let targetOrigin = origin(for: panel.frame.size, in: target)
        // 新角标从下方 10pt 滑上来；已经是同一块角标换内容时只轻轻托一下，
        // 不再从透明重新淡入 —— 那样会在旧回执的位置闪一下。
        if replacing {
            panel.alphaValue = 1
            panel.setFrameOrigin(NSPoint(x: targetOrigin.x, y: targetOrigin.y - 4))
        } else {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: targetOrigin.x, y: targetOrigin.y - 10))
        }
        panel.orderFrontRegardless()

        Motion.run(duration: Design.Timing.settle, curve: Motion.Curve.enter) {
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(targetOrigin)
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// 窗口配置必须显式给齐：borderless 的 `NSPanel` 默认**仍然是不透明的**，
    /// 不设 `isOpaque = false` + 透明背景，圆角卡片后面会跟着一块灰色矩形；
    /// 而 `hidesOnDeactivate` 默认是 true，app 一失焦角标就凭空消失。
    private func makePanel(size: NSSize) -> ToastPanel {
        let panel = ToastPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        panel.isFloatingPanel = true
        // 进场完全由 `Motion` 控制；不要系统再叠一层默认窗口动画。
        panel.animationBehavior = .none
        panel.level = ShotLevels.toast
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false      // 窗口阴影是方形的，会从圆角卡片的四个角漏出来
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        return panel
    }

    func hide() {
        guard let panel else { return }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        self.panel = nil

        let current = panel.frame.origin
        Motion.run(duration: 0.18, curve: Motion.Curve.exit) {
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(NSPoint(x: current.x, y: current.y - 6))
        } completion: {
            panel.orderOut(nil)
            panel.contentView = nil
        }
    }

    private func origin(for size: NSSize, in screen: NSScreen?) -> NSPoint {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(x: visible.maxX - size.width - inset,
                       y: visible.minY + inset)
    }

    private static func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}

/// 角标窗口：不能成为 key，免得把焦点从预览面板或用户正在用的 app 手里抢走。
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 深色圆角卡片：缩略图 + 主标题 + 次要说明。
///
/// internal 是给离屏渲染自检用的（`UIRenderSelfTest` 要把它真的画出来看截断）。
final class ToastCardView: NSView {

    var onClick: (() -> Void)? {
        didSet {
            // tooltip 不能在 init 里算：`onClick` 是调用方在 `ToastCardView`
            // 初始化**之后**才挂上的，那时初值永远是 nil —— 于是可点的卡片
            // 永远没有「点击打开这张截图」这句提示，用户只知道它能看，不知道能点。
            toolTip = onClick == nil ? nil : "点击打开这张截图"
            window?.invalidateCursorRects(for: self)
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private var isHovering = false

    init(title: String, detail: String?, thumbnail: CGImage?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Design.Ink.hud.cgColor
        layer?.cornerRadius = Design.Radius.hud
        layer?.borderWidth = 1
        layer?.borderColor = Design.Ink.hudEdge.cgColor
        // 角标停三秒多，读屏用户更需要"内容一次报全"，而不是逐个标签去摸
        setAccessibilityLabel([title, detail].compactMap { $0 }.joined(separator: "，"))
        setAccessibilityRole(.group)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Design.Fonts.title
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let detailLabel = NSTextField(wrappingLabelWithString: detail ?? "")
        detailLabel.font = Design.Fonts.caption
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.68)
        // 说明行**允许折两行**。以前是单行 + 尾部截断，而最长的那几条文案
        // （首次运行的引导、带保存路径的结果反馈）实测有 300+pt —— 角标只停 2 秒，
        // 把它切成「先点菜单栏的 Grabi 图标授权屏…」等于这条信息根本没发出去。
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.isHidden = (detail ?? "").isEmpty

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let content = NSStackView(views: [text])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        // 没有缩略图时不该把它的 54+10 一起扣掉：那是白给的 64pt 宽度，
        // 正好是把引导文案从"放得下"推进"被截断"的那一段。
        let textWidth = thumbnail == nil ? toastCardWidth - 24 : toastCardWidth - 24 - 54 - 10
        detailLabel.preferredMaxLayoutWidth = textWidth

        NSLayoutConstraint.activate([
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth)
        ])

        if let thumbnail {
            let preview = NSImageView()
            preview.image = NSImage(cgImage: thumbnail,
                                    size: NSSize(width: thumbnail.width, height: thumbnail.height))
            preview.imageScaling = .scaleProportionallyUpOrDown
            preview.wantsLayer = true
            preview.layer?.cornerRadius = Design.Radius.chip
            preview.layer?.masksToBounds = true
            preview.setContentHuggingPriority(.required, for: .horizontal)
            content.insertArrangedSubview(preview, at: 0)
            preview.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                preview.widthAnchor.constraint(equalToConstant: 54),
                preview.heightAnchor.constraint(equalToConstant: 40)
            ])
        }

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持归档加载") }

    /// 可点的角标需要自己的悬停回执：光标变手形只是"能点"，卡面轻微提亮
    /// 才让整张卡片像一个可以按的东西。不可点的角标保持完全静止。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func setHovering(_ hovering: Bool) {
        guard onClick != nil, isHovering != hovering else { return }
        isHovering = hovering
        let base = Design.Ink.hud
        let target = hovering
            ? (base.blended(withFraction: 0.08, of: .white) ?? base)
            : base
        let edge = hovering
            ? NSColor.white.withAlphaComponent(0.24)
            : Design.Ink.hudEdge
        guard let layer else { return }

        Motion.animate(layer, keyPath: "backgroundColor",
                       from: layer.presentation()?.backgroundColor,
                       to: target.cgColor,
                       duration: Design.Timing.fade,
                       curve: Motion.Curve.move,
                       key: "toast.hover.background")
        Motion.animate(layer, keyPath: "borderColor",
                       from: layer.presentation()?.borderColor,
                       to: edge.cgColor,
                       duration: Design.Timing.fade,
                       curve: Motion.Curve.move,
                       key: "toast.hover.edge")
        layer.backgroundColor = target.cgColor
        layer.borderColor = edge.cgColor
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// 角标弹出来时 app 未必在前台：不接受 first mouse 的话，
    /// 用户第一下会被系统拿去激活窗口而丢掉，点不出文件。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard let onClick, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        // 先收掉当前角标，再执行点击动作。反过来的话，`onClick` 里打开失败会
        // 用 `ToastHUDController.show` 弹一条新的失败说明，紧接着这里那句
        // `hide()` 又把新角标收掉 —— 用户点了一下，失败原因一闪都没看见。
        ToastHUDController.shared.hide()
        onClick()
    }
}
