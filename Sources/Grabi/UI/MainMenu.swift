import AppKit

/// 标准主菜单。
///
/// 菜单栏应用（LSUIElement）不写主菜单，代价远不止"顶部少一排菜单"：
///
/// * ⌘C / ⌘V / ⌘A / ⌘Z 这些**标准编辑快捷键是由主菜单的 key equivalent 派发的**。
///   没有主菜单，设置面板里的文件名输入框就粘不上去 —— 用户的判断是
///   "这软件坏了"。
/// * app 一旦被激活（打开设置、弹权限说明、截图覆盖层），顶部会出现一排
///   **只有光秃秃应用名的空菜单**，这是最典型的"没做完"观感。
///
/// 这里给一份精简但符合系统惯例的主菜单：应用 / 编辑 / 视图 / 窗口。
/// 编辑菜单的目标一律留 nil，交给响应链 —— 只有能响应的视图会点亮它，
/// 截图预览面板那种自定义窗口不受影响（⌘C 仍由面板自己处理）。
enum MainMenu {

    static func install() {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(windowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    // MARK: - 应用

    private static func appMenuItem() -> NSMenuItem {
        // 顶层项标题写死：`NSMenuItem()` 的默认标题是类名字面量 "NSMenuItem"，
        // 菜单栏上因为显示的是子菜单标题才看不出来 —— 但任何按标题找东西的代码都会踩到。
        let item = NSMenuItem(title: "Grabi", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Grabi")

        menu.addItem(action("关于 Grabi",
                            #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                            key: ""))
        menu.addItem(.separator())
        menu.addItem(action("设置…",
                            #selector(AppController.showSettingsWindow(_:)),
                            key: ","))
        menu.addItem(.separator())

        for item in captureItems(capture: SettingsStore.shared.hotKeyCapture) {
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // 热键可以在设置里改，菜单不能停在旧的那一套上：每次弹出时按当前设置重标。
        menu.delegate = MainMenu.appMenuRefresher

        let services = NSMenu(title: "服务")
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)

        menu.addItem(.separator())
        menu.addItem(action("隐藏 Grabi",
                            #selector(NSApplication.hide(_:)), key: "h"))
        menu.addItem(action("退出 Grabi",
                            #selector(NSApplication.terminate(_:)), key: "q"))

        item.submenu = menu
        return item
    }

    // MARK: - 编辑

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "编辑")

        menu.addItem(action("撤销", Selector(("undo:")), key: "z"))
        menu.addItem(action("重做", Selector(("redo:")), key: "Z"))
        menu.addItem(.separator())
        menu.addItem(action("剪切", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(action("复制", #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(action("粘贴", #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(action("删除", #selector(NSText.delete(_:)), key: ""))
        menu.addItem(action("全选", #selector(NSText.selectAll(_:)), key: "a"))
        menu.addItem(.separator())
        menu.addItem(findMenuItem())

        item.submenu = menu
        return item
    }

    /// 查找子菜单。识别结果是一块**可以编辑**的文字，动辄上百字，而用户往往只要
    /// 其中一段 —— 没有 ⌘F 的话，找一处误识别只能靠滚动加眼睛。
    ///
    /// 全部走 `performFindPanelAction:` + 系统那套 tag：自己拼一个查找条既做不到
    /// 和「划选内容 / 大小写 / 整词」这些习惯一致，也活不过下一次系统更新。
    /// target 同样留 nil，所以没有文字输入的窗口（比如截图覆盖层）里这些项自动是灰的。
    private static func findMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "查找", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "查找")

        menu.addItem(findAction("查找…", key: "f", tag: 1))
        menu.addItem(findAction("查找并替换…", key: "f", tag: 8, modifiers: [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(findAction("查找下一个", key: "g", tag: 2))
        menu.addItem(findAction("查找上一个", key: "g", tag: 3, modifiers: [.command, .shift]))
        menu.addItem(findAction("使用划选内容查找", key: "e", tag: 7))

        item.submenu = menu
        return item
    }

    /// `performFindPanelAction:` 靠 `tag` 区分动作，所以这里必须连 tag 一起设。
    /// 忘了设 tag 的查找项不会报错 —— 它只会一直做「查找…」那一件事。
    private static func findAction(_ title: String, key: String, tag: Int,
                                   modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: Selector(("performFindPanelAction:")),
                              keyEquivalent: key)
        item.tag = tag
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    // MARK: - 视图

    /// 截图预览的缩放。
    ///
    /// 目标一律留 nil，由当前 key window 的预览面板接。没有预览面板时，
    /// 响应链上找不到实现，菜单项由系统自动置灰。
    private static func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "视图", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "视图")

        menu.addItem(action("放大预览", #selector(InlinePreviewController.zoomIn(_:)), key: "="))
        menu.addItem(action("缩小预览", #selector(InlinePreviewController.zoomOut(_:)), key: "-"))
        menu.addItem(action("实际大小", #selector(InlinePreviewController.resetZoom(_:)), key: "1"))

        item.submenu = menu
        return item
    }

    // MARK: - 窗口

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "窗口")

        menu.addItem(action("最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(action("关闭", #selector(NSWindow.performClose(_:)), key: "w"))
        menu.addItem(.separator())
        menu.addItem(action("前置全部窗口",
                            #selector(NSApplication.arrangeInFront(_:)), key: ""))

        item.submenu = menu
        // 交给系统托管：它会自动列出所有窗口并打勾，省掉一套自造的窗口管理
        NSApp.windowsMenu = menu
        return item
    }


    // MARK: - 截图命令

    /// 截图命令。菜单栏应用一旦被激活（打开设置、弹权限说明、点过 Dock 之外的入口），
    /// 顶部这排菜单就是用户唯一**看得见**的入口 —— 全局热键没人会去猜，
    /// 而菜单栏图标本来就是可以隐藏的。
    ///
    /// 组合键从设置里读，不写死（写死的那份和真实热键分家只是时间问题）。
    /// Carbon 的全局热键和这里的 key equivalent 是同一个组合也不会截两次：
    /// 一次按键只会被一层消费，何况 `handleCapture` 开头还有 `isBusy` 那道闸。
    static func captureItems(capture: HotKeySpec) -> [NSMenuItem] {
        let specs: [(String, String, Selector)] = [
            ("截图", "capture", #selector(AppController.captureFromMenu(_:)))
        ]
        return zip(specs, [capture]).map { pair, spec in
            let item = NSMenuItem(title: pair.0, action: pair.2, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(pair.1)
            annotate(item, with: spec)
            return item
        }
    }

    /// 把一个热键写进菜单项。抽出来是因为「弹出时重标」和「建菜单」得用同一套规则。
    static func annotate(_ item: NSMenuItem, with spec: HotKeySpec) {
        if let key = spec.menuKeyEquivalent {
            item.keyEquivalent = key.key
            item.keyEquivalentModifierMask = key.modifiers
            item.toolTip = nil
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            item.toolTip = spec.isDisabled
                ? "还没设置全局快捷键 —— 这里点一下也能截"
                : "全局快捷键 \(spec.displayString)（这个键位显示不进菜单，按它照样有效）"
        }
    }

    private final class AppMenuRefresher: NSObject, NSMenuDelegate {
        func menuNeedsUpdate(_ menu: NSMenu) {
            let settings = SettingsStore.shared
            let current: [String: HotKeySpec] = ["capture": settings.hotKeyCapture]
            for item in menu.items {
                guard let id = item.identifier?.rawValue, let spec = current[id] else { continue }
                MainMenu.annotate(item, with: spec)
            }
        }
    }

    private static let appMenuRefresher = AppMenuRefresher()

    // MARK: - 工厂

    /// 目标留 nil：事件走响应链，谁能在当前上下文里响应，菜单项就自动点亮。
    private static func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        if key == "Z" { item.keyEquivalentModifierMask = [.command, .shift] }
        return item
    }
}
