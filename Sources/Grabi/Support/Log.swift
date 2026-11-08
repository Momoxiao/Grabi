import Foundation
import os

/// 统一日志出口。走 os_log（OSLog），几乎零开销，可在「控制台」里用
/// subsystem == com.momoxiao.grabi 过滤。
enum Log {
    private static let subsystem = "com.momoxiao.grabi"

    static let app     = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let ocr     = Logger(subsystem: subsystem, category: "ocr")
    static let system  = Logger(subsystem: subsystem, category: "system")
    static let hotkey  = Logger(subsystem: subsystem, category: "hotkey")
    static let ui      = Logger(subsystem: subsystem, category: "ui")
}

/// 轻量耗时统计，方便在日志里对比性能。
struct Stopwatch {
    private let start = DispatchTime.now()
    private let label: String

    init(_ label: String) { self.label = label }

    @discardableResult
    func stop(_ logger: Logger) -> Double {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        logger.debug("\(label, privacy: .public) 耗时 \(ms, format: .fixed(precision: 1)) ms")
        return ms
    }
}
