// Grabi 应用图标：用 CoreGraphics 画，而不是修位图。
//
// 图形语言：一只被取景框框住的六叶快门。
// 外框对应「box」，中间的六段环形光圈对应「shutter」，组成 Grabi 的缩写。
// 图标完全几何化，16pt 到 1024pt 共用同一套结构，不依赖 AI 位图或外部素材。
//
//     swift tools/make-icon.swift /tmp/icon-1024.png
//
// 打包成 .icns 见 tools/make-icon.sh
import AppKit
import CoreGraphics

let side: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

guard let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                          bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func fillPath(_ path: CGPath, color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func strokePath(_ path: CGPath, color: CGColor, width: CGFloat) {
    ctx.addPath(path)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.strokePath()
}

// MARK: - 底板（标准 macOS 图标网格：内容约占 80%）

let inset: CGFloat = 96
let tile = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

let tileGradient = CGGradient(colorsSpace: colorSpace,
                              colors: [rgb(70, 88, 238), rgb(36, 52, 142),
                                       rgb(10, 14, 36)] as CFArray,
                              locations: [0, 0.54, 1])!
ctx.drawLinearGradient(tileGradient,
                       start: CGPoint(x: inset, y: side - inset),
                       end: CGPoint(x: side - inset, y: inset),
                       options: [])

// 左上柔光让深色底板有层次，不至于像一块纯色。
let glow = CGGradient(colorsSpace: colorSpace,
                      colors: [rgb(116, 220, 255, 0.36), rgb(116, 220, 255, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: side * 0.28, y: side * 0.78),
                       startRadius: 0,
                       endCenter: CGPoint(x: side * 0.28, y: side * 0.78),
                       endRadius: 500,
                       options: [])

// 右上角一抹暖色，避免整张图只剩蓝紫一个色相。
let warmGlow = CGGradient(colorsSpace: colorSpace,
                          colors: [rgb(255, 178, 82, 0.34), rgb(255, 178, 82, 0)] as CFArray,
                          locations: [0, 1])!
ctx.drawRadialGradient(warmGlow,
                       startCenter: CGPoint(x: side * 0.84, y: side * 0.82),
                       startRadius: 0,
                       endCenter: CGPoint(x: side * 0.84, y: side * 0.82),
                       endRadius: 300,
                       options: [])

// MARK: - 取景框

let frameSide: CGFloat = 560
let frameRect = CGRect(x: (side - frameSide) / 2,
                       y: (side - frameSide) / 2,
                       width: frameSide,
                       height: frameSide)
let framePath = CGPath(roundedRect: frameRect,
                       cornerWidth: 82,
                       cornerHeight: 82,
                       transform: nil)

// 先画一层深色底，白色框线在渐变上有稳定的边缘。
strokePath(framePath, color: rgb(5, 9, 24, 0.42), width: 48)
strokePath(framePath, color: rgb(255, 255, 255, 0.96), width: 30)

// MARK: - 六叶快门

let center = CGPoint(x: side / 2, y: side / 2)
let outerRadius: CGFloat = 164
let innerRadius: CGFloat = 62
let bladeGap: CGFloat = 8 * .pi / 180
let bladeSpan: CGFloat = 52 * .pi / 180
let bladeColors = [rgb(255, 255, 255, 0.98),
                   rgb(112, 229, 255, 0.98),
                   rgb(255, 255, 255, 0.98),
                   rgb(112, 229, 255, 0.98),
                   rgb(255, 255, 255, 0.98),
                   rgb(112, 229, 255, 0.98)]

for index in 0..<6 {
    let start = CGFloat(index) * .pi / 3 + bladeGap / 2
    let end = start + bladeSpan
    let blade = CGMutablePath()
    blade.addArc(center: center, radius: outerRadius,
                 startAngle: start, endAngle: end, clockwise: false)
    blade.addArc(center: center, radius: innerRadius,
                 startAngle: end, endAngle: start, clockwise: true)
    blade.closeSubpath()
    fillPath(blade, color: bladeColors[index])
}

// 内圈压暗，中心留出干净的负空间，让六叶图案在 16pt 时也不糊成一团。
let apertureHole = CGPath(ellipseIn: CGRect(x: center.x - innerRadius,
                                            y: center.y - innerRadius,
                                            width: innerRadius * 2,
                                            height: innerRadius * 2),
                          transform: nil)
fillPath(apertureHole, color: rgb(12, 18, 48, 0.94))

ctx.restoreGState()

// MARK: - 图标边缘

strokePath(tilePath, color: rgb(255, 255, 255, 0.16), width: 2)

guard let image = ctx.makeImage() else { exit(2) }
let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: output))
print("已写出 \(output)")
