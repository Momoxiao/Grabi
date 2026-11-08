import AppKit

/// Grabi 各个浮层的窗口层级。
///
/// 抽出来集中一处只为一件事：它们**必须保持这个先后**，而这件事以前只写在注释里
/// （"必须在预览面板之上"）。注释不会失败，断言会 —— 改坏一处层级，症状是
/// "工具栏被自己的预览盖住"这种只在真机上看得见的问题。
enum ShotLevels {

    /// 全屏覆盖层：截图时的选区层、调整范围时的取层。要压过一切普通窗口。
    static let overlay = NSWindow.Level.screenSaver

    /// 压暗层（纯视觉，鼠标穿透）。
    static let dim = NSWindow.Level.floating

    /// 就地预览面板。
    static let preview = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    /// 预览下面那条工具栏。
    static let toolbar = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)

    /// **钉在屏幕上**的预览（拖走 / 缩放过之后）。
    ///
    /// 用户明确要求"固定在屏幕最高层，不会被覆盖"。普通的 `.floating` 只压得住
    /// 普通窗口，遇到别的 app 的全屏 / 高浮层窗口照样会被盖住 —— 所以钉住之后
    /// 把这一张提到 `.screenSaver` 下面两档：全屏覆盖层（截图时的选区层，
    /// 只在抓图那一刻存在）仍然压得住它，其余窗口一律在它下面。
    static let pinnedPreview = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)

    /// 右下角的结果角标。压在最上面那一档（除全屏覆盖层外），
    /// 这样"已固定在屏幕上 / 已复制"这些回执**不会被钉住的预览盖掉**。
    static let toast = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

    /// 从低到高。断言直接吃这一份，代码里的赋值也吃这一份。
    static var orderedBottomToTop: [(String, NSWindow.Level)] {
        [("压暗层", dim), ("预览面板", preview), ("工具栏", toolbar),
         ("钉住的预览", pinnedPreview), ("结果角标", toast), ("全屏覆盖层", overlay)]
    }
}
