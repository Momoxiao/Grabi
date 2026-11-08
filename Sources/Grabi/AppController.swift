import AppKit

/// 应用主控：装配各个部件，处理生命周期。
final class AppController: NSObject, NSApplicationDelegate {

    private let settings = SettingsStore.shared
    private let coordinator = ShotCoordinator.shared

    private var statusBar: StatusBarController!
    private var hotKeys: HotKeyCenter!
    private var settingsWindow: SettingsWindowController!

    /// 缺权限时的授权侦测。系统设置里勾上之后，**当前进程不会立刻生效**，
    /// 只能重启 —— 不告诉用户这一条，他就会反复按热键然后以为软件坏了。
    private var permissionPoll: Timer?
    private var reopenObserver: NSObjectProtocol?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Grabi 启动 bundle=\(Bundle.main.bundleIdentifier ?? "nil", privacy: .public)")

        settings.ensureSaveDirectory()
        // 保活隐含开机自启（launchd agent 带 RunAtLoad）。默认值本身就可能不一致，
        // 所以启动时先归位一次，后面读到的、显示的都是同一份真相。
        settings.normalizeAutoStart()

        hotKeys = HotKeyCenter()
        settingsWindow = SettingsWindowController(onSettingsChanged: { [weak self] in
            self?.applySettings()
        })

        statusBar = StatusBarController()
        statusBar.onOpenSettings = { [weak self] in self?.settingsWindow.present() }
        statusBar.onSettingsChanged = { [weak self] in self?.applySettings() }
        statusBar.onQuit = { [weak self] in self?.quit() }
        statusBar.setVisible(!settings.hideStatusBarIcon)

