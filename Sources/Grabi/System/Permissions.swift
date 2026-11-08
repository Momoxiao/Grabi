import AppKit
import CoreGraphics

/// 屏幕录制（Screen Recording）权限。
///
/// ScreenCaptureKit 与 CGWindowList 都受 TCC 管控；未授权时截出来的是壁纸 +
/// 空窗口，而不是报错，所以必须显式检查，否则用户会以为软件坏了。
///
/// ## 关于「明明授权了，还一直要权限」
///
/// TCC 的授权记录是**绑定代码签名**的。ad-hoc 签名（`codesign -s -`）的
/// designated requirement 里包含 cdhash，也就是说——**每重新编译一次，
/// 系统就认为这是一个全新的、从未授权过的 app**，于是重新索要权限。
///
/// 这也是为什么提示逻辑必须克制：
///   * 启动时最多提示一次，而且只在真正首次运行时；
///   * 主动申请有冷却时间，短时间内不重复；
///   * 截图流程本身**不弹窗**，只在菜单栏显示状态。
enum Permissions {

    private enum Key {
        static let promptCount   = "permissionPromptCount"
        static let lastPromptAt  = "permissionLastPromptAt"
        static let lastLaunchHad = "lastLaunchHadPermission"
        static let lastLaunchAt  = "lastLaunchAt"
        static let didOnboard    = "didPromptPermissionOnFirstRun"
    }

    /// 同一次会话里两次主动申请之间的最小间隔。
    private static let cooldown: TimeInterval = 600

    /// 是否已经拿到屏幕录制权限（只读检查，不会弹窗）。
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 主动申请权限。第一次调用会弹系统授权窗；已拒绝过则直接返回 false。
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 现在是否适合再弹一次提示（冷却 + 次数上限）。
    static func shouldPrompt() -> Bool {
        let count = UserDefaults.standard.integer(forKey: Key.promptCount)
        guard count < 3 else { return false }
        let last = UserDefaults.standard.double(forKey: Key.lastPromptAt)
        return Date().timeIntervalSince1970 - last > cooldown
    }

    private static func markPrompted() {
        let count = UserDefaults.standard.integer(forKey: Key.promptCount)
        UserDefaults.standard.set(count + 1, forKey: Key.promptCount)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.lastPromptAt)
    }

    /// 是否已经走过一次首次运行引导。
    static var didOnboardPermission: Bool {
        UserDefaults.standard.bool(forKey: Key.didOnboard)
    }

    static func markOnboarded() {
        UserDefaults.standard.set(true, forKey: Key.didOnboard)
    }

    /// 未授权时给一次明确提示；返回 true 表示可以继续。
    ///
    /// - Parameter forcePrompt: 跳过冷却检查（只用于用户主动点击「修复权限」）。
    /// - Parameter explains: 是否弹自己的说明窗。`false` 时只触发系统授权请求。
    ///
    /// 注意 `CGRequestScreenCaptureAccess()` 是**异步**的：调用后系统弹授权框，
    /// 函数立刻返回，此时 `hasScreenRecording` 多半还是 false。所以"系统框刚弹完
    /// 又紧接着弹自己的说明窗"是必然的，不是偶发——首次启动引导必须走 `explains: false`。
    @discardableResult
    static func ensureScreenRecording(interactive: Bool,
                                      forcePrompt: Bool = false,
                                      explains: Bool = true) -> Bool {
        if hasScreenRecording { return true }
        guard interactive else { return false }
        guard forcePrompt || shouldPrompt() else { return false }
        markPrompted()

        _ = requestScreenRecording()
        if hasScreenRecording { return true }
        guard explains else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = """
        Grabi 截图依赖系统的屏幕录制权限。

        请在「系统设置 › 隐私与安全性 › 屏幕与系统音频录制」中勾选 Grabi，\
        然后完全退出并重新打开它才会生效。

        如果列表里已经勾上却仍然无效，多半是旧记录失效了（重新编译会让签名变化，\
        系统会当作新 app）——点下面的「重置权限记录」清掉旧记录，再重新授权一次。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "重置权限记录")
        alert.addButton(withTitle: "稍后再说")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openScreenRecordingSettings()
        case .alertSecondButtonReturn:
            if resetScreenRecordingRecord() { presentResetDone() }
        default:
            break
        }
        return false
    }

    /// 跳到「系统设置 › 隐私与安全性 › 屏幕与系统音频录制」。
    static func openScreenRecordingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]
        let urls = candidates.compactMap { URL(string: $0) }
        SystemOpen.openFirst(urls, page: "隐私与安全性 › 屏幕与系统音频录制")
    }

    /// 清掉本 app 的屏幕录制授权记录，让系统下次重新询问。
    ///
    /// 用在"授权记录与实际签名对不上"的场景：系统设置里明明勾着，app 却始终
    /// 认为自己没权限。
    @discardableResult
    static func resetScreenRecordingRecord() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleID]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            Log.system.notice("已重置屏幕录制授权记录，退出码 \(process.terminationStatus)")
            UserDefaults.standard.set(0, forKey: Key.promptCount)
            return process.terminationStatus == 0
        } catch {
            Log.system.error("tccutil 执行失败: \(error.localizedDescription)")
            return false
        }
    }

    static func presentResetDone() {
        let alert = NSAlert()
        alert.messageText = "已清除旧的授权记录"
        alert.informativeText = """
        接下来请：

        1. 完全退出 Grabi
        2. 重新打开 Grabi
        3. 系统会重新弹出权限请求，这次勾选允许

        如果系统没有再弹，就到「系统设置 › 隐私与安全性 › 屏幕与系统音频录制」\
        里手动把 Grabi 加上。
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 启动状态记录
    //
    // 从终端跑 `--diagnose` 时，进程的 responsible process 是终端，
    // 权限判定会继承终端的授权，**不代表 GUI 启动时的真实状态**。
    // 所以在 GUI 启动时把真实状态记下来，供诊断读取。

    static func recordLaunchState() {
        UserDefaults.standard.set(hasScreenRecording, forKey: Key.lastLaunchHad)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.lastLaunchAt)
    }

    static var lastLaunchState: (hadPermission: Bool, at: Date)? {
        let timestamp = UserDefaults.standard.double(forKey: Key.lastLaunchAt)
        guard timestamp > 0 else { return nil }
        return (UserDefaults.standard.bool(forKey: Key.lastLaunchHad),
                Date(timeIntervalSince1970: timestamp))
    }
}
