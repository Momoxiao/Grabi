import AppKit
import Carbon.HIToolbox

/// 一条快捷键的持久化描述。
///
/// 直接用 Carbon 的 keyCode + 修饰符位，好处是 `RegisterEventHotKey` 不需要
/// 「辅助功能」权限（比 NSEvent 全局监听省一次授权），且系统级生效。
struct HotKeySpec: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let none = HotKeySpec(keyCode: 0xFFFF_FFFF, modifiers: 0)

    /// 出厂默认组合。**只有这一份** —— 「读不到时的回退」和「恢复默认按钮」共用它。
    static let defaultCapture = HotKeySpec.make(Key.a, Mod.ctrl | Mod.opt)

    var isDisabled: Bool { keyCode == 0xFFFF_FFFF }

    static func make(_ keyCode: UInt32, _ carbonModifiers: UInt32) -> HotKeySpec {
        HotKeySpec(keyCode: keyCode, modifiers: carbonModifiers)
    }

    enum Key {
        static let a: UInt32 = UInt32(kVK_ANSI_A)
        static let s: UInt32 = UInt32(kVK_ANSI_S)
        static let d: UInt32 = UInt32(kVK_ANSI_D)
        static let w: UInt32 = UInt32(kVK_ANSI_W)
        static let z: UInt32 = UInt32(kVK_ANSI_Z)
        static let x: UInt32 = UInt32(kVK_ANSI_X)
        static let c: UInt32 = UInt32(kVK_ANSI_C)
        static let q: UInt32 = UInt32(kVK_ANSI_Q)
        static let three: UInt32 = UInt32(kVK_ANSI_3)
        static let four: UInt32 = UInt32(kVK_ANSI_4)
        static let five: UInt32 = UInt32(kVK_ANSI_5)
        static let six: UInt32 = UInt32(kVK_ANSI_6)
        static let space: UInt32 = UInt32(kVK_Space)
        static let ret: UInt32 = UInt32(kVK_Return)
        static let left: UInt32 = UInt32(kVK_LeftArrow)
    }

    enum Mod {
        static let cmd: UInt32   = UInt32(cmdKey)
        static let opt: UInt32   = UInt32(optionKey)
        static let ctrl: UInt32  = UInt32(controlKey)
        static let shift: UInt32 = UInt32(shiftKey)

        /// 默认修饰键组合：⌃⌥，几乎不和系统或常用 app 冲突。
        static let `default`: UInt32 = ctrl | opt
    }

    /// "⌃⌥A" 这种可读形式。
    var displayString: String {
        guard !isDisabled else { return "未设置" }
        var s = ""
        if modifiers & Mod.ctrl != 0 { s += "⌃" }
        if modifiers & Mod.opt != 0 { s += "⌥" }
        if modifiers & Mod.shift != 0 { s += "⇧" }
        if modifiers & Mod.cmd != 0 { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    /// Apple 的修饰键书写顺序：⌃⌥⇧⌘（`displayString` 就是按这个顺序拼的）。
    static let modifierGlyphs: [Character] = ["⌃", "⌥", "⇧", "⌘"]

    /// 在一段文案里找**修饰键顺序写反了**的地方，返回第一个坏样本；nil 表示干净。
    ///
    /// 为什么值得钉住：说明文字写 `⌘⇧4`、录制框里显示 `⇧⌘4`，用户会以为是两条不同的
    /// 快捷键 —— 而这套 UI 里唯一的"正确写法"是 `displayString` 生成的那一种。
    /// 手打出来的顺序错最容易出现在纯文字里（README 和设置面板都曾错过）。
    ///
    /// 只判**连在一起**的修饰键：`⌘C / ⇧⌘R` 各自成一串，互不影响；
    /// `⇧ 锁正方形，⌥ 从中心向外扩` 这种隔开的单键不参与，免得误报。
    static func modifierOrderViolation(in text: String) -> String? {
        var run: [Character] = []
        var firstBad: String?

        func rank(_ c: Character) -> Int? { modifierGlyphs.firstIndex(of: c) }
        func flush() {
            defer { run = [] }
            guard firstBad == nil, run.count >= 2 else { return }
            let ranks = run.compactMap(rank)
            // 严格递增：重复的 `⌘⌘` 同样不算写对。
            let increasing = zip(ranks, ranks.dropFirst()).allSatisfy(<)
            if !increasing { firstBad = String(run) }
        }

        for c in text {
            if rank(c) != nil { run.append(c) } else { flush() }
        }
        flush()
        return firstBad
    }

    private static func keyName(for code: UInt32) -> String {
        let map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩",
            UInt32(kVK_Escape): "⎋", UInt32(kVK_Tab): "⇥",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
            UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
            UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
            UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Backslash): "\\",
            UInt32(kVK_ANSI_Grave): "`"
        ]
        return map[code] ?? "Key\(code)"
    }

    /// 按了几个修饰键（⌃⌥⇧⌘ 里的几个）。
    var modifierCount: Int {
        var n = 0
        for mod in [Mod.cmd, Mod.opt, Mod.ctrl, Mod.shift] where modifiers & mod != 0 { n += 1 }
        return n
    }

    /// 主菜单项用的组合键（`keyEquivalent` + `keyEquivalentModifierMask`）。
    ///
    /// 只有能写成单个字符的键给得出来：字母、数字、`-` `[` `;` 这些符号、空格。
    /// ↩ ⎋ ⇥ 和四个方向键在 AppKit 里走的是私有码位，硬塞一个 "↩" 只会让菜单
    /// 看起来有快捷键、按下去什么都不派发 —— 那种假象比不显示更糟，所以给 nil，
    /// 菜单项照常可以点。
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard !isDisabled else { return nil }
        let name = Self.keyName(for: keyCode)
        let character: String
        if name == "Space" {
            character = " "
        } else if name.count == 1, name.allSatisfy(\.isASCII) {
            character = name.lowercased()
        } else {
            return nil
        }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & Mod.cmd != 0 { flags.insert(.command) }
        if modifiers & Mod.opt != 0 { flags.insert(.option) }
        if modifiers & Mod.ctrl != 0 { flags.insert(.control) }
        if modifiers & Mod.shift != 0 { flags.insert(.shift) }
        return (character, flags)
    }

    /// 刚录到组合键时框里该说什么「不行」，nil 表示可以接受。
    ///
    /// 少于两个修饰键一律拦下来：`RegisterEventHotKey` 对 ⌘C、⌃A 这种都返回
    /// noErr（实测），也就是**真的会抢下来** —— 挂上 ⌘C 之后所有 app 的复制就
    /// 没了，挂 ⌃A 会让每个文本框的行首快捷键失效。这种事故没有报错、也没有
    /// 日志，只能不接受。
    var modifierRejection: String? {
        modifierCount < 2 ? "再加一个修饰键（如 ⌃⌥）" : nil
    }

    /// macOS 自带截图占用的组合：⇧⌘3 / 4 / 5 / 6，以及多按 ⌃ 的「存到剪贴板」变体。
    ///
    /// 精确匹配修饰键：⌃⌥⇧4 这种不算是系统的那条，拦了就是误报。
    var conflictsWithSystemScreenshot: Bool {
        guard !isDisabled else { return false }
        let toFile = Mod.cmd | Mod.shift
        let toClipboard = toFile | Mod.ctrl
        guard modifiers == toFile || modifiers == toClipboard else { return false }
        return [UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4),
                UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6)].contains(keyCode)
    }

    /// 从键盘事件构造。这里只挡"一个修饰键都没有"（裸字母热键没法注册），
    /// 「至少要两个」那条在 `modifierRejection` 里，由录制控件在收下之前判。
    static func from(event: NSEvent) -> HotKeySpec? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= Mod.cmd }
        if flags.contains(.option)  { mods |= Mod.opt }
        if flags.contains(.control) { mods |= Mod.ctrl }
        if flags.contains(.shift)   { mods |= Mod.shift }

        guard mods != 0 else { return nil }
        return HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: mods)
    }
}

