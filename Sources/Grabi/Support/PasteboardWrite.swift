import AppKit

/// 往剪贴板写，并且**回读**。
///
/// 三处「已复制」以前只看设置开没开、或者干脆不看写入结果：`clearContents()` 的
/// 返回值（新的 changeCount，失败给 0）、`declareTypes` 与 `setString` / `setData`
/// 的 Bool 全被丢掉。写失败最坑的地方在于它**不是没有反应**，而是用户按 ⌘V
/// 粘出来上一份内容 —— 他以为复制成功了。所以这里统一成"写完读一遍"。
enum PasteboardWrite {

    @discardableResult
    static func write(text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        let before = pasteboard.changeCount
        guard pasteboard.clearContents() != 0 else { return false }
        guard pasteboard.setString(text, forType: .string) else { return false }
        return verifyText(text, on: pasteboard, changedFrom: before)
    }

    /// 一张图给 TIFF + PNG 两份：只写 TIFF 时某些 app 粘不出来。
    /// `fileURL` 有值时就再声明一份文件 URL —— Finder / 部分聊天工具要的是这一份，
    /// 而不是位图数据。没有文件时只写图片，绝不去声明一个不存在的路径。
    @discardableResult
    static func writeImage(tiff: Data?, png: Data?, fileURL: URL? = nil,
                           to pasteboard: NSPasteboard = .general) -> Bool {
        let before = pasteboard.changeCount
        guard tiff != nil || png != nil else { return false }
        guard pasteboard.clearContents() != 0 else { return false }
        var types: [NSPasteboard.PasteboardType] = [.tiff, .png]
        if fileURL != nil { types.append(.fileURL) }
        // `declareTypes` 在这套 SDK 上返回的是 Int（新的 changeCount，0 = 没声明上），
        // 不是文档里写的 Bool —— 编译器说的算。
        guard pasteboard.declareTypes(types, owner: nil) != 0 else { return false }
        var wrote = false
        if let tiff { wrote = pasteboard.setData(tiff, forType: .tiff) || wrote }
        if let png { wrote = pasteboard.setData(png, forType: .png) || wrote }
        if let fileURL { wrote = pasteboard.setString(fileURL.absoluteString, forType: .fileURL) || wrote }
        guard wrote else { return false }
        return verifyImage(on: pasteboard, changedFrom: before)
    }

    /// 回读：那份字必须原样读得回来，且 changeCount 真的动过。
    static func verifyText(_ text: String, on pasteboard: NSPasteboard,
                           changedFrom before: Int) -> Bool {
        pasteboard.changeCount != before && pasteboard.string(forType: .string) == text
    }

    /// 图片不整份读回来比对（一张 6K 截图的 TIFF 上百 MB），只查这份剪贴板里
    /// 到底有没有一个可粘的图像类型。
    static func verifyImage(on pasteboard: NSPasteboard, changedFrom before: Int) -> Bool {
        pasteboard.changeCount != before
            && (pasteboard.availableType(from: [.tiff]) == .tiff
                || pasteboard.availableType(from: [.png]) == .png)
    }

    // MARK: - 措辞（纯函数：两头都查得到，且自检不碰真剪贴板）

    /// 状态行那种一行的说法。
    static func textStatus(ok: Bool, characters: Int) -> String {
        ok ? "已复制 \(characters) 个字符"
           : "复制没成功：剪贴板没收下这 \(characters) 个字符　·　可能被别的 app 占着，再按一次"
    }

    /// 同一行的图片版。带上尺寸是因为"复制的是画布上这一张"这件事，
    /// 用户只有看到刚裁出来的那个数字才敢信。
    static func imageStatus(ok: Bool, dimensions: String) -> String {
        ok ? "已复制图片 \(dimensions)"
           : "复制没成功：剪贴板没收下这张图　·　可能被别的 app 占着，再按一次"
    }

    static let textFailureTitle = "复制没成功"

    /// 角标那两行的说法：标题短到不会被裁，细节里说清"多少字 + 下一步"。
    static func textFailureDetail(characters: Int) -> String {
        "剪贴板没收下这 \(characters) 个字符　·　可能被别的 app 占着，再按一次"
    }

    /// 同一句的图片版 —— 标题共用「复制没成功」，因为对用户来说是同一件坏事。
    static func imageFailureDetail(dimensions: String) -> String {
        "剪贴板没收下这张 \(dimensions) 的图　·　可能被别的 app 占着，再按一次"
    }

    /// 截图角标里那半句。写失败时不能只说"已保存"就完事 —— 用户回头会去找
    /// "刚才那张复制到哪去了"。
    static func imageClipboardSuffix(ok: Bool) -> String {
        ok ? "　·　已复制" : "　·　图片没进剪贴板"
    }
}
