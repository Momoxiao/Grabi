import AppKit
import ServiceManagement

/// 开机自启 + 后台保活。
///
/// 两条通道，自动选择，**互斥**（绝不会同时装，否则会启动两个实例）：
///
/// 1. **SMAppService**（macOS 13+，Apple 官方后台项 API）
///    - `mainApp`           → 注册为登录项，只做「登录时启动」
///    - `agent(plistName:)` → 注册 bundle 内的 LaunchAgent，能表达「崩溃后重启」
///    由系统守护进程托管，不需要 `launchctl bootstrap` 权限。
///
/// 2. **手写 LaunchAgent**（`~/Library/LaunchAgents/*.plist`）兜底。
///
/// 关于保活语义有个坑：如果用 `KeepAlive = true`，用户从菜单点「退出」会被
/// launchd 立刻拉起来，体验极差。所以统一用 `KeepAlive = { SuccessfulExit = false }`：
/// 只有**异常退出（崩溃）**才重启，用户主动退出（exit 0）就真的退出。
final class AutoStartManager {

    static let shared = AutoStartManager()

    private let label = "com.momoxiao.grabi"
    private let throttleSeconds = 5

    /// bundle 内保活 agent 的 plist 文件名。
    ///
    /// 只保留一份：`RunAtLoad = true` + `KeepAlive = { SuccessfulExit = false }`。
    /// 试过再放一份 `RunAtLoad = false` 的"非常驻保活"版本，但 SMAppService 对
    /// 同一个 bundle 只会登记一个 agent，第二份 plist 永远停在 `notFound`。
    /// 而且语义上「保活」本来就以「程序在运行」为前提，所以收敛成"开保活 = 常驻"。
    private let keepAlivePlistName = "com.momoxiao.grabi.keepalive.plist"

    /// 记录"上次成功注册时的二进制指纹"。
    ///
    /// SMAppService 会把后台项的**代码签名**一并登记到系统的 BTM 数据库里。
    /// 之后如果二进制被重新编译（ad-hoc 签名的 cdhash 变了），登记信息就和实际
    /// 签名对不上，系统会在拉起进程的一瞬间直接击杀：
    ///
    ///     signal: SIGKILL (Code Signature Invalid)
    ///     indicator: Launch Constraint Violation
    ///
    /// 现象是"进程启动即消失、没有崩溃栈、没有任何提示"，极难排查。
    /// 所以留个指纹，二进制换了就自动重新注册一次。
    private let fingerprintKey = "autoStartBinaryFingerprint"

    private var binaryFingerprint: String {
        guard let url = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else {
            return "unknown"
        }
        return "\(size)-\(Int(modified.timeIntervalSince1970))"
    }

    private func recordFingerprint() {
        UserDefaults.standard.set(binaryFingerprint, forKey: fingerprintKey)
    }

