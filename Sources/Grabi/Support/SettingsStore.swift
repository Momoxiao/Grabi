import AppKit
import Carbon.HIToolbox

enum ImageFormat: String, CaseIterable {
    case png, jpeg, heic

    var fileExtension: String {
        switch self {
        case .png:  return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }

    var displayName: String {
        switch self {
        case .png:  return "PNG（无损，体积大）"
        case .jpeg: return "JPEG（有损，体积小）"
        case .heic: return "HEIC（有损，体积最小）"
        }
    }
}

/// 那四个"菜单栏里能翻、设置窗里也能翻"的开关，**名字只有一份**。
///
/// 起因是一组真的分家：菜单写「开机自动启动」、设置写「登录后自动启动」——
/// 同一个开关两个名字，而且开机和登录根本不是一回事（`SMAppService` 登记的是登录项，
/// 用户登录之后才起来）。两边各自硬编码一个字符串，改一处忘另一处是必然的。
///
/// 只放**括号之前的核心名**：菜单那一行短，设置那一行要在括号里补一句
/// "它还会顺带干什么"，那部分属于面板、不属于名字。
enum ToggleTitles {
    static let launchAtLogin = "登录时启动"
    static let keepAlive = "崩溃后重启"
    static let hideStatusBarIcon = "隐藏菜单栏图标"

    /// 菜单栏上那一条"自启 + 保活"合并项的名字。**从两条核心名拼出来**，
    /// 不另抄一份 —— 改了上面任何一条，这一条跟着变，不会出现菜单说 A、设置说 B。
    static var autoStartPair: String { "\(launchAtLogin)（含\(keepAlive)）" }

    /// 每一项都要在设置窗里出现；菜单那边只带其中两条（另两条并成了 `autoStartPair`、
    /// 「隐藏菜单栏图标」挪进了设置 ▸ 界面），所以自检按 `menuCarried` 分着对。
    static let all: [(key: String, title: String)] = [
        ("launchAtLogin", launchAtLogin),
        ("keepAlive", keepAlive),
        ("hideStatusBarIcon", hideStatusBarIcon)
    ]
}

/// 支持的 OCR 语言（Vision 的 BCP-47 标识符）。
struct OCRLanguage {
    let code: String
    let name: String

    static let common: [OCRLanguage] = [
        .init(code: "zh-Hans", name: "简体中文"),
        .init(code: "zh-Hant", name: "繁体中文"),
        .init(code: "en-US",   name: "英文"),
        .init(code: "ja-JP",   name: "日文"),
        .init(code: "ko-KR",   name: "韩文"),
        .init(code: "fr-FR",   name: "法文"),
        .init(code: "de-DE",   name: "德文"),
        .init(code: "es-ES",   name: "西班牙文"),
        .init(code: "ru-RU",   name: "俄文"),
        .init(code: "it-IT",   name: "意大利文")
    ]
}

/// 全局配置。基于 UserDefaults，读写都很轻。
final class SettingsStore {

    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let saveDirectory   = "saveDirectory"
        static let fileNamePattern = "fileNamePattern"
        static let imageFormat     = "imageFormat"
        static let jpegQuality     = "jpegQuality"
        static let saveOCRText     = "saveOCRText"
        static let ocrLanguages    = "ocrLanguages"
        static let playSound       = "playSound"
        static let showCursor      = "showCursor"
        static let launchAtLogin   = "launchAtLogin"
        static let keepAlive       = "keepAlive"
        static let recentShots     = "recentShots"

        // 界面
        static let hideStatusBarIcon   = "hideStatusBarIcon"
        static let autoCopyOCRText     = "autoCopyOCRText"
        static let didShowWelcome      = "didShowWelcome"

        // 热键（统一入口）
        static let hotKeyCapture = "hotKeyCapture"
    }

