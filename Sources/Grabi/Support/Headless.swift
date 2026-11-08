import AppKit

/// 无头模式：自检跑的是给用户看的同一批界面，但不该在用户屏幕上留下任何痕迹。
///
/// 为什么单独一档：`--ui-render` 要构造真的窗口才能离屏画，而构造路径里那些
/// `makeKeyAndOrderFront` / `NSApp.activate` / 菜单栏图标是给"人正在用"的时候写的。
/// 自检一遍几十张图，弹窗就会一次次盖到用户的工作上 —— 而 `cacheDisplay` 根本
/// 不需要窗口在屏上。所以：窗口只建不显、菜单栏不留图标、不抢焦点。
/// 哪一档该进无头见 `main.swift` 的 `headlessFlags`。
enum Headless {
    static var active = false

    /// 上屏类调用一律走这里：无头时只跳过显示，不跳过建窗口和排版。
    static func onScreen(_ body: () -> Void) {
        guard !active else { return }
        body()
    }
}