/// 全局热键注册中心。
///
/// 用 Carbon 的 `RegisterEventHotKey`：不需要辅助功能权限、不需要 Input Monitoring，
/// 也不依赖 app 是否在前台。它是目前 macOS 上做系统级热键开销最小的方式。
final class HotKeyCenter {

    typealias Handler = () -> Void

    private var handlers: [UInt32: Handler] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private let signature: OSType = 0x4C53_4854 // 'LSHT'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // 用 GetEventDispatcherTarget：菜单栏（LSUIElement）应用在没有 key window 时
        // 也能收到热键事件。
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, eventRef, userData -> OSStatus in
            guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(eventRef,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hotKeyID)
            guard err == noErr else { return err }

            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.fire(hotKeyID.id) }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)

        if status != noErr {
            Log.hotkey.error("InstallEventHandler 失败: \(status)")
        }
    }

    deinit {
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func fire(_ id: UInt32) {
        guard let handler = handlers[id] else { return }
        Log.hotkey.debug("触发热键 id=\(id)")
        handler()
    }

    /// 注册一条热键。
    ///
    /// ⚠ 返回 true 只代表"系统收下了这次注册"，**不代表这条快捷键没人用**。
    /// 实测：菜单栏里那个正在运行的 Grabi 持有 ⇧⌘X 与 ⌃⌥S 时，另起一个进程
    /// 再注册同样的组合仍然返回 noErr；只有同一进程里重复注册才会拿到 -9878。也就是说跨进程"撞车"是不会被报出来的 ——
    /// 真撞了的症状是按了没反应，而不是这里失败。所以那些一眼就会撞的组合
    /// （单修饰键、macOS 自带截图那几条）得在录制那头拦下来。
    @discardableResult
    func register(_ spec: HotKeySpec, handler: @escaping Handler) -> Bool {
        guard !spec.isDisabled else { return false }

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(spec.keyCode,
                                         spec.modifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)

        guard status == noErr, let ref else {
            Log.hotkey.error("注册 \(spec.displayString, privacy: .public) 失败: \(status)")
            return false
        }

        refs[id] = ref
        handlers[id] = handler
        Log.hotkey.info("注册热键 \(spec.displayString, privacy: .public)")
        return true
    }

    func unregisterAll() {
        for (_, ref) in refs {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        handlers.removeAll()
    }
}
