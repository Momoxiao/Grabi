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

    /// 设置窗的滑杆范围就是这个区间；旧偏好或手工改过的 defaults 里若存了
    /// 越界值，直接交给 ImageIO 会得到 0% 或非法的压缩质量。
    static let jpegQualityRange: ClosedRange<Double> = 0.3...1.0
    static let defaultJPEGQuality = 0.9
    static let defaultSaveDirectory = NSString(string: "~/Pictures/Grabi").expandingTildeInPath

    static func clampedJPEGQuality(_ value: Double) -> Double {
        guard value.isFinite else { return defaultJPEGQuality }
        return min(max(value, jpegQualityRange.lowerBound), jpegQualityRange.upperBound)
    }

    /// 旧版本 / 手工改过的 defaults 里可能存着单修饰键组合。那种组合注册到
    /// Carbon 后会把 ⌘C、⌃A 这类全局键抢走，系统却不会报错；读出来时退回默认值。
    static func sanitizedHotKey(_ spec: HotKeySpec, fallback: HotKeySpec) -> HotKeySpec {
        if spec.isDisabled { return spec }
        return spec.modifierCount >= 2 ? spec : fallback
    }

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
            Key.saveDirectory:   Self.defaultSaveDirectory,
            Key.fileNamePattern: "Grabi-{date}-{time}",
            Key.imageFormat:     ImageFormat.png.rawValue,
            Key.jpegQuality:     Self.defaultJPEGQuality,
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
        get {
            let raw = defaults.string(forKey: Key.saveDirectory) ?? ""
            // 空串会让 URL(fileURLWithPath:) 落到当前工作目录（.app 启动时是 /）：
            // 截图看似保存成功，用户却在图片文件夹里找不到。旧偏好里存过空串时
            // 必须回退到注册默认值。
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultSaveDirectory : raw
        }
        set { defaults.set(newValue, forKey: Key.saveDirectory) }
    }

    var saveDirectoryURL: URL {
        URL(fileURLWithPath: NSString(string: saveDirectory).expandingTildeInPath, isDirectory: true)
    }

    @discardableResult
    func ensureSaveDirectory() -> Bool {
        let url = saveDirectoryURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            // 同名文件会把 createDirectory 顶回来；这里若回报 true，诊断和启动
            // 都会说"目录可用"，直到用户真的截图才看到写入失败。
            return isDirectory.boolValue
        }
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
        get {
            guard defaults.object(forKey: Key.jpegQuality) != nil else {
                return Self.defaultJPEGQuality
            }
            return Self.clampedJPEGQuality(defaults.double(forKey: Key.jpegQuality))
        }
        set { defaults.set(Self.clampedJPEGQuality(newValue), forKey: Key.jpegQuality) }
    }

    var saveOCRText: Bool {
        get { defaults.bool(forKey: Key.saveOCRText) }
        set { defaults.set(newValue, forKey: Key.saveOCRText) }
    }

    // MARK: - OCR

    var ocrLanguages: [String] {
        get {
            let list = defaults.stringArray(forKey: Key.ocrLanguages) ?? []
            // 空数组会让设置面板显示"一个语言都没选"，而 OCR 实际会退回英文；
            // 旧偏好里存过空数组时按默认值处理，别让界面和实际行为分家。
            return list.isEmpty ? ["zh-Hans", "en-US"] : list
        }
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
        // 老版本没有写入上限，读到超过 10 条的旧偏好也要按当前上限收回来，
        // 否则菜单会显示一长串"最近截图"。
        get { Array((defaults.stringArray(forKey: Key.recentShots) ?? []).prefix(10)) }
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
        return Self.sanitizedHotKey(spec, fallback: fallback)
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
        let cleaned = cleanTemplate(expand(pattern, type: type))
        if cleaned.hadIllegal { issues.append("非法字符已换成 -") }
        if cleaned.hadLeadingDot { issues.append("开头的点已去掉（否则成了隐藏文件）") }
        if cleaned.hadTrailingDot { issues.append("末尾的点已去掉") }
        // 按**清洗后**的字节数判：行尾空白和末尾的点本来就会被剥掉，拿清洗前的
        // 长度判会把没做的"截断"也说成做了；反过来，先 trim 再判也不会漏掉
        // "空白 + 点"开头的隐藏文件。
        if cleaned.text.utf8.count > nameByteBudget { issues.append("超长已截断") }
        return issues
    }

    /// 把模板展开结果清洗到"能直接当文件名"的那一步，并报告动过哪几刀。
    /// `sanitize` 和 `templateIssues` 共用这一份，面板上的提示不会和落盘行为分家。
    private static func cleanTemplate(_ expanded: String)
        -> (text: String, hadIllegal: Bool, hadLeadingDot: Bool, hadTrailingDot: Bool) {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let hadIllegal = expanded.rangeOfCharacter(from: illegal) != nil
        var text = expanded.components(separatedBy: illegal).joined(separator: "-")
        var hadLeadingDot = false
        var hadTrailingDot = false

        // 先 trim 再剥点：模板写成「 .截图」时，如果先剥点再 trim，开头那个
        // 空白会把点"藏"过去，最后仍存成隐藏文件。
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix(".") {
            hadLeadingDot = true
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 末尾的点同样会惹麻烦（"名字." 加扩展名后变成 "名字..png"）。
        while text.hasSuffix(".") {
            hadTrailingDot = true
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (text, hadIllegal, hadLeadingDot, hadTrailingDot)
    }

    static func sanitize(_ name: String) -> String {
        var name = cleanTemplate(name).text

        if name.utf8.count > nameByteBudget {
            // 按 Character 走，才不会把一个 emoji 或组合字母从中间截断成乱码。
            var cut = ""
            for character in name {
                if (cut + String(character)).utf8.count > nameByteBudget { break }
                cut.append(character)
            }
            name = cut.trimmingCharacters(in: .whitespacesAndNewlines)
            // 截断点可能正好落在末尾的点上；剥点的规则必须在截断之后再跑一次，
            // 否则会得到「名字.」+「.png」=「名字..png」。
            while name.hasSuffix(".") {
                name.removeLast()
                name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return name.isEmpty ? "Grabi" : name
    }
}
