// Grabi DMG 安装窗口的背景图。
//
// 画的是 Finder 图标视图后面那张底图：顶部一句标题，中间一支指向右的箭头，
// 把「左边是应用、右边是 Applications」这件事在视觉上说清楚。
// 图标本身由 Finder 摆放（见 package.sh 里的 AppleScript），这里只画背景，
// 所以下面这些坐标必须和 package.sh 里的 position 对齐：
//
//   Grabi.app        (168, 176)
//   Applications     (492, 176)
//   使用说明.txt      (330, 352)
//
// ⚠️ Finder 把背景图按**像素**画在图标视图里，并且贴着图标视图的**下边缘**。
// 图标视图比窗口矮（顶上让给标题栏、底下还有一条空白），所以这张图实际只有
// 下半部分看得到，顶端会被切掉。实机量出来的映射是
//
//     窗口内坐标 = 图片坐标 - 25pt
//
// 因此：顶部 25pt 留白不要放东西，标题文字从 76pt 开始；Finder 的 position
// 指的是「图标 + 名字」整块的中心，图标本身比它高约 9pt，所以箭头画在 192pt
// 才和两个图标真正对齐。底部收到纯白，和图标视图下面那条空白接得上。
//
//     swift tools/make-dmg-background.swift out.png [width] [height] [scale]
//
// scale=2 时像素翻倍、逻辑尺寸不变，PNG 会带 144dpi，供 Retina 屏幕使用。
import AppKit

let argv = CommandLine.arguments
let outputPath = argv.count > 1 ? argv[1] : "dmg-background.png"
let pointWidth = argv.count > 2 ? (Double(argv[2]) ?? 660) : 660
let pointHeight = argv.count > 3 ? (Double(argv[3]) ?? 520) : 520
let renderScale = argv.count > 4 ? (Double(argv[4]) ?? 1) : 1

let W = CGFloat(pointWidth)
let H = CGFloat(pointHeight)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let pxW = Int((W * CGFloat(renderScale)).rounded())
let pxH = Int((H * CGFloat(renderScale)).rounded())
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: pxW, pixelsHigh: pxH,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("无法创建位图上下文\n".utf8))
    exit(1)
}

// 逻辑尺寸决定 PNG 的 DPI：1320×940 的图声明为 660×470，就是 144dpi。
rep.size = NSSize(width: W, height: H)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext
ctx.scaleBy(x: CGFloat(renderScale), y: CGFloat(renderScale))
// 从这里开始都按「点」作图，坐标系原点在左下角。

/// 把「从顶部量」的 y 换算成 AppKit 的左下角原点坐标。
func top(_ y: CGFloat) -> CGFloat { H - y }

// MARK: - 底板

let backdrop = NSGradient(colors: [rgb(0xF7F7FA), rgb(0xFDFDFE), rgb(0xFFFFFF)],
                          atLocations: [0, 0.55, 1],
                          colorSpace: .sRGB)!
backdrop.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

/// 居中一行文字，`centerY` 是这一行在背景里从顶部算的中心位置。
func drawCentered(_ text: String, font: NSFont, color: NSColor,
                  centerY: CGFloat, kerning: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: kerning,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    string.draw(at: NSPoint(x: ((W - size.width) / 2).rounded(),
                            y: (top(centerY) - size.height / 2).rounded()))
}

// MARK: - 文案

drawCentered("把 Grabi 拖进 Applications", font: .systemFont(ofSize: 16, weight: .semibold),
             color: rgb(0x1D1D1F), centerY: 76)
drawCentered("拖进「应用程序」文件夹，即可完成安装",
             font: .systemFont(ofSize: 12, weight: .regular),
             color: rgb(0x6E6E73), centerY: 101)

// MARK: - 箭头

let arrowY = top(192)
let arrowColor = rgb(0xB5B5BE)

let shaft = NSBezierPath()
shaft.lineWidth = 5
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: 250, y: arrowY))
shaft.line(to: NSPoint(x: 398, y: arrowY))
arrowColor.setStroke()
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 418, y: arrowY))
head.line(to: NSPoint(x: 397, y: arrowY + 12))
head.line(to: NSPoint(x: 397, y: arrowY - 12))
head.close()
arrowColor.setFill()
head.fill()

// MARK: - 输出

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: outputPath))
} catch {
    FileHandle.standardError.write(Data("写入 \(outputPath) 失败：\(error)\n".utf8))
    exit(1)
}
print(outputPath)
