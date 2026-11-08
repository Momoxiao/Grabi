import AppKit

/// 菜单栏常驻控制器。菜单每次弹出时重建，保证勾选状态 / 最近截图永远是最新的。
final class StatusBarController: NSObject, NSMenuDelegate, NSMenuItemValidation {

    private let statusItem: NSStatusItem
    private let settings = SettingsStore.shared
    private let coordinator = ShotCoordinator.shared

    private var flashTimer: Timer?
    private var isFlashing = false
    private var isPermissionWarning = false

    var onOpenSettings: (() -> Void)?
    var onSettingsChanged: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = StatusIcon.image(.normal)
            button.toolTip = "Grabi — 截图与文字识别"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        // 自检会构造好几个这个控制器（每个都要摊开菜单量一遍）——
        // 菜单栏里不该因此多出几个图标。
        if Headless.active { statusItem.isVisible = false }
    }

    // MARK: - 显示 / 隐藏

    /// 离屏渲染自检用：拿到那份"每次弹出才重建"的菜单，好把它弹开一次来体检。
    var menuForSelfTest: NSMenu? { statusItem.menu }

    /// 自检用：无头模式下这个图标不该占到菜单栏。
    var statusItemVisibleForSelfTest: Bool { statusItem.isVisible }

    func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
        Log.ui.debug("菜单栏图标可见性: \(visible)")
    }

    // MARK: 图标

    /// 截图完成后短暂闪一下，给用户"拍到了"的确定感。
    ///
    /// 闪的是**同一副括号中间多了一颗点**，不是换成另一枚符号：换整枚符号读起来
    /// 像换了个 app，而不是"这一下拍到了"。
    ///
    /// 原来的 180ms 是"动画帧"的量级，不是"人能看见"的量级；截图后预览面板还会
    /// 立刻吸走注意力，所以这里留 900ms：足够形成反馈，又不至于像卡住。
    static let flashDuration: TimeInterval = 0.90

    func flash() {
        guard !isFlashing, !isPermissionWarning, statusItem.isVisible else { return }
        isFlashing = true
        statusItem.button?.image = StatusIcon.image(.flashed)
        // 菜单栏图标本身只有 16pt；模板图在深浅底上又都很克制。加一层系统按下态，
        // 让"拍到了"这件事在小图标之外还有一次明确的视觉回执。
        statusItem.button?.highlight(true)
        statusItem.button?.toolTip = "Grabi：这一张拍到了"

        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: Self.flashDuration,
                                          repeats: false) { [weak self] _ in
            guard let self else { return }
            self.statusItem.button?.image = StatusIcon.image(.normal)
            self.statusItem.button?.highlight(false)
            self.statusItem.button?.toolTip = "Grabi — 截图与文字识别"
            self.isFlashing = false
        }
    }

    /// 缺权限时把图标换成警示样式——不弹窗，但用户一眼能看到。
    func showPermissionWarning() {
        guard !isPermissionWarning, statusItem.isVisible else { return }
        isPermissionWarning = true
        flashTimer?.invalidate()
        isFlashing = false

        statusItem.button?.image = StatusIcon.image(.warning)
        statusItem.button?.highlight(false)
        statusItem.button?.toolTip = "Grabi：缺少屏幕录制权限，截图不可用（点开菜单处理）"
    }

    private func clearPermissionWarningIfNeeded() {
        guard isPermissionWarning, Permissions.hasScreenRecording else { return }
        isPermissionWarning = false
        statusItem.button?.image = StatusIcon.image(.normal)
        statusItem.button?.highlight(false)
        statusItem.button?.toolTip = "Grabi — 截图与文字识别"
    }

    /// 权限刚拿到时由启动流程主动调一次。
    ///
    /// 原来只在菜单弹出时才检查（`menuWillOpen`），于是授权之后那个 ⚠️ 图标
    /// 会一直挂着 —— 用户已经照做了，界面却还在说"你缺权限"。
    func clearPermissionWarning() {
        clearPermissionWarningIfNeeded()
    }

    // MARK: 菜单

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        clearPermissionWarningIfNeeded()

        // 这一排从 16 行收到 8 行。三条合并的理由都写在被合掉的那一条原来站的位置上：
        // ① 两条提示行（手势 / 保存路径）撤了 —— 手势那句覆盖层顶部本来就有一条，
        //    路径那句挪进「截图文件」的子菜单，它跟着"文件"这件事走更顺。
        // ② 打开保存位置 / 最近截图 两条并成一个子菜单：两件都是
        //    "对已经存下来的那堆东西做点什么"。
        // ③ 自启和保活并成一条。它们本来是一个不变式的两面（保活 ⇒ 自启），
        //    摆两条等于允许用户拧出一个自相矛盾的组合，再靠 `normalizeAutoStart`
        //    在他看不见的时候掰回来 —— 那是界面在演一出戏。
        // ④ 「隐藏菜单栏图标」挪进设置 ▸ 界面：它是一条按下去就把这个菜单本身
        //    藏掉的键，放在菜单最下方反而最容易被误按。
        let capture = NSMenuItem(title: "截图", action: #selector(doCapture), keyEquivalent: "")
        capture.target = self
        // 这一行用的就是菜单栏那枚图标：同一个动作在两个地方长两个样，
        // 用户就得记两次。
        capture.image = StatusIcon.image(.normal)
        menu.addItem(capture)

        menu.addItem(.separator())

        addShotFilesMenu(to: menu)

        menu.addItem(.separator())

        let autoStart = NSMenuItem(title: ToggleTitles.autoStartPair,
                                   action: #selector(toggleAutoStart), keyEquivalent: "")
        autoStart.target = self
        autoStart.state = settings.launchAtLogin ? .on : .off
        autoStart.image = icon("power")
        menu.addItem(autoStart)

        menu.addItem(.separator())

        // ── 权限 ──────────────────────────────────────────
        addPermissionMenu(to: menu)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = icon("gearshape")
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Grabi", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = icon("xmark.circle")
        menu.addItem(quit)

        // 快捷键统一放到右边一列（系统自动对齐），不再挤在标题里
        annotate(capture, with: settings.hotKeyCapture.displayString)
    }

    /// 「截图文件」子菜单：最近那几张 + 打开保存位置 + 精细处理。
    ///
    /// 顶部那行灰字是**路径**：它以前单独占主菜单一行，挪进来之后正好给这一组做说明。
    private func addShotFilesMenu(to menu: NSMenu) {
        settings.pruneRecentShots { FileManager.default.fileExists(atPath: $0) }
        let recent = settings.recentShots

        let files = NSMenuItem(title: "最近截图", action: nil, keyEquivalent: "")
        files.image = icon("folder")
        let submenu = NSMenu()
        submenu.addItem(hintItem("　" + abbreviate(settings.saveDirectory)))
        for path in recent {
            let url = URL(fileURLWithPath: path)
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(openRecentShot(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.image = icon("photo")
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let open = NSMenuItem(title: "打开文件夹", action: #selector(openSaveDirectory),
                              keyEquivalent: "")
        open.target = self
        open.image = icon("folder.badge.gearshape")
        submenu.addItem(open)

        files.submenu = submenu
        menu.addItem(files)
    }

    /// 一条键管一对偏好：登录自启 + 崩溃保活。
    ///
    /// 它们本来就是同一个不变式的两面（保活 ⇒ 自启），拆成两条摆就是允许用户
    /// 拧出一个矛盾组合、再由代码背着他掰回去。判断本身在 `SettingsStore.autoStartPair`，
    /// 和设置窗那条勾选框是同一份。
    @objc private func toggleAutoStart() {
        let pair = SettingsStore.autoStartPair(turningOn: !settings.launchAtLogin)
        settings.launchAtLogin = pair.launchAtLogin
        settings.keepAlive = pair.keepAlive
        AutoStartManager.shared.apply(launchAtLogin: pair.launchAtLogin,
                                      keepAlive: pair.keepAlive)
        onSettingsChanged?()
    }

    /// 把快捷键挪到标题末尾的 Tab 之后：macOS 会把这一列统一右对齐，
    /// 比夹在标题中间好读。放在最后统一处理，省得每处标题都自己拼字符串。
    private func annotate(_ item: NSMenuItem, with hotKey: String) {
        guard !hotKey.isEmpty else { return }
        item.title = "\(item.title)\t\(hotKey)"
    }

    /// 弹出前系统那一趟校验问的就是这里 —— 菜单项的可用状态只能由它说了算。
    ///
    /// `NSMenu.autoenablesItems` 默认开着，`menu.update()` 会按 target/action 重算
    /// 每一项的 `isEnabled`：建菜单时写的那句 `isEnabled = false` 实测会被重新点亮，
    /// 于是"没有截图时置灰"变成"灰了 0 毫秒，点下去叮一声"。
    /// 只有这条回调活得过那一趟。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return true
    }

    /// 禁用态的说明行。用它代替"提示文字塞进菜单项标题"，视觉上更轻。
    private func hintItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func addPermissionMenu(to menu: NSMenu) {
        let granted = Permissions.hasScreenRecording
        let permission = NSMenuItem(title: granted ? "屏幕录制：已授权"
                                                   : "屏幕录制：未授权",
                                    action: #selector(fixPermission),
                                    keyEquivalent: "")
        permission.target = self
        permission.image = icon(granted ? "checkmark.shield" : "exclamationmark.shield")
        menu.addItem(permission)

        if !granted {
            let reset = NSMenuItem(title: "重置权限记录",
                                   action: #selector(resetPermissionRecord),
                                   keyEquivalent: "")
            reset.target = self
            reset.image = icon("arrow.counterclockwise")
            menu.addItem(reset)
        }
    }

    private func icon(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func abbreviate(_ path: String) -> String {
        NSString(string: path).abbreviatingWithTildeInPath
    }

    // MARK: 动作

    @objc private func doCapture() {
        DispatchQueue.main.async { self.coordinator.handleCapture() }
    }

    @objc private func openSaveDirectory() {
        settings.ensureSaveDirectory()
        SystemOpen.open(settings.saveDirectoryURL, subject: .folder)
    }

    @objc private func openRecentShot(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        // 菜单刚建好到点击之间还有一段时间：文件可能在这中间被删掉。
        // 原先这里连返回值都不看，点了就是没反应。
        SystemOpen.open(URL(fileURLWithPath: path), subject: .file) {
            SettingsStore.shared.forgetShot($0)
        }
    }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func fixPermission() {
        if Permissions.hasScreenRecording {
            Permissions.openScreenRecordingSettings()
        } else {
            _ = Permissions.ensureScreenRecording(interactive: true, forcePrompt: true)
        }
    }

    @objc private func resetPermissionRecord() {
        if Permissions.resetScreenRecordingRecord() {
            Permissions.presentResetDone()
        } else {
            _ = Permissions.ensureScreenRecording(interactive: true, forcePrompt: true)
        }
    }

    @objc private func quit() { onQuit?() }

    private func presentInfo(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
