import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 把 CGImage 按配置写到磁盘。
enum ImageWriter {

    static func utType(for format: ImageFormat) -> UTType {
        switch format {
        case .png:  return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }

    /// 写入图片，返回落盘路径。同名自动加 -2 / -3 后缀，不会覆盖已有文件。
    ///
    /// - Parameter sourceRect: 选区在屏幕坐标系里的位置。倍率要按**被截的那块屏**算，
    ///   传了它才能在外接 1x 屏上写出 72dpi 而不是 144dpi；不传退回主屏。
    @discardableResult
    static func write(_ image: CGImage, type: String, sourceRect: NSRect? = nil) throws -> URL {
        let settings = SettingsStore.shared
        let dir = settings.saveDirectoryURL

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw CaptureError.writeFailed(error.localizedDescription)
        }

        let format = settings.imageFormat
        let baseName = settings.renderFileName(type: type)
        let ext = format.fileExtension

        var url = dir.appendingPathComponent(baseName).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(baseName)-\(index)").appendingPathExtension(ext)
            index += 1
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         utType(for: format).identifier as CFString,
                                                         1,
                                                         nil) else {
            throw CaptureError.writeFailed("无法创建图像输出目标")
        }

        var properties: [CFString: Any] = [:]
        if format == .jpeg || format == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = settings.jpegQuality
        }
        // 写入正确的 DPI，别让别的 app 按 72dpi 放大显示
        let scale = sourceRect.map { ScreenGeometry.scale(of: $0) }
            ?? NSScreen.main?.backingScaleFactor ?? 2
        applyDPI(scale: scale, to: &properties)

        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.writeFailed("图像编码失败")
        }

        Log.capture.info("已保存 \(url.path, privacy: .public)")
        return url
    }

    /// 覆盖写入（用于就地预览调整选区后重新截取并保存）。
    ///
    /// 编码格式**跟着目标文件的扩展名走**，而不是当前设置：截图后用户可能改过格式，
    /// 若按新格式编码却写回旧扩展名的文件，就会出现「JPEG 数据装进 .png」这种错位。
    ///
    /// `dpi` 是给"目标路径上已经读不到原 DPI"的调用方用的。不传就照旧从目标路径上读。
    @discardableResult
    static func overwrite(_ image: CGImage, at url: URL,
                          dpi: (width: Double, height: Double)? = nil) throws -> URL {
        let format = ImageFormat.allCases
            .first { $0.fileExtension.caseInsensitiveCompare(url.pathExtension) == .orderedSame }
            ?? SettingsStore.shared.imageFormat
        // 覆盖写必须把原文件自带的 DPI 带上。预览里改选区重截走这条路，
        // 以前一个 DPI 都不写，图就打回 72dpi —— 同一张截图裁一刀再插进文档，
        // 尺寸凭空大一倍。原文件没标注（不是本 app 写的）就不猜，保持不标注。
        // 读要在建目标之前：目标一旦创建，旧内容随时可能没了。
        let carriedDPI = dpi ?? existingDPI(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         utType(for: format).identifier as CFString,
                                                         1,
                                                         nil) else {
            throw CaptureError.writeFailed("无法创建图像输出目标")
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg || format == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = SettingsStore.shared.jpegQuality
        }
        if let dpi = carriedDPI {
            properties[kCGImagePropertyDPIWidth] = dpi.width
            properties[kCGImagePropertyDPIHeight] = dpi.height
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.writeFailed("图像编码失败")
        }
        return url
    }

    /// 同名 `.txt` 落在哪儿。写和"告诉用户写没写成"必须算同一个路径。
    static func textURL(alongside imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("txt")
    }

    /// 把 OCR 文本写成同名 .txt（与图片放一起，便于溯源对照）。
    ///
    /// 抛错不要吞：设置里勾了「保存识别文本」却没落盘，等于替用户做了一个他没同意的决定。
    @discardableResult
    static func writeText(_ text: String, alongside imageURL: URL) throws -> URL {
        let txtURL = textURL(alongside: imageURL)
        try text.write(to: txtURL, atomically: true, encoding: .utf8)
        return txtURL
    }

    /// 识别文本落盘后接在状态行/角标后面的那半句。抽成纯函数是为了让自检能查它：
    /// 成功和失败**必须一眼分得出来**，失败不许出现"已存"字样。
    static func ocrTextStatus(wrote: Bool, txtURL: URL, reason: String?) -> String {
        wrote ? "　·　已存 \(txtURL.lastPathComponent)"
              : "　·　\(txtURL.lastPathComponent) 没写成功：\(reason ?? "未知原因")"
    }

    /// 图**还没落盘**时那句预告（默认的截图流程就是这个状态）。
    ///
    /// 这条存在的理由：勾了「识别结果存成同名 .txt」却一个字都没写、又不吭声，
    /// 用户接下来会去截图目录找那个文件 —— 找不到的是他以为已经有的东西。
    /// 现在默认不落盘，所以"当场写"变成了"按「保存」时一起写"，那句话得说准。
    static let ocrTextPendingStatus = "　·　按「保存」后一并存成同名 .txt"

    /// 丢弃截图：移到废纸篓（可恢复），连同名 .txt 一起。
    /// 用 trashItem 而不是 removeItem：误点「丢弃」还能从废纸篓里捞回来。
    ///
    /// **失败必须抛出去。**原来这里是 `try?`：移不进去也照样往下走，界面演完
    /// 「已丢弃」、最近截图列表里划掉、剪贴板也清了，而文件还原封不动躺在截图目录里 ——
    /// 只读挂载点、外置盘、网络盘、被 chmod 过的目录都会真的报
    /// `NSCocoaErrorDomain 513`（实测），用户只会觉得"废纸篓里怎么没有"。
    /// 同名 `.txt` 是附属品，尽力而为：主图已经移走，旁车挪不动不值得把成功说成失败。
    static func discard(_ url: URL) throws {
        let fm = FileManager.default
        // 已经不在了（重复点、或别的东西挪走了）不算失败：没东西可丢，也没什么要谎报。
        guard fm.fileExists(atPath: url.path) else { return }
        _ = try trash(url)
        let txtURL = textURL(alongside: url)
        if fm.fileExists(atPath: txtURL.path) {
            _ = try? trash(txtURL)
        }
        Log.capture.info("已丢弃 \(url.lastPathComponent, privacy: .public)")
    }

    /// 挪进废纸篓，并尽量把**落点**报回来（拿不到就返回 nil：文件确实挪走了，
    /// 只是这台机器没告诉我们去哪儿 —— 那种情况下话术不能替它编一个路径）。
    ///
    /// 「丢弃」不需要知道去哪儿，但把落点报回来是这条函数给调用方的能力。
    /// 各写一遍 `trashItem` 的话，将来一边修了（比如只读挂载点那个 513）
    /// 另一边不会跟着好。
    private static func trash(_ url: URL) throws -> URL? {
        var moved: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &moved)
        return moved as URL?
    }

    /// 丢弃失败时给用户看的那两行。抽成纯函数是为了让 `--logic-selftest` 能量它：
    /// 必须明说"还在原处"、必须带上具体路径（只说"没权限"等于让人自己去找那个文件）。
    static func discardFailureText(url: URL, reason: String) -> String {
        "\(reason)\n文件还在原处：\(url.path)"
    }

    private static func applyDPI(scale: CGFloat, to properties: inout [CFString: Any]) {
        let dpi = ScreenGeometry.dpi(scale: scale)
        properties[kCGImagePropertyDPIWidth] = dpi
        properties[kCGImagePropertyDPIHeight] = dpi
    }

    /// 读回文件已有的 DPI。没有标注（或读不出来）就返回 nil，让调用方保持不标注。
    private static func existingDPI(at url: URL) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyDPIWidth] as? NSNumber,
              let height = props[kCGImagePropertyDPIHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        return (width.doubleValue, height.doubleValue)
    }

    /// 自检用：读出一个文件头里标注的 DPI（读不到返回 nil）。
    static func dpiWidthForSelfTest(of url: URL) -> Double? {
        existingDPI(at: url)?.width
    }

    static func fileSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int64) ?? 0
    }
}
