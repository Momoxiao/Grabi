import Foundation
import CoreGraphics
import CoreText
import Vision
import AppKit

/// 基于 Vision 的本地 OCR。全程离线，不联网、不上传，识别在 Apple Neural Engine /
/// GPU 上跑，功耗和延迟都很低。
final class OCRRecognizer {

    /// 系统当前实际支持的语言集合。static let 是惰性初始化，只查一次系统。
    static let supportedLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        if let languages = try? request.supportedRecognitionLanguages(), !languages.isEmpty {
            return languages
        }
        return ["zh-Hans", "zh-Hant", "en-US"]
    }()

    /// 一条识别结果，带位置信息（归一化坐标，原点左下）。
    struct Line {
        let text: String
        let boundingBox: CGRect
        /// 更细的可选单元：中文一个字、拉丁一个词。界面靠它做"单选某一个字"。
        ///
        /// 为空表示拿不到字级坐标（老系统 / 特殊文本），界面会退化成整行选择。
        let units: [Unit]
    }

    /// 一个可选单元（一个汉字或一个英文词）。
    struct Unit {
        let text: String
        let boundingBox: CGRect
        /// 这个单元在原文里前面是否隔着空白。拼接选中结果时据此补空格，
        /// 否则 "Grabi OCR probe" 会被拼成 "GrabiOCRprobe"。
        let precededBySpace: Bool

        init(text: String, boundingBox: CGRect, precededBySpace: Bool = false) {
            self.text = text
            self.boundingBox = boundingBox
            self.precededBySpace = precededBySpace
        }
    }

    /// 识别图片中的文字，保留段落行结构。
    func recognize(_ image: CGImage, languages: [String]) async throws -> String {
        let lines = try await recognizeLines(image, languages: languages)
        return lines.map(\.text).joined(separator: "\n")
    }

    /// 识别并返回每一行的文本与位置，供界面做"点选某一行"。
    ///
    /// 带一层容错：某些环境下「指定识别语言」这一步会让 Vision 直接抛错，
    /// 这时退回去用系统默认语言再试一次，别让整条链路一起哑掉。
    func recognizeLines(_ image: CGImage, languages: [String]) async throws -> [Line] {
        do {
            return try await perform(image, languages: languages)
        } catch {
            Log.ocr.notice("带语言配置识别失败，改用系统默认语言重试：\(error.localizedDescription)")
            return try await perform(image, languages: nil)
        }
    }

    /// Vision 专用串行队列。**所有**对 `run(image:languages:)` 的调用都必须排在这条
    /// 队列上——预热、正式识别、以及界面浮出时的「抢跑」三者的入口。
    ///
    /// 原因：Vision 扛不住并发。预热要跑几十秒（首次加载语言纠正模型），
    /// 用户恰好在这期间截图 → 预览面板浮出 → 抢跑立刻也调一次 Vision。
    /// 两个请求同时在加载模型，后到的那个会抛
    /// `TextRecognition.CRImageReaderError 1`，而且**一旦抛了就会一直抛**
    /// （模型加载被打断后进入坏状态），表现就是"百分比复现"。
    ///
    /// 串行之后最坏情况只是抢跑排在预热后面多等一会儿，不会失败。
    private static let visionQueue = DispatchQueue(label: "com.grabi.vision", qos: .userInitiated)

    /// 真正的识别。`languages` 传 nil 表示不指定，交给系统按用户偏好决定。
    private func perform(_ image: CGImage, languages: [String]?) async throws -> [Line] {
        let effective = Self.resolve(languages)
        // 缩图只做一次，两轮重试（带语言 / 不带语言）共用同一张。
        let scaled = Self.downscale(image, maxSide: Self.tuning.maxSide)

        return try await withCheckedThrowingContinuation { continuation in
            // 排到 Vision 专用串行队列上（见 `visionQueue` 的注释）。
            Self.visionQueue.async {
                let timer = Stopwatch("ocr")
                // 新引擎（`RecognizeTextRequest.perform`）是 async 的，这里用信号量
                // 把整段 await 收敛成同步调用——**必须阻塞这条队列**，
                // 否则任务一撒开就等于没有串行，并发问题会原样回来。
                let semaphore = DispatchSemaphore(value: 0)
                var outcome: Result<[Line], Error>?
                Task {
                    do { outcome = .success(try await Self.run(image: scaled, languages: effective)) }
                    catch { outcome = .failure(error) }
                    semaphore.signal()
                }
                semaphore.wait()

                switch outcome {
                case .success(let lines):
                    timer.stop(Log.ocr)
                    continuation.resume(returning: lines)
                case .failure(let error):
                    let nsError = error as NSError
                    Log.ocr.error("识别失败 [\(nsError.domain, privacy: .public) \(nsError.code)]: \(nsError.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                case .none:
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    /// 把外部传入的语言收敛成 Vision 真正能用的列表。空数组表示"交给系统自动检测"。
    private static func resolve(_ languages: [String]?) -> [String] {
        guard let languages else { return [] }
        let usable = languages.filter { supportedLanguages.contains($0) }
        // 一个都匹配不上（用户在设置里勾了系统不支持的）就退回英文，
        // 别交给自动检测——那样会把中文也认错。
        return usable.isEmpty ? ["en-US"] : usable
    }

    /// 跑一次识别。正式识别和预热共用这一份配置，
    /// 否则预热加载的是 A 模型、真用的时候却是 B 模型，等于没预热。
    ///
    /// - macOS 15+ 走新的 `RecognizeTextRequest`（revision 3）。
    ///   旧 API（`VNRecognizeTextRequest`）在 macOS 26/27 上属于遗留路径，
    ///   冷启动要加载一整套 CoreML 模型，实测首次 2–60 秒且会进入
    ///   "抛 `CRImageReaderError 1` 就再也回不来"的坏状态。
    ///   新 API 是 Swift 原生请求，走的是同一套系统模型但**加载路径不同**，
    ///   而且不经过那条会崩的 CoreRecognition 通道。
    /// - 更老的系统（macOS 14）自动回落到旧 API，功能一致。
    private static func run(image: CGImage, languages: [String]) async throws -> [Line] {
        if tuning.engine == .modern, #available(macOS 15.0, *) {
            do {
                return try await runModern(image: image, languages: languages)
            } catch {
                // 新引擎万一失败，退回旧 API 再试一次，别让用户直接吃闭门羹
                let nsError = error as NSError
                Log.ocr.error("新引擎失败，回落旧引擎 [\(nsError.domain, privacy: .public) \(nsError.code)]")
                return try runLegacy(image: image, languages: languages)
            }
        }
        return try runLegacy(image: image, languages: languages)
    }

    // MARK: 新引擎（macOS 15+）

    @available(macOS 15.0, *)
    private static func runModern(image: CGImage, languages: [String]) async throws -> [Line] {
        var request = RecognizeTextRequest(.revision3)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        // 与旧 API 同样的硬约束：两个语言开关必须由同一个条件推导。
        // 「不设 recognitionLanguages + automaticallyDetectsLanguage = false」
        // 会让 Vision 不知道该用哪套模型，卡住后报错。
        // 注意要按**过滤之后**的结果判断：用户选的语言可能被新版引擎全部过滤掉，
        // 那时若还按"传进来了几个"设 false，就会正好落进上面那个坏组合。
        let supported = Set(request.supportedRecognitionLanguages)
        let resolved = languages
            .map { Locale.Language(identifier: $0) }
            .filter { supported.contains($0) }
        request.recognitionLanguages = resolved
        request.automaticallyDetectsLanguage = resolved.isEmpty

        if tuning.minimumTextHeight > 0 {
            request.minimumTextHeightFraction = tuning.minimumTextHeight
        }

        let observations = try await request.perform(on: image)
        return assembleModern(observations)
    }

    // MARK: 旧引擎（macOS 14 及更早）

    private static func runLegacy(image: CGImage, languages: [String]) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // 别为了"省时间"把它关掉。看着像是少加载一个模型会更快，实测并非如此：
        // 关掉之后首次识别反而可能在 30 秒量级，且结果更差（会把 "macoS"
        // 这类错字原样留着）。保持开启，把省时间的力气花在「预热」和「缩图」上。
        request.usesLanguageCorrection = true

        let detectsLanguage = languages.isEmpty
        if !detectsLanguage {
            request.recognitionLanguages = languages
        }
        request.automaticallyDetectsLanguage = detectsLanguage

        if tuning.minimumTextHeight > 0 {
            request.minimumTextHeight = tuning.minimumTextHeight
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return assembleLegacy(request.results ?? [])
    }

    // MARK: - 标点归一

    /// 拉丁/代码为主的文本里，把被误认成全角的括号、逗号还原成半角。
    ///
    /// 实测（`--ocr-quality`）：`recognitionLanguages` 里 zh-Hans 排在 en-US 前时，
    /// Vision 会把代码里的半角标点按中文习惯输出成全角——
    ///
    /// ```
    /// 期望 func recognize(_ image: CGImage) async throws -> [Line] {
    /// 实际 func recognize（_ image: CGImage）async throws ->［Line］｛
    /// ```
    ///
    /// 代码场景的整体相似度因此只有 94.1%，错的全在这。而中文正文里全角括号
    /// 是对的，所以只在「这一行以拉丁字符为主 **且** 带代码特征」时才转。
    ///
    /// 只做**等长**替换：`splitUnits` 里按原文本算的 range 仍然对得上，
    /// 字级高亮框不会错位。
    private static func normalizePunctuation(_ text: String) -> String {
        let pairs: [Character: Character] = [
            "（": "(", "）": ")",
            "［": "[", "］": "]",
            "｛": "{", "｝": "}",
            "，": ",", "：": ":", "；": ";"
        ]
        guard text.contains(where: { pairs[$0] != nil }) else { return text }

        let meaningful = text.filter { !$0.isWhitespace }
        guard !meaningful.isEmpty else { return text }

        // 拉丁字母 / 数字占多数，才可能是代码或英文内容
        let latin = meaningful.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.count
        guard Double(latin) / Double(meaningful.count) >= 0.6 else { return text }

        // 再加一道代码特征，避免把 "Grabi（轻量截图工具）" 这类正常中文也转掉
        let hints = ["->", "_", ";", "=", "<", ">", "|", "&", ":", "(", ")", "[", "]", "{", "}"]
        guard hints.contains(where: { text.contains($0) }) else { return text }

        return String(text.map { pairs[$0] ?? $0 })
    }

    // MARK: - 缩图

    /// 识别相关的可调参数。
    ///
    /// 存在的唯一目的是给 `--ocr-quality` 做 A/B：正常路径永远用 `Tuning()` 的默认值，
    /// 只有基准命令会临时改它。这样调参不用往设置里塞一堆用户看不懂的开关。
    struct Tuning {
        /// 送进 Vision 之前允许的最大边长（0 表示不缩）。
        var maxSide: CGFloat = 2048
        /// `minimumTextHeight`，0 表示用系统默认。
        /// 调高可以跳过画面里的细小噪点，但也可能漏掉真正的小字。
        var minimumTextHeight: Float = 0
        /// 用哪套识别引擎。
        var engine: Engine = .modern
    }

    /// 识别引擎。
    ///
    /// - `modern`：`RecognizeTextRequest`（macOS 15+，revision 3）。
    /// - `legacy`：`VNRecognizeTextRequest`，旧系统兜底。
    ///
    /// 留这个开关只是为了给 `--ocr-quality --ab` 做对照测量，
    /// 正常路径永远用默认值。
    enum Engine {
        case modern
        case legacy
    }

    nonisolated(unsafe) static var tuning = Tuning()

    /// 送进 Vision 之前允许的最大边长（像素）。
    ///
    /// Retina 屏一张 1600×900 的选区进来就是 3200×1800，4K/5K 屏更大。
    /// 文字检测的开销随像素数走，但屏幕上真正需要看清的字并不会因为
    /// 图变大而变小——多出来的像素是白烧的。Umi-OCR 也有同款设置
    /// （「限制图像边长」）。
    ///
    /// 2048 是留了余量的：常见的 1080p/2K 选区原样进，只有超大图才缩。
    /// 归一化坐标不受影响，高亮框该在哪还在哪。
    private static func downscale(_ image: CGImage, maxSide: CGFloat) -> CGImage {
        guard maxSide > 0 else { return image }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > maxSide else { return image }

        let ratio = maxSide / longest
        let targetWidth = max(Int((width * ratio).rounded()), 1)
        let targetHeight = max(Int((height * ratio).rounded()), 1)

        guard let context = CGContext(data: nil,
                                      width: targetWidth,
                                      height: targetHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { return image }

        Log.ocr.info("缩图 \(image.width, privacy: .public)×\(image.height, privacy: .public) → \(scaled.width, privacy: .public)×\(scaled.height, privacy: .public)")
        return scaled
    }

    // MARK: - 预热

    /// 预热的排程账本。
    ///
    /// 单独拎出来是因为「正在跑的时候又来了一个请求」这一支最容易写错，而写错的
    /// 后果是**静默的**：旧写法直接 `return`，那一轮加载的还是改之前的语言，跑完
    /// 又把"暖好了"挂回去 —— 用户接着点「识别文字」照样等几十秒，而这正是这段
    /// 代码存在的理由。勾选语言时连点几个框、或者启动预热还没跑完就改了设置，
    /// 都会踩到。
    struct WarmUpScheduler {
        private(set) var warming = false
        private(set) var warm = false
        private(set) var pending = false
        /// 正在跑的（或已经跑完的那）一轮用的是哪套语言。
        private(set) var loaded: [String] = []

        /// 一次预热请求的下场。`true` = 调用方现在就去排队真跑一轮。
        mutating func begin(languages: [String], force: Bool) -> Bool {
            if warming {
                // 这一轮已经来不及了。欠一次补跑，同时把"暖了"摘掉：
                // 留着它就是在骗 UI，也是在骗用户。
                if force || languages != loaded {
                    warm = false
                    pending = true
                }
                return false
            }
            if warm && !force && languages == loaded { return false }
            warming = true
            warm = false
            loaded = languages
            return true
        }

        /// 一轮跑完。`true` = 还欠着一轮，调用方要用**当时的**配置再排一次。
        mutating func end() -> Bool {
            warming = false
            guard pending else {
                warm = true
                return false
            }
            pending = false
            warm = false
            return true
        }
    }

    private static let warmUpLock = NSLock()
    private static var scheduler = WarmUpScheduler()

    /// 真跑一轮要做的两件事：去哪拿配置、怎么跑。自检把两个都换成假的——
    /// 真跑一次要等模型加载（实测 2–32 秒），而且会把用户的语言偏好卷进来。
    private struct WarmUpSeam {
        var current: () -> [String]
        var runner: ([String]) -> Void
    }

    private static var seam = WarmUpSeam(
        current: { resolve(SettingsStore.shared.ocrLanguages) },
        runner: { runWarmUp($0) }
    )

    /// 模型是否已经预热好。UI 用它决定要不要提示"首次识别需要加载模型"。
    static var isWarm: Bool {
        warmUpLock.lock(); defer { warmUpLock.unlock() }
        return scheduler.warm
    }

    /// 后台预热：拿一张极小的图跑一次完整识别，把 Vision 的模型提前加载好。
    ///
    /// 冷启动实测（同一台机器、同一张图、独立进程）：**首次识别 2–32 秒**，
    /// 之后稳定在 ~180 ms。差距的大头是语言纠正模型（开 32.5s / 关 2.0s），
    /// 那份代价每台机器（或每次开机）只付一次，但用户恰好会在那一刻点
    /// 「识别文字」——表现就是"点了没反应"。所以 app 启动后立刻在后台
    /// 静默跑一次，把这份代价提前付掉。
    ///
    /// - Parameter force: 已经预热过也要再跑一次。改了识别配置（比如打开
    ///   语言纠正）之后必须强制，否则加载的还是旧配置那套模型。
    static func warmUp(force: Bool = false) {
        warmUpLock.lock()
        let languages = seam.current()
        let shouldRun = scheduler.begin(languages: languages, force: force)
        warmUpLock.unlock()
        guard shouldRun else { return }

        // 和正式识别走同一条串行队列（见 `visionQueue` 的注释）。
        // userInitiated 而不是 default：预热本来就是为了让用户少等，
        // 排得太靠后就没意义了；串行保证它不会跟识别并发，不会互相打断。
        visionQueue.async {
            seam.runner(languages)
            warmUpLock.lock()
            let owesAnother = scheduler.end()
            warmUpLock.unlock()
            // 补跑读的是**此刻**的配置，不是请求当时那份：用户在预热期间又改了
            // 两次语言的话，最后留下的那套才算数。
            if owesAnother { warmUp(force: true) }
        }
    }

    /// 真跑一轮 Vision。调用方已经把整件事排在串行队列上，这里可以阻塞。
    private static func runWarmUp(_ languages: [String]) {
        guard let image = makeWarmUpImage() else { return }
        let timer = Stopwatch("ocr.warmup")
        // 同样要把 async 的引擎调用收敛成同步，并阻塞住这条串行队列
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let lines = try await run(image: image, languages: languages)
                Log.ocr.info("预热完成，识别到 \(lines.count, privacy: .public) 行")
            } catch {
                let nsError = error as NSError
                Log.ocr.error("预热失败 [\(nsError.domain, privacy: .public) \(nsError.code)]")
            }
            timer.stop(Log.ocr)
            semaphore.signal()
        }
        semaphore.wait()
    }

    // MARK: - 自检用的预热把手

    /// 自检快照：排程账本此刻的样子。
    static func warmUpStateForSelfTest() -> (warming: Bool, warm: Bool, pending: Bool, loaded: [String]) {
        warmUpLock.lock(); defer { warmUpLock.unlock() }
        return (scheduler.warming, scheduler.warm, scheduler.pending, scheduler.loaded)
    }

    /// 自检之间互不干扰：把账本归零，免得上一条留下的 `warm` 让这一条白过。
    static func resetWarmUpForSelfTest() {
        warmUpLock.lock()
        scheduler = WarmUpScheduler()
        warmUpLock.unlock()
    }

    /// 临时换掉"去哪拿配置 / 怎么跑一轮"，`body` 跑完原样还原。
    ///
    /// 换掉 `runner` 之后自检才能连点几次请求还不真的加载模型；换掉 `current`
    /// 才能在不碰用户语言偏好的前提下量到"改配置之后补跑的是新配置"。
    static func withWarmUpSeam<T>(current: @escaping () -> [String],
                                  runner: @escaping ([String]) -> Void,
                                  _ body: () -> T) -> T {
        warmUpLock.lock()
        let saved = seam
        seam = WarmUpSeam(current: current, runner: runner)
        warmUpLock.unlock()
        defer {
            warmUpLock.lock()
            seam = saved
            warmUpLock.unlock()
        }
        return body()
    }

    /// 等串行队列上的预热（含补跑）全部落地。自检用，带超时——超时是"没落地"，
    /// 由调用方的断言去红，而不是在这儿悄悄返回。
    static func waitForWarmUpQueue(timeoutSeconds: Double) {
        let done = DispatchSemaphore(value: 0)
        visionQueue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeoutSeconds)
    }

    /// 预热用的小图。**必须画真的字**——只画色块的话文字检测阶段找不到任何
    /// 文本区域，识别模型可能压根不加载，预热就白做了。
    ///
    /// 这里刻意不用 `NSBitmapImageRep` / `NSGraphicsContext` / `NSString.draw`：
    /// 预热跑在 `visionQueue` 后台线程上，而 AppKit 的绘图不是线程安全的。
    /// 那种错法很安静——图可能画成空白（预热"成功"但没加载模型，用户第一次
    /// 识别仍要等几十秒），也可能在别的系统版本上直接崩。CoreGraphics + CoreText
    /// 本来就是线程安全的，画出来的东西也和这里要的一模一样。
    private static func makeWarmUpImage() -> CGImage? {
        let width = 120, height = 44
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)
                                          ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        guard let text = CFAttributedStringCreate(nil, "Grabi 8" as CFString,
                                                  attributes as CFDictionary) else { return nil }
        let line = CTLineCreateWithAttributedString(text)
        context.textPosition = CGPoint(x: 4, y: 10)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    // MARK: - 结果装配

    /// 一个文本片段。两条引擎路径都先归一到这个结构，再共用同一套"按视觉行重组"。
    private struct Fragment {
        let text: String
        let box: CGRect
        /// 这一段的字/词级单元。
        let units: [Unit]
    }

    /// 把「规范化文本」里的 range 映射回 Vision 原始候选文本里的 range。
    ///
    /// `normalizePunctuation` 只保证**字符数**不变（全角括号 → 半角），UTF-8
    /// 字节长度会变。`String.Index` 绑定它来源的那个字符串，直接把 normalized
    /// text 的 index 交给 `candidate.boundingBox(for:)`，Vision 会按错误的位置
    /// 取字（实测偏一整个字符），字级高亮框随之错位。所以这里按 Character
    /// offset 重建区间。
    private static func sourceRange(_ range: Range<String.Index>,
                                    in text: String,
                                    original: String) -> Range<String.Index>? {
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        guard let start = original.index(original.startIndex, offsetBy: lower,
                                         limitedBy: original.endIndex),
              let end = original.index(start, offsetBy: upper - lower,
                                       limitedBy: original.endIndex) else { return nil }
        return start..<end
    }

    /// 旧引擎的观测 → 片段。
    private static func assembleLegacy(_ observations: [VNRecognizedTextObservation]) -> [Line] {
        let fragments: [Fragment] = observations.compactMap { observation -> Fragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let original = candidate.string
            let text = Self.normalizePunctuation(original)
            // 旧 API 的 `boundingBox(for:)` 是 throwing 的，取不到就跳过
            let boxProvider: (Range<String.Index>) -> CGRect? = { range in
                guard let source = Self.sourceRange(range, in: text, original: original)
                else { return nil }
                return try? candidate.boundingBox(for: source)?.boundingBox
            }
            let units = splitUnits(of: text, box: boxProvider)
            return Fragment(text: text,
                            box: observation.boundingBox,
                            units: units.isEmpty ? [Unit(text: text, boundingBox: observation.boundingBox)] : units)
        }
        return lines(from: fragments)
    }

    /// 新引擎的观测 → 片段。
    @available(macOS 15.0, *)
    private static func assembleModern(_ observations: [RecognizedTextObservation]) -> [Line] {
        let fragments: [Fragment] = observations.compactMap { observation -> Fragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let original = candidate.string
            let text = Self.normalizePunctuation(original)
            // 新 API 的同名方法是可选返回，不抛错
            // 新 API 的 `boundingBox` 是 NormalizedRect，取 `cgRect` 才是 CGRect
            let boxProvider: (Range<String.Index>) -> CGRect? = { range in
                guard let source = Self.sourceRange(range, in: text, original: original)
                else { return nil }
                return candidate.boundingBox(for: source)?.boundingBox.cgRect
            }
            let units = splitUnits(of: text, box: boxProvider)
            let box = observation.boundingBox.cgRect
            return Fragment(text: text,
                            box: box,
                            units: units.isEmpty ? [Unit(text: text, boundingBox: box)] : units)
        }
        return lines(from: fragments)
    }

    /// 把若干文本块按视觉行重组。
    ///
    /// Vision 会把同一行的左右两段拆成两个 observation，直接换行拼接会得到
    /// 破碎的结果；这里先按纵向位置聚成行，再在行内按横向顺序拼接。
    private static func lines(from fragments: [Fragment]) -> [Line] {
        guard !fragments.isEmpty else { return [] }

        // 自上而下（归一化坐标里 y 越大越靠上）
        let sorted = fragments.sorted { $0.box.midY > $1.box.midY }

        var groups: [[Fragment]] = []
        for fragment in sorted {
            if var last = groups.last, let reference = last.first {
                let tolerance = max(reference.box.height, fragment.box.height) * 0.55
                if abs(reference.box.midY - fragment.box.midY) <= tolerance {
                    last.append(fragment)
                    groups[groups.count - 1] = last
                    continue
                }
            }
            groups.append([fragment])
        }

        // Vision 常把一行拆成多个 observation，段与段之间的空格是**拼的时候补的**，
        // 所以要同步给该段的首个单元打上 "前面有空格"，否则界面按单元拼回去时会丢这些空格。
        return groups.map { group -> Line in
            let ordered = group.sorted { $0.box.minX < $1.box.minX }

            var text = ""
            var lineUnits: [Unit] = []

            for (offset, fragment) in ordered.enumerated() {
                var needsSpace = false
                if offset > 0,
                   fragment.text.first?.isWhitespace != true,
                   let last = text.last, let first = fragment.text.first {
                    // 中日韩之间不加空格，拉丁语系加空格
                    needsSpace = !(isCJK(last) && isCJK(first))
                }
                if needsSpace { text += " " }
                text += fragment.text

                var units = fragment.units
                if needsSpace, let first = units.first, !first.precededBySpace {
                    units[0] = Unit(text: first.text,
                                    boundingBox: first.boundingBox,
                                    precededBySpace: true)
                }
                lineUnits.append(contentsOf: units)
            }

            let union = ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
            return Line(text: text, boundingBox: union, units: lineUnits)
        }
    }

    // MARK: - 字 / 词级切分

    /// 把一段识别文本切成可选单元：中文**一个字**一个单元，拉丁**一个词**一个单元。
    ///
    /// 为什么不是统一按字符切：英文按字符选会变成"点 H 只选中 H"，拷贝体验很差。
    /// 位置由 `box` 回调按 range 取——新旧两套引擎的取法不一样
    /// （一个 throwing、一个可选返回），所以做成回调而不是各自实现一遍。
    private static func splitUnits(of text: String,
                                   box: (Range<String.Index>) -> CGRect?) -> [Unit] {
        var result: [Unit] = []
        var start = text.startIndex
        /// 记录当前位置之前是否吞掉了空白（空白本身不生成单元）
        var sawSpace = false

        func append(_ range: Range<String.Index>) {
            // 取不到字级坐标就跳过这一步，后面由观测框兜底
            guard let rectangle = box(range) else { return }
            let piece = String(text[range])
            guard !piece.isEmpty else { return }
            result.append(Unit(text: piece,
                               boundingBox: rectangle,
                               precededBySpace: sawSpace))
            sawSpace = false
        }

        while start < text.endIndex {
            let character = text[start]

            if isCJK(character) {
                // CJK：逐字
                let end = text.index(after: start)
                append(start..<end)
                start = end
                continue
            }

            if character.isWhitespace || character.isNewline {
                sawSpace = true
                start = text.index(after: start)
                continue
            }

            // 拉丁：连续的字母/数字算一个词，遇到空白或汉字断开
            var end = start
            while end < text.endIndex {
                let next = text[end]
                if next.isWhitespace || next.isNewline || isCJK(next) { break }
                end = text.index(after: end)
            }
            append(start..<end)
            start = end
        }

        return result
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,   // CJK 标点
             0x3040...0x30FF,   // 假名
             0x3400...0x4DBF,   // 扩展 A
             0x4E00...0x9FFF,   // 基本区
             0xF900...0xFAFF,   // 兼容汉字
             0xAC00...0xD7AF,   // 谚文
             0xFF00...0xFFEF:   // 全角
            return true
        default:
            return false
        }
    }
}