    /// app 是否位于标准应用目录。
    ///
    /// SMAppService 登记的进程带一条 launch constraint，**要求可执行文件位于
    /// `/Applications` 或 `~/Applications` 下**。放在别处（比如某个项目目录里），
    /// 系统拉起时会直接击杀，`launchctl` 显示 `job state = spawn failed,
    /// last exit code = 78 (EX_CONFIG)`。
    var isInStandardLocation: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let home = NSHomeDirectory()
        return path.hasPrefix("/Applications/") || path.hasPrefix("\(home)/Applications/")
    }

    var locationWarning: String? {
        // 过去这里还要求 `activeMechanism != .none`，于是"没登记 + 不在标准目录"这种
        // 最该提醒的情况反而一句提示都没有（登记成功了才提示）。
        guard !isInStandardLocation else { return nil }
        return "Grabi 当前不在 ~/Applications 或 /Applications 下，系统会拒绝自动启动它。"
    }

    /// 已经注册、但还等用户在「系统设置 › 通用 › 登录项与扩展」里点确认。
    var needsUserApproval: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return keepAliveStatus == .requiresApproval || loginItemStatus == .requiresApproval
    }

    /// 跳到「系统设置 › 通用 › 登录项与扩展」。
    /// 注册成功但状态是 `requiresApproval` 时，只有用户在这一页点一下才算数。
    static func openLoginItemsSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LoginItems"
        ]
        let urls = candidates.compactMap { URL(string: $0) }
        SystemOpen.openFirst(urls, page: "登录项")
    }

    /// 「运行」面板那一行的结论：怎么说、要不要醒目、给什么出路。
    ///
    /// 以前只是把状态原样拼成一行灰字。两个开关都勾着、系统却根本没登记时，
    /// 界面仍然用陈述语气写在最不起眼的一行里，也没有任何可点的出路 ——
    /// 而同一个面板往下两行的「屏幕录制权限」已经是正确做法（橙色「未授权」+ 修复按钮）。
    /// 用户要的和不成立的事实对不上，就得变橙并且给一键，所以判据收在这个纯函数里。
    struct RunStateAdvisory: Equatable {
        enum Action: Equatable { case none, reRegister, openLoginItems }
        var text: String
        var isWarning: Bool
        var action: Action

        var actionTitle: String? {
            switch action {
            case .none:          return nil
            case .reRegister:    return "重新登记"
            case .openLoginItems: return "打开登录项设置"
            }
        }
    }

    static func advisory(wanted: Bool,
                         mechanism: Mechanism,
                         statusText: String,
                         needsApproval: Bool,
                         locationWarning: String?) -> RunStateAdvisory {
        let head = "当前机制：\(mechanism.rawValue)　·　\(statusText)"
        guard wanted else {
            // 没要求自启：机制未启用只是陈述，不该吓唬人。
            return .init(text: head, isWarning: false, action: .none)
        }
        if let warning = locationWarning {
            // 不在标准目录时给按钮没用（得用户自己把 app 拖过去），只能把话说响。
            return .init(text: head + "\n⚠︎ \(warning)请移到「应用程序」后再开启。",
                         isWarning: true, action: .none)
        }
        if needsApproval {
            return .init(text: head + "\n⚠︎ 还差你在系统设置里点一下确认。",
                         isWarning: true, action: .openLoginItems)
        }
        if mechanism == .none {
            return .init(text: head + "\n⚠︎ 开关已开，但系统没有登记；重启后不会自动启动。",
                         isWarning: true, action: .reRegister)
        }
        return .init(text: head, isWarning: false, action: .none)
    }

    private init() {}

    // MARK: - 状态

    enum Mechanism: String {
        case none           = "未启用"
        case keepAliveAgent = "后台项"
        case loginItem      = "登录项"
        case manualPlist    = "LaunchAgent"
    }

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    var isManualPlistInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @available(macOS 13.0, *)
    private var loginItemStatus: SMAppService.Status { SMAppService.mainApp.status }

    @available(macOS 13.0, *)
    private var keepAliveStatus: SMAppService.Status {
        SMAppService.agent(plistName: keepAlivePlistName).status
    }

    /// `.enabled` 和 `.requiresApproval` 都算"已经挂上了"——后者只是等用户点一下确认。
    @available(macOS 13.0, *)
    private func isArmed(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    var activeMechanism: Mechanism {
        if isManualPlistInstalled { return .manualPlist }
        if #available(macOS 13.0, *) {
            if isArmed(keepAliveStatus) { return .keepAliveAgent }
            if isArmed(loginItemStatus) { return .loginItem }
        }
        return .none
    }

    var statusDescription: String {
        if isManualPlistInstalled {
            return "已安装"
        }
        if #available(macOS 13.0, *) {
            let status = isArmed(keepAliveStatus) ? keepAliveStatus : loginItemStatus
            switch status {
            case .enabled:          return "已启用"
            case .requiresApproval: return "等待你在系统设置中批准"
            case .notFound:         return "系统未找到记录"
            case .notRegistered:    return "未注册"
            @unknown default:       return "未知状态"
            }
        }
        return "需要 macOS 13 或更高版本"
    }

    // MARK: - 应用配置

    /// 应用启动时按当前设置对齐一次。
    ///
    /// **必须幂等**：状态已经符合设置就什么都不做。否则会出现恶性循环——
    /// app 由保活 agent 拉起 → 启动时又去 register 同一个 agent → 系统认为该
    /// 后台项被重新注册、把当前进程踢掉 → 再被拉起……
    func syncFromSettings() {
        let settings = SettingsStore.shared
        let launchAtLogin = settings.launchAtLogin
        let keepAlive = settings.keepAlive

        if let recorded = UserDefaults.standard.string(forKey: fingerprintKey),
           recorded != binaryFingerprint,
           activeMechanism != .none,
           launchAtLogin || keepAlive {
            Log.system.notice("检测到二进制已变更，重新登记后台项以刷新签名")
            apply(launchAtLogin: launchAtLogin, keepAlive: keepAlive, silent: true, force: true)
            return
        }

        guard !isAlreadyCorrect(launchAtLogin: launchAtLogin, keepAlive: keepAlive) else {
            Log.system.debug("自启动配置已符合设置，跳过同步")
            return
        }
        apply(launchAtLogin: launchAtLogin, keepAlive: keepAlive, silent: true)
    }

    private func isAlreadyCorrect(launchAtLogin: Bool, keepAlive: Bool) -> Bool {
        if !launchAtLogin && !keepAlive { return activeMechanism == .none }
        if keepAlive { return activeMechanism == .keepAliveAgent || activeMechanism == .manualPlist }
        return activeMechanism == .loginItem || activeMechanism == .manualPlist
    }

    /// - Parameter force: 忽略"已经注册过"的判断，强制先注销再注册（刷新签名登记）。
    func apply(launchAtLogin: Bool, keepAlive: Bool, silent: Bool = false, force: Bool = false) {
        guard Bundle.main.bundleIdentifier != nil,
              let executable = Bundle.main.executableURL else {
            if !silent {
                presentInfo("当前不是以 .app 形式运行，自启动设置不会生效。请先执行 ./build.sh 打包。")
            }
            return
        }

        guard launchAtLogin || keepAlive else {
            teardownAll()
            UserDefaults.standard.removeObject(forKey: fingerprintKey)
            return
        }

        if keepAlive {
            unregisterLoginItem(silent: true)
            uninstallManualPlist()

            if registerAgent(plistName: keepAlivePlistName, silent: silent, force: force) {
                recordFingerprint()
                return
            }
            installManualPlist(executable: executable, runAtLoad: true, silent: silent)
            recordFingerprint()
            return
        }

        // 只要开机自启，不要保活
        unregisterAgent(plistName: keepAlivePlistName, silent: true)

        if registerLoginItem(silent: silent, force: force) {
            uninstallManualPlist()
            recordFingerprint()
            return
        }

        installManualPlist(executable: executable, runAtLoad: true, silent: silent)
        recordFingerprint()
    }

    private func teardownAll() {
        unregisterLoginItem(silent: true)
        unregisterAgent(plistName: keepAlivePlistName, silent: true)
        uninstallManualPlist()
    }

    // MARK: - 通道一：系统托管

    /// 一次注册走到哪儿了。`failed` 里带的是可以直接给用户看的一句话。
    enum RegistrationOutcome: Equatable {
        case alreadyArmed       // 没要求 force，系统本来就挂着
        case registered         // 原本没挂，这次挂上了
        case refreshed          // force：注销旧的、重新注册新的
        case failed(String)
    }

    /// 注册的全部决策，系统调用注入进来（自检拿假状态机跑同一条路，不是抄一份）。
    ///
    /// 这里原本会**谎报成功**：`force` 时先注销旧的，那次注销失败被 `try?` 吞掉，
    /// 状态于是仍然算"挂着"，紧跟着的 `if !armed { register() }` 就被跳过 —— 函数
    /// 回报 true，`apply` 顺手把新的二进制指纹记进 UserDefaults。后果是"签名变了要
    /// 重新登记"这件事**永远不会再试**，而 force 存在的唯一理由就是刷新签名：
    /// 系统那边还指着旧登记，下次登录要么拉不起要么 `EX_CONFIG`。
    /// 现在两条都收紧：注销失败就是失败；收尾必须回读系统状态才算数。
    static func register(force: Bool,
                         armedBefore: Bool,
                         unregister: () throws -> Void,
                         register: () throws -> Void,
                         armedAfter: () -> Bool) -> RegistrationOutcome {
        var didUnregister = false
        if force, armedBefore {
            do {
                try unregister()
            } catch {
                return .failed("没能注销旧的登记：\(error.localizedDescription)")
            }
            didUnregister = true
        }
        if didUnregister || !armedBefore {
            do {
                try register()
            } catch {
                return .failed("注册失败：\(error.localizedDescription)")
            }
        }
        // 唯一算数的判据是系统回读：没抛异常不等于挂上了
        guard armedAfter() else {
            return .failed("系统里没有留下登记记录（可能被登录项策略拦下了）")
        }
        if didUnregister { return .refreshed }
        return armedBefore ? .alreadyArmed : .registered
    }

    /// 把决策结果落到日志 / 用户提示上。
    @available(macOS 13.0, *)
    private func report(_ outcome: RegistrationOutcome,
                        status: SMAppService.Status,
                        silent: Bool,
                        kind: PendingKind) -> Bool {
        switch outcome {
        case .failed(let reason):
            Log.system.error("自启动登记失败：\(reason, privacy: .public)")
            // 两条通道失败后都会退到通道二（手写 LaunchAgent），所以这句话是真的；
            // 通道二再失败由 `installManualPlist` 自己说。
            if !silent { presentInfo("\(reason)\n\n将改用 LaunchAgent 方式。") }
            return false
        case .alreadyArmed, .registered, .refreshed:
            Log.system.info("自启动已登记：\(self.statusDescription, privacy: .public)")
            warnIfNeedsApproval(status, silent: silent, kind: kind)
            return true
        }
    }

    @discardableResult
    private func registerLoginItem(silent: Bool, force: Bool = false) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        let service = SMAppService.mainApp
        let outcome = Self.register(force: force,
                                    armedBefore: isArmed(service.status),
                                    unregister: { try service.unregister() },
                                    register: { try service.register() },
                                    armedAfter: { isArmed(service.status) })
        return report(outcome, status: service.status, silent: silent, kind: .loginItem)
    }

    @discardableResult
    private func unregisterLoginItem(silent: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return true }
        let service = SMAppService.mainApp
        guard isArmed(service.status) else { return true }
        do {
            try service.unregister()
            Log.system.info("登录项已注销")
            return true
        } catch {
            Log.system.error("注销登录项失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func registerAgent(plistName: String, silent: Bool, force: Bool = false) -> Bool {
        guard #available(macOS 13.0, *) else { return false }

        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            Log.system.error("bundle 内缺少 agent plist: \(bundled.path, privacy: .public)")
            // 这是安装包坏了，不是用户做错了什么。不说一句，他就只会反复点同一个开关。
            if !silent {
                presentInfo("安装包里没有保活配置（Contents/Library/LaunchAgents/\(plistName)）。\n\n请重新安装 Grabi。")
            }
            return false
        }

        let service = SMAppService.agent(plistName: plistName)
        let outcome = Self.register(force: force,
                                    armedBefore: isArmed(service.status),
                                    unregister: { try service.unregister() },
                                    register: { try service.register() },
                                    armedAfter: { isArmed(service.status) })
        return report(outcome, status: service.status, silent: silent, kind: .agent)
    }

    @discardableResult
    private func unregisterAgent(plistName: String, silent: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return true }
        let service = SMAppService.agent(plistName: plistName)
        guard isArmed(service.status) else { return true }
        do {
            try service.unregister()
            Log.system.info("后台项已注销")
            return true
        } catch {
            Log.system.error("注销后台项失败: \(error.localizedDescription)")
            return false
        }
    }

    private enum PendingKind { case loginItem, agent }

    @available(macOS 13.0, *)
    private func warnIfNeedsApproval(_ status: SMAppService.Status,
                                     silent: Bool,
                                     kind: PendingKind) {
        guard !silent, status == .requiresApproval else { return }
        let what = kind == .agent ? "后台保活" : "开机自启"
        presentInfo("""
        Grabi 的\(what)已注册，还需要你确认一次：

        打开「系统设置 › 通用 › 登录项与扩展」，允许 Grabi。

        —— 后台保活开启后，Grabi 崩溃时系统会自动把它拉起来；主动退出不会复活。
        """)
    }

    // MARK: - 通道二：手写 LaunchAgent（兜底）

    private func installManualPlist(executable: URL, runAtLoad: Bool, silent: Bool) {
        let plist = makeManualPlist(executable: executable, runAtLoad: runAtLoad)
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml,
                                                          options: 0)
            try data.write(to: plistURL, options: .atomic)
            Log.system.info("已写入 LaunchAgent: \(self.plistURL.path, privacy: .public)")
        } catch {
            Log.system.error("写入 LaunchAgent 失败: \(error.localizedDescription)")
            if !silent { presentInfo("写入自启动配置失败：\(error.localizedDescription)") }
            return
        }
        reloadManualAgent(silent: silent)
    }

    private func makeManualPlist(executable: URL, runAtLoad: Bool) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable.path],
            "RunAtLoad": runAtLoad,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": throttleSeconds,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "WorkingDirectory": executable.deletingLastPathComponent().path
        ]
    }

    func uninstallManualPlist() {
        guard isManualPlistInstalled else { return }
        bootoutManualAgent()
        try? FileManager.default.removeItem(at: plistURL)
        Log.system.info("已移除 LaunchAgent")
    }

    private func reloadManualAgent(silent: Bool) {
        bootoutManualAgent()
        guard !bootstrapManualAgent(), !silent else { return }
        presentInfo("""
        LaunchAgent 已写入 ~/Library/LaunchAgents/com.momoxiao.grabi.plist，\
        但 launchd 拒绝立即加载它。

        这通常出现在受管设备或受限环境里。可以：
        1. 注销后重新登录，系统会在登录时自动加载；
        2. 或在终端执行：
           launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.momoxiao.grabi.plist
        """)
    }

    private func bootstrapManualAgent() -> Bool {
        let result = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        if result.status == 0 {
            _ = launchctl(["enable", "gui/\(getuid())/\(label)"])
            Log.system.info("LaunchAgent 已加载")
            return true
        }
        if launchctl(["load", "-w", plistURL.path]).status == 0 {
            Log.system.info("LaunchAgent 已通过 legacy load 加载")
            return true
        }
        Log.system.error("launchctl bootstrap 失败(\(result.status)): \(result.stderr, privacy: .public)")
        return false
    }

    private func bootoutManualAgent() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        _ = launchctl(["unload", plistURL.path])
    }

    /// 预览将要写入的 plist，供诊断和人工核对。
    func previewPlist() -> String {
        guard let executable = Bundle.main.executableURL else {
            return "（不是以 bundle 形式运行，无法确定可执行文件路径）"
        }
        let plist = makeManualPlist(executable: executable, runAtLoad: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                             format: .xml,
                                                             options: 0),
              let text = String(data: data, encoding: .utf8) else {
            return "（生成失败）"
        }
        return "写入位置: \(plistURL.path)\n\n\(text)"
    }

    func detailedStatus() -> String {
        var lines: [String] = []
        lines.append("生效机制      : \(activeMechanism.rawValue)")
        lines.append("状态描述      : \(statusDescription)")
        lines.append("手写 plist    : \(isManualPlistInstalled ? plistURL.path : "未安装")")
        lines.append("app 路径      : \(Bundle.main.bundleURL.path)")
        lines.append("标准应用目录  : \(isInStandardLocation ? "是 ✓" : "否 ✗（后台启动会被系统拒绝）")")

        if #available(macOS 13.0, *) {
            lines.append("mainApp       : \(Self.describe(SMAppService.mainApp.status))")
            lines.append("keepalive     : \(Self.describe(SMAppService.agent(plistName: keepAlivePlistName).status))")
        } else {
            lines.append("（需要 macOS 13 或更高版本）")
        }
        return lines.joined(separator: "\n")
    }

    @available(macOS 13.0, *)
    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:    return "notRegistered（未注册）"
        case .enabled:          return "enabled（已启用）"
        case .requiresApproval: return "requiresApproval（等待用户批准）"
        case .notFound:         return "notFound（系统找不到）"
        @unknown default:       return "unknown(\(status.rawValue))"
        }
    }

    // MARK: - 工具

    @discardableResult
    private func launchctl(_ arguments: [String]) -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, text)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func presentInfo(_ text: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "自启动 / 保活"
            alert.informativeText = text
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}