    private init() {
        defaults.register(defaults: [
            Key.saveDirectory:   NSString(string: "~/Pictures/Grabi").expandingTildeInPath,
            Key.fileNamePattern: "Grabi-{date}-{time}",
            Key.imageFormat:     ImageFormat.png.rawValue,
            Key.jpegQuality:     0.9,
            Key.saveOCRText:     false,
            Key.ocrLanguages:    ["zh-Hans", "en-US"],
            Key.playSound:       true,
            Key.showCursor:      false,
            Key.launchAtLogin:   false,
            Key.keepAlive:       true,
            Key.recentShots:     [String](),

            Key.hideStatusBarIcon:      false,
            Key.autoCopyOCRText:        false,
            Key.didShowWelcome:         false
        ])
    }

    // MARK: - 保存

    var saveDirectory: String {
        get { defaults.string(forKey: Key.saveDirectory) ?? "" }
        set { defaults.set(newValue, forKey: Key.saveDirectory) }
    }

    var saveDirectoryURL: URL {
        URL(fileURLWithPath: NSString(string: saveDirectory).expandingTildeInPath, isDirectory: true)
    }

    @discardableResult
    func ensureSaveDirectory() -> Bool {
        let url = saveDirectoryURL
        if FileManager.default.fileExists(atPath: url.path) { return true }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            Log.app.error("创建保存目录失败: \(error.localizedDescription)")
            return false
        }
    }

    var fileNamePattern: String {
        get { defaults.string(forKey: Key.fileNamePattern) ?? "Grabi-{date}-{time}" }
        set { defaults.set(newValue, forKey: Key.fileNamePattern) }
    }

    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: Key.imageFormat) ?? "") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: Key.imageFormat) }
    }

    var jpegQuality: Double {
        get { defaults.double(forKey: Key.jpegQuality) }
        set { defaults.set(newValue, forKey: Key.jpegQuality) }
    }

    var saveOCRText: Bool {
        get { defaults.bool(forKey: Key.saveOCRText) }
        set { defaults.set(newValue, forKey: Key.saveOCRText) }
    }

    // MARK: - OCR

    var ocrLanguages: [String] {
        get { defaults.stringArray(forKey: Key.ocrLanguages) ?? ["zh-Hans", "en-US"] }
        set { defaults.set(newValue, forKey: Key.ocrLanguages) }
    }


    var autoCopyOCRText: Bool {
        get { defaults.bool(forKey: Key.autoCopyOCRText) }
        set { defaults.set(newValue, forKey: Key.autoCopyOCRText) }
    }

    // MARK: - 行为

    var playSound: Bool {
        get { defaults.bool(forKey: Key.playSound) }
        set { defaults.set(newValue, forKey: Key.playSound) }
    }

    var showCursor: Bool {
        get { defaults.bool(forKey: Key.showCursor) }
        set { defaults.set(newValue, forKey: Key.showCursor) }
    }

    /// 按偏好 key 取一个开关的状态。
    ///
    /// 给对账类自检用：它们手上只有 `ToggleTitles.all` 里那份 key，
    /// 不该再自己抄一张 key → 属性 的映射表（那张表本身又会变成一处真相的副本）。
    func isEnabled(forToggleKey key: String) -> Bool { defaults.bool(forKey: key) }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    var keepAlive: Bool {
        get { defaults.bool(forKey: Key.keepAlive) }
        set { defaults.set(newValue, forKey: Key.keepAlive) }
    }

    /// 保活**隐含开机自启**：launchd agent 带 RunAtLoad，本来就会在登录时把 app 拉起来。
    /// 两个开关因此不能各存各的 —— 默认值就正好是 `keepAlive=true / launchAtLogin=false`，
    /// 于是设置面板里出现过"保活开着、开机自启却没勾"这种自相矛盾的画面
    /// （而面板上那行字写的是"会一并开启开机自启"）。
    static func impliedLaunchAtLogin(keepAlive: Bool, launchAtLogin: Bool) -> Bool {
        keepAlive || launchAtLogin
    }

    /// 一条键管一对偏好：按下去之后这两条各是什么。
    ///
    /// 菜单和设置窗**共用这一份判断**。各自写一遍"顺手把另一条也改成一样"就是
    /// 第二份真相 —— 改了一处，另一处会安静地变成只动半对。
    static func autoStartPair(turningOn: Bool) -> (launchAtLogin: Bool, keepAlive: Bool) {
        (turningOn, turningOn)
    }

    /// 把上面那条不变式落回存储。返回是否改动过。
    @discardableResult
    func normalizeAutoStart() -> Bool {
        let wanted = Self.impliedLaunchAtLogin(keepAlive: keepAlive,
                                               launchAtLogin: launchAtLogin)
        guard wanted != launchAtLogin else { return false }
        launchAtLogin = wanted
        return true
    }

    // MARK: - 界面

    /// 隐藏菜单栏图标。app 仍常驻运行，热键照常可用。
    var hideStatusBarIcon: Bool {
        get { defaults.bool(forKey: Key.hideStatusBarIcon) }
        set { defaults.set(newValue, forKey: Key.hideStatusBarIcon) }
    }

    /// 是否已经给过首次运行引导。
    var didShowWelcome: Bool {
        get { defaults.bool(forKey: Key.didShowWelcome) }
        set { defaults.set(newValue, forKey: Key.didShowWelcome) }
    }

    // MARK: - 最近截图

    var recentShots: [String] {
        get { defaults.stringArray(forKey: Key.recentShots) ?? [] }
        set { defaults.set(Array(newValue.prefix(10)), forKey: Key.recentShots) }
    }

    func rememberShot(_ path: String) {
        var list = recentShots.filter { $0 != path }
        list.insert(path, at: 0)
        recentShots = list
    }

    /// 把已经不存在的截图从「最近截图」里摘掉，返回摘掉的条数。
    ///
    /// 菜单每次弹开都会逐个 `fileExists` 过滤**显示**，但只过滤不回写：死链一直
    /// 占着那 10 个格子，用户清过一轮截图目录之后，菜单里就只剩两三条"最近"了，
    /// 明明截了十张。这里顺手把账清了。
    /// 没有东西可摘时不碰偏好 —— 每次点开菜单都写一遍 UserDefaults 是没必要的抖动。
    @discardableResult
    func pruneRecentShots(exists: (String) -> Bool) -> Int {
        let live = Self.liveRecentShots(recentShots, exists: exists)
        let dropped = recentShots.count - live.count
        if dropped > 0 { recentShots = live }
        return dropped
    }

    /// 纯函数那一半（自检直接给它假的文件系统，不碰真偏好）。
    static func liveRecentShots(_ list: [String], exists: (String) -> Bool) -> [String] {
        list.filter(exists)
    }

    func forgetShot(_ path: String) {
        recentShots = recentShots.filter { $0 != path }
    }

    // MARK: - 热键

    private func readHotKey(_ key: String, fallback: HotKeySpec) -> HotKeySpec {
        guard let data = defaults.data(forKey: key),
              let spec = try? JSONDecoder().decode(HotKeySpec.self, from: data)
        else { return fallback }
        return spec
    }

    private func writeHotKey(_ key: String, _ spec: HotKeySpec) {
        guard let data = try? JSONEncoder().encode(spec) else { return }
        defaults.set(data, forKey: key)
    }

    /// 主截图热键：一个入口，窗口 / 区域 / 全屏三合一。
    var hotKeyCapture: HotKeySpec {
        get { readHotKey(Key.hotKeyCapture, fallback: .defaultCapture) }
        set { writeHotKey(Key.hotKeyCapture, newValue) }
    }

    func resetHotKeys() {
        hotKeyCapture = .defaultCapture
    }

    // MARK: - 文件名模板

    /// 支持 {date} {time} {datetime} {type}
    func renderFileName(type: String) -> String {
        Self.renderedName(fileNamePattern, type: type)
    }

    /// 用**任意**模板算一个示例名 —— 设置面板在不落盘的前提下实时预览结果。
    static func renderedName(_ pattern: String, type: String) -> String {
        sanitize(expand(pattern, type: type))
    }

    /// 只替换占位符，不做任何清洗。设置面板拿它和清洗后的结果一比，
    /// 就知道"用户写的东西我们动没动"，动了就得当场说清楚。
    static func expandedName(_ pattern: String, type: String) -> String {
        expand(pattern, type: type)
    }

    private static func expand(_ pattern: String, type: String) -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        formatter.dateFormat = "yyyyMMdd"
        let date = formatter.string(from: now)
        formatter.dateFormat = "HHmmss"
        let time = formatter.string(from: now)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let datetime = formatter.string(from: now)

        var name = pattern
        name = name.replacingOccurrences(of: "{datetime}", with: datetime)
        name = name.replacingOccurrences(of: "{date}", with: date)
        name = name.replacingOccurrences(of: "{time}", with: time)
        name = name.replacingOccurrences(of: "{type}", with: type)
        return name
    }

    /// 单个文件名成分的 UTF-8 字节预算。APFS 的上限是 255 字节，这里留出余量给
    /// 扩展名和同名撞车时追加的 `-2` / `-3`（最坏要加到三位数）。
    static let nameByteBudget = 180

    /// 认识的占位符。**设置面板上那行「可用占位符」也是从这儿拼出来的**，
    /// 免得说明书和实现各写一份、其中一份说谎。
    static let knownPlaceholders = ["{date}", "{time}", "{datetime}", "{type}"]

    /// 用户写了我们不认识的 `{...}`：不猜也不改，但**必须说出来** ——
    /// 不然 `{datetme}` 这种笔误会真的原样留在文件名里，用户还以为功能坏了。
    static func unknownPlaceholders(in pattern: String) -> [String] {
        var found: [String] = []
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{"),
              let close = rest[open...].firstIndex(of: "}") {
            let token = String(rest[open...close])
            if !knownPlaceholders.contains(token), !found.contains(token) {
                found.append(token)
            }
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    /// 展开 + 清洗之后，"对用户的模板动了哪几刀 / 有哪几处没看懂"。
    /// 面板显示的、自检查的都是这一份，所以不会和实现分家。
    static func templateIssues(pattern: String, type: String) -> [String] {
        var issues = unknownPlaceholders(in: pattern).map {
            "未知占位符 \($0) 会原样写进文件名"
        }
        let expanded = expand(pattern, type: type)
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        if expanded.rangeOfCharacter(from: illegal) != nil {
            issues.append("非法字符已换成 -")
        }
        if expanded.hasPrefix(".") { issues.append("开头的点已去掉（否则成了隐藏文件）") }
        if expanded.hasSuffix(".") { issues.append("末尾的点已去掉") }
        // 按预算判，不比字节数：去掉一个点也会让长度变短，
        // 那样"开头的点已去掉"会顺带把"超长已截断"也报出来 —— 说了没做的事。
        if expanded.utf8.count > nameByteBudget { issues.append("超长已截断") }
        return issues
    }

    static func sanitize(_ name: String) -> String {
        var name = name
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        name = name.components(separatedBy: illegal).joined(separator: "-")
        // 以点开头会被当成隐藏文件：用户只看得到"截图不见了"，Finder 里却搜不着。
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 末尾的点同样会惹麻烦（"名字." 加扩展名后变成 "名字..png"）。
        while name.hasSuffix(".") { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.utf8.count > nameByteBudget {
            // 按 Character 走，才不会把一个 emoji 或组合字母从中间截断成乱码。
            var cut = ""
            for character in name {
                if (cut + String(character)).utf8.count > nameByteBudget { break }
                cut.append(character)
            }
            name = cut.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? "Grabi" : name
    }
}
