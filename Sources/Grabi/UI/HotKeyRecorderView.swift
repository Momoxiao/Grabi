import AppKit

/// 快捷键录制控件。
///
/// 点击后进入录制态，直接按键即可捕获。要求至少带一个修饰键——注册一个裸字母
/// 热键会抢走全局输入，那种设计是要挨骂的。
final class HotKeyRecorderView: NSView {

    var spec: HotKeySpec = .none {
        didSet { needsDisplay = true }
    }

    /// 唯一的提交通道。以前这里还并着一条 `actionTarget` + `actionSelector`
    /// 的字符串式 target/action（`perform` 的返回值被丢掉）：控件弱引用着目标、
    /// 选择器是拼出来的字符串，任何一环断了都**不会有任何反应** —— 框里那行字
    /// 已经换成新组合了，偏好里却还是旧的，热键也就从来没换过。闭包是类型的，
    /// 接不上就编译不过，少一种静默失效。
    var onChange: ((HotKeySpec) -> Void)?

    private var isRecording = false
    private var isHovering = false
    private var trackingAreaRef: NSTrackingArea?
    private var rejectHint: String?
    private var rejectHintReset: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }
    /// 170 不是随手写的：录制态那句「按下组合键　·　Esc 取消」实测 137pt，
    /// 原先的 150 只剩 1pt 呼吸，看着就是顶到边框。自检每次量一遍这个数字。
    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 26) }

    /// 框里的字统一用这个字体：自检要按它量「这句话塞不塞得进框」，
    /// 写两处字号早晚会和真实绘制对不上。
    static let hintTextFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// 一个修饰键都没按时框里的说法（和 `modifierRejection` 一样进宽度表，
    /// 免得自检量的是手抄的旧文案）。
    static let noModifierHint = "至少加一个修饰键"

    /// 录制态此刻该显示什么。绘制和自检共用一个来源，免得自检量的是另一套文案。
    static func boxText(recording: Bool, spec: HotKeySpec, rejectHint: String?) -> String {
        if recording { return rejectHint ?? "按下组合键　·　Esc 取消" }
        if spec.isDisabled { return "点击设置（未启用）" }
        return spec.displayString
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)

        let fill: NSColor
        if isRecording {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.16)
        } else if isHovering {
            fill = NSColor.controlBackgroundColor.blended(withFraction: 0.08, of: .labelColor) ?? .controlBackgroundColor
        } else {
            fill = .controlBackgroundColor
        }
        fill.setFill()
        path.fill()

        let borderColor: NSColor
        if rejectHint != nil {
            borderColor = .systemOrange
        } else {
            borderColor = isRecording ? .controlAccentColor : .separatorColor
        }
        borderColor.setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let text = Self.boxText(recording: isRecording, spec: spec, rejectHint: rejectHint)
        let color: NSColor
        if rejectHint != nil {
            color = .systemOrange
        } else if isRecording {
            color = .controlAccentColor
        } else {
            color = spec.isDisabled ? .tertiaryLabelColor : .labelColor
        }
        let string = NSAttributedString(string: text, attributes: [
            .font: Self.hintTextFont,
            .foregroundColor: color
        ])
        let size = string.size()
        string.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                y: bounds.midY - size.height / 2))
    }

    // MARK: 交互

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // 「按 Delete 清空」这条没人能猜到，不写进 tooltip 就等于没有
        toolTip = "点击后按下新组合键（至少两个修饰键，⌃⌥ 最稳）；按 Delete 清空、Esc 取消"
        setAccessibilityLabel("快捷键设置")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        if !isRecording { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {          // Esc 放弃
            stopRecording()
            return
        }

        // Delete / Backspace：清空这条热键（置为停用）
        if event.keyCode == 51 || event.keyCode == 119 {
            spec = .none
            stopRecording()
            onChange?(spec)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isEmpty, let captured = HotKeySpec.from(event: event) else {
            showRejectHint(Self.noModifierHint)
            return
        }
        // 单修饰键（⌘C、⌃A、⌥3…）会被系统"成功"注册，然后把所有 app 的这条
        // 快捷键抢走。不拦下来等到出事是没人会知道的。
        if let why = captured.modifierRejection {
            showRejectHint(why)
            return
        }

        spec = captured
        stopRecording()
        onChange?(captured)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording() }
        return super.resignFirstResponder()
    }

    private func startRecording() {
        isRecording = true
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    private func stopRecording() {
        isRecording = false
        rejectHint = nil
        rejectHintReset?.cancel()
        rejectHintReset = nil
        needsDisplay = true
        window?.makeFirstResponder(nil)
    }

    /// 按了不合规的组合时**不要响提示音**：那声"哔"只表达了"不行"，
    /// 而框里那行字可以直接说清楚"怎么才行"，而且不打断录制 ——
    /// 用户接着按一个带修饰键的组合就能成，不用重新点一次。
    private func showRejectHint(_ message: String) {
        rejectHint = message
        needsDisplay = true
        rejectHintReset?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rejectHint = nil
            self?.needsDisplay = true
        }
        rejectHintReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    // MARK: - 自检接缝

    struct RecordedResult {
        /// 录制是否结束：true = 这条被收下了（或被 Delete/Esc 取消），false = 被拦在框里，还能继续按
        let stopped: Bool
        let spec: HotKeySpec
        let hint: String?
    }

    var rejectHintForSelfTest: String? { rejectHint }
    var isRecordingForSelfTest: Bool { isRecording }

    /// 喂一条真实的 keyDown 走完整路径。自检用的是游离控件（不接 onChange），
    /// 所以不会写用户的偏好、也不会弹模态框。
    @discardableResult
    func recordForSelfTest(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> RecordedResult {
        if !isRecording { startRecording() }
        let event = NSEvent.keyEvent(with: .keyDown,
                                     location: .zero,
                                     modifierFlags: modifiers,
                                     timestamp: 0,
                                     windowNumber: 0,
                                     context: nil,
                                     characters: "x",
                                     charactersIgnoringModifiers: "x",
                                     isARepeat: false,
                                     keyCode: UInt16(keyCode))
        if let event { keyDown(with: event) }
        return RecordedResult(stopped: !isRecording, spec: spec, hint: rejectHint)
    }
}