        // 后到实例拿到单实例锁失败后，会发这条跨进程通知。把菜单栏图标恢复出来；
        // 如果用户是从 Finder 再次点开，也把设置窗带到前面，和 `open` 的行为一致。
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.reopenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleReopenRequest()
        }

        coordinator.onFlashStatusItem = { [weak self] in self?.statusBar.flash() }
        coordinator.onOpenSettings = { [weak self] in self?.settingsWindow.present() }
        coordinator.onPermissionMissing = { [weak self] in
            self?.statusBar.showPermissionWarning()
            self?.watchPermissionGrant()
        }

        applySettings()
        AutoStartManager.shared.syncFromSettings()
        warmUpOCR()
        Permissions.recordLaunchState()
        presentWelcomeIfNeeded()

        // 只在真正的第一次运行引导一次权限——之前每次启动都提示，
        // 叠加重编译会让授权记录失效，就变成了"明明给过权限还一直要"。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.promptPermissionOnceIfNeeded()
        }
    }

    /// 「设置…」入口，供主菜单调用（目标留 nil，走响应链找到这里）。
    @objc func showSettingsWindow(_ sender: Any?) {
        settingsWindow.present()
    }

    /// 主菜单里的截图命令。走的是和全局热键**同一个入口**，
    /// 所以权限缺失、忙时的忽略、预览与角标这些行为不会分叉。
    @objc func captureFromMenu(_ sender: Any?) {
        coordinator.handleCapture()
    }

    // MARK: - 首次运行引导

    /// 第一次运行给一条引导角标：告诉他热键是什么、图存在哪儿。
    ///
    /// 只出现一次。菜单栏应用没有 Dock 图标、也没有欢迎窗口，
    /// 装完之后的"然后呢？"是真实存在的空缺 —— 但用弹窗挡路更糟，
    /// 所以用会在几秒后自己消失的角标。
    private func presentWelcomeIfNeeded() {
        guard !settings.didShowWelcome else { return }
        settings.didShowWelcome = true

        let directory = NSString(string: settings.saveDirectory).abbreviatingWithTildeInPath
        // 还没授权时，第一句该说的是"先去授权"，而不是"按 ⌃A 截图"——
        // 后者只会让人按了没反应，然后怀疑软件坏了。
        let detail = Permissions.hasScreenRecording
            ? "按 \(settings.hotKeyCapture.displayString) 截图　·　图存到 \(directory)"
            : "先点菜单栏的 Grabi 图标授权「屏幕录制」，之后按 \(settings.hotKeyCapture.displayString) 截图"

        ToastHUDController.shared.show(title: "Grabi 已就绪",
                                       detail: detail,
                                       duration: 8)
    }

    // MARK: - 权限生效侦测

    /// 缺权限时开始轮询预检接口，检测到用户刚刚授权就提示"重启才生效"。
    ///
    /// `CGPreflightScreenCaptureAccess()` 不弹窗、开销可以忽略，
    /// 而且 TCC 不会给 app 推送授权变化，只能自己问。
    private func watchPermissionGrant() {
        guard !Permissions.hasScreenRecording, permissionPoll == nil else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] timer in
            guard Permissions.hasScreenRecording else { return }
            timer.invalidate()
            self?.permissionPoll = nil
            self?.presentPermissionRestartNotice()
        }
    }

    private func presentPermissionRestartNotice() {
        statusBar.clearPermissionWarning()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "权限已开启，重启一次就能用"
        alert.informativeText = """
        macOS 只在应用启动时读取屏幕录制授权，所以 Grabi 需要重新打开一次。

        点「立即重启」，大概一秒钟就回来。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "立即重启")
        alert.addButton(withTitle: "稍后再说")

        if alert.runModal() == .alertFirstButtonReturn {
            relaunchAndTerminate()
        }
    }

    /// 交棒给系统：先让启动服务在旧进程退出之后把 app 重新拉起来，再退出自己。
    ///
    /// 不能直接 `open` 再 `terminate`：两份实例同时存在的那一瞬间，
    /// 热键会互相抢注册，新实例反而会因为"被占用"注册失败。
    private func relaunchAndTerminate() {
        let bundlePath = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", bundlePath]
        do {
            try task.run()
        } catch {
            Log.system.error("安排重启失败: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys?.unregisterAll()
        if let reopenObserver {
            DistributedNotificationCenter.default().removeObserver(reopenObserver)
        }
        SingleInstance.shared.release()
    }

    /// 用户再次打开 app（比如菜单栏图标被隐藏后想找回来）时触发。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        handleReopenRequest()
        return true
    }

    /// Finder 再次点开或后到实例请求唤醒时，恢复菜单栏图标并打开设置。
    private func handleReopenRequest() {
        guard statusBar != nil else { return }
        if settings.hideStatusBarIcon {
            settings.hideStatusBarIcon = false
            statusBar.setVisible(true)
            Log.app.notice("检测到重新打开，已恢复菜单栏图标")
        }
        settingsWindow.present()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator.cancelAll()
        return .terminateNow
    }

    // MARK: - 设置生效

    private func applySettings() {
        registerHotKeys()
        statusBar.setVisible(!settings.hideStatusBarIcon)
    }

    private func registerHotKeys() {
        hotKeys.unregisterAll()

        let bindings: [(String, HotKeySpec)] = [
            ("截图", settings.hotKeyCapture)
        ]

        var failures: [String] = []
        for (title, spec) in bindings where !spec.isDisabled {
            let ok = hotKeys.register(spec) { [weak self] in
                self?.coordinator.handleCapture()
            }
            if !ok { failures.append("\(title)（\(spec.displayString)）") }
        }

        if !failures.isEmpty {
            Log.hotkey.error("热键注册失败: \(failures.joined(separator: "、"), privacy: .public)")
            notifyHotKeyFailure(failures)
        }
    }

    private func notifyHotKeyFailure(_ failures: [String]) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "快捷键注册失败"
            alert.informativeText = """
            系统拒绝了这几个组合键的注册：

            \(failures.joined(separator: "\n"))

            去「设置 › 快捷键」换一条（⌃⌥ 开头的最稳），或点「恢复默认快捷键」。

            另外提醒一句：如果是被**别的 app** 占用了，系统不会报错 —— 注册照样
            "成功"，症状是按了没反应。那种情况也在上面那个面板里换一条就行。
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    // MARK: - 权限引导

    private func promptPermissionOnceIfNeeded() {
        guard !Permissions.hasScreenRecording else { return }
        watchPermissionGrant()

        guard !Permissions.didOnboardPermission else {
            Log.app.notice("缺少屏幕录制权限，但已经引导过，不再重复弹窗")
            statusBar.showPermissionWarning()
            return
        }
        Permissions.markOnboarded()
        // 只触发系统那一次授权请求，不再叠一个自己的说明窗——
        // 系统弹窗已经说清楚了要什么权限，再弹一次是纯粹的打扰。
        // （而且 CGRequestScreenCaptureAccess 是异步的，看结果要等下一轮启动。）
        Permissions.ensureScreenRecording(interactive: true, forcePrompt: true, explains: false)
        if !Permissions.hasScreenRecording {
            statusBar.showPermissionWarning()
        }
    }

    // MARK: - OCR 预热

    /// 空闲预热 OCR。
    ///
    /// Vision 第一次加载模型要 2–32 秒（之后走系统缓存只要 ~200ms）。
    /// 这个代价绝不能落在用户第一次点「识别文字」上——放在启动后静默完成。
    ///
    /// ⚠️ 曾经这里用的是一张 16×16 的**空白图**，预热日志显示"耗时 0.1 秒"，
    /// 看着成功其实什么都没加载：图里没有文字，检测阶段直接返回，
    /// 识别模型压根不会被拽起来。所以预热图里必须画真的字。
    private func warmUpOCR() {
        // 越早越好：预热没跑完时用户第一次点「识别文字」要排队等它（实测最多 30 秒），
        // 表现就是"点了没反应"。只留一点点时间给启动本身，别让两件事挤在同一帧。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            OCRRecognizer.warmUp()
        }
    }

    // MARK: - 退出

    private func quit() {
        hotKeys?.unregisterAll()
        NSApp.terminate(nil)
    }
}
