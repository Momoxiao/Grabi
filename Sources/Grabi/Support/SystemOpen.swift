import AppKit

/// 「点一下就该有反应」的那几个系统打开动作，集中在一处。
///
/// `NSWorkspace.open` 失败时是**静默**返回 false 的：菜单点了没动静、面板没反应，
/// 用户只会以为自己没点到，于是再点一次。这类"没反应"和上一轮修掉的
/// "把失败说成成功"是同一枚硬币的两面 —— 都该有一句人话。
enum SystemOpen {
    enum Subject {
        case file, folder

        var gone: String { self == .file ? "这张图已经不在了" : "这个文件夹已经不在了" }
        var unopenable: String { self == .file ? "系统没能打开它" : "系统没能打开这个文件夹" }
    }

    /// 打不开时角标上的两行。
    ///
    /// "不在了"和"在但打不开"必须分开说：前者下一步是去回收站/别的机器找，
    /// 后者下一步是查默认 app、磁盘是否还挂着 —— 混成一句"打开失败"两条都指不了。
    /// 第二行一定带上具体路径：只给文件名，用户不知道是哪一份。
    static func failureText(url: URL, subject: Subject, exists: Bool) -> (title: String, detail: String) {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let reason = exists ? subject.unopenable : subject.gone
        return ("打不开 \(name)", "\(reason)　·　\(url.deletingLastPathComponent().path)")
    }

    /// 打开，失败时弹角标说明。`onGone` 只在"确实不在了"时回调（用来把死链从
    /// 最近截图里摘掉）—— 打不开但文件还在的时候摘它，等于把用户的记录弄丢。
    @discardableResult
    static func open(_ url: URL, subject: Subject, onGone: ((String) -> Void)? = nil) -> Bool {
        if NSWorkspace.shared.open(url) { return true }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists { onGone?(url.path) }
        let text = failureText(url: url, subject: subject, exists: exists)
        ToastHUDController.shared.show(title: text.title, detail: text.detail, duration: 4.8)
        return false
    }

    /// 「系统设置 › …」那一页的候选 URL 挨个试（不同 macOS 版本 URL 不一样），
    /// 全都不行才说话 —— 中间那次失败说给用户听毫无意义。
    /// 这一类失败原先是**彻底静默**的：点「点此修复」什么也没弹，
    /// 而用户本来就卡在权限这一步上，那是最不该没反应的一处。
    @discardableResult
    static func openFirst(_ urls: [URL], page: String) -> Bool {
        for url in urls where NSWorkspace.shared.open(url) { return true }
        let text = settingsPaneText(page: page)
        ToastHUDController.shared.show(title: text.title, detail: text.detail, duration: 5.4)
        return false
    }

    /// 在访达里选中这个文件。`activateFileViewerSelecting` **没有返回值**，
    /// 所以这里能查的那件事就是"文件还在不在" —— 而它恰好是这条路径上唯一现实的
    /// 失败（图被别的 app 删了、外置盘被弹掉）。
    static func reveal(_ url: URL, onGone: ((String) -> Void)? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            onGone?(url.path)
            let text = failureText(url: url, subject: .file, exists: false)
            ToastHUDController.shared.show(title: text.title, detail: text.detail, duration: 4.8)
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    static func settingsPaneText(page: String) -> (title: String, detail: String) {
        ("没能打开「\(page)」", "系统设置没有响应　·　可手动打开「系统设置 › \(page)」")
    }
}
