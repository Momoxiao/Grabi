// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Grabi",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Grabi",
            path: "Sources/Grabi",
            swiftSettings: [
                // 使用 Swift 5 语言模式：AppKit / ScreenCaptureKit 的跨线程调用更宽松，
                // 我们自己在流水线里显式回到主线程。
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
