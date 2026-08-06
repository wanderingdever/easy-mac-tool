import AppKit
import CoreGraphics
import CoreText
import Foundation

// Generate a modern macOS Big Sur style app icon (1024x1024 RGBA PNG).
//
// Design (Aurora v2):
// - Soft diagonal 3-stop gradient background (soft blue → indigo → violet),
//   与 DesignTokens.Aurora.brandGradient 同源（#4C9FFF → #827FF0 → #C982F2）
// - macOS squircle (continuous-corners rounded rect, ~22.37% corner radius)
// - White bolt.fill glyph centered（与菜单栏镂空闪电、应用内品牌图标一致）。
//   Subtle drop shadow for depth.
//
// Usage: swift generate_app_icon.swift /path/to/output.png

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : {
        // 基于脚本所在目录推导默认输出路径，避免硬编码绝对路径
        // 在仓库迁移或他人构建时失效。
        let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        return scriptDir
            .appendingPathComponent("../EasyMacTool/Assets.xcassets/AppIcon.appiconset/AppIcon_1024.png")
            .standardizedFileURL.path
    }()

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("FAIL: cannot create context")
    exit(1)
}

// Flip to top-left origin so text draws upright.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// 1. Squircle background via continuous-corners rounded rect.
// macOS icon corner radius ≈ 0.2237 * edge length on a 1024 canvas ≈ 229.
let canvasRect = CGRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = 229
let bgPath = CGPath(
    roundedRect: canvasRect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)

// 2. Fill squircle with the Aurora diagonal 3-stop gradient
// (top-left soft blue → indigo → bottom-right violet).
let colorSpace = CGColorSpaceCreateDeviceRGB()
let colors = [
    CGColor(red: 0.298, green: 0.624, blue: 1.0, alpha: 1.0),   // #4C9FFF Aurora blue
    CGColor(red: 0.510, green: 0.498, blue: 0.941, alpha: 1.0), // #827FF0 Aurora indigo
    CGColor(red: 0.788, green: 0.510, blue: 0.949, alpha: 1.0), // #C982F2 Aurora violet
] as CFArray
let locations: [CGFloat] = [0.0, 0.55, 1.0]
guard let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: colors,
    locations: locations
) else {
    print("FAIL: cannot create gradient")
    exit(1)
}

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
// Draw gradient diagonally: top-left (0,0) → bottom-right (1024,1024).
// (In flipped top-left-origin space.)
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: CGFloat(size), y: CGFloat(size)),
    options: []
)

// 3. Subtle top highlight (gloss) — soft white gradient from top, ~18% opacity.
let glossColors = [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
] as CFArray
let glossLocations: [CGFloat] = [0.0, 0.55]
guard let glossGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: glossColors,
    locations: glossLocations
) else {
    print("FAIL: cannot create gloss gradient")
    exit(1)
}
ctx.drawLinearGradient(
    glossGradient,
    start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: 0, y: CGFloat(size) * 0.6),
    options: []
)
ctx.restoreGState()

// 4. Draw white bolt.fill glyph centered（Aurora v2 品牌图形）。
// 注意：SF Symbol NSImage 的 .size 不随 SymbolConfiguration 可靠缩放，
// 因此显式指定目标尺寸（高度 = 画布 58%，宽度按符号原始宽高比），
// 避免闪电被 squircle 边缘裁切。
guard let boltSymbol = NSImage(
    systemSymbolName: "bolt.fill",
    accessibilityDescription: nil
) else {
    print("FAIL: cannot load bolt.fill symbol")
    exit(1)
}
let symbolConfig = NSImage.SymbolConfiguration(
    pointSize: 256,
    weight: .bold
)
let bolt = boltSymbol.withSymbolConfiguration(symbolConfig) ?? boltSymbol
let naturalSize = bolt.size
let aspect = naturalSize.width / max(naturalSize.height, 1)

let targetH = CGFloat(size) * 0.58
let targetW = targetH * aspect

// 在临时上下文中把闪电渲染成纯白色（锁 hue：白色填充 + sourceIn 上色）。
// 2x 渲染保证边缘平滑。
guard let boltCtx = CGContext(
    data: nil,
    width: Int(targetW * 2),
    height: Int(targetH * 2),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("FAIL: cannot create bolt context")
    exit(1)
}
boltCtx.scaleBy(x: 2, y: 2)
let nsCtx = NSGraphicsContext(cgContext: boltCtx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx
bolt.draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
          from: .zero,
          operation: .sourceOver,
          fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
// sourceIn：用白色填充已绘制区域（保留 alpha 形状）。
boltCtx.setBlendMode(.sourceIn)
boltCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
boltCtx.fill(CGRect(x: 0, y: 0, width: targetW * 2, height: targetH * 2))
guard let whiteBolt = boltCtx.makeImage() else {
    print("FAIL: cannot make white bolt image")
    exit(1)
}

// 合成到主画布：居中 + 轻微下沉阴影，裁剪到 squircle 内。
ctx.saveGState()
// Drop shadow for depth（主 ctx 已是 top-left 翻转坐标，向下阴影 y 为正）。
ctx.setShadow(offset: CGSize(width: 0, height: 10),
              blur: 26,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
ctx.addPath(bgPath)
ctx.clip()
let drawW = targetW * 2
let drawH = targetH * 2
let drawRect = CGRect(x: (CGFloat(size) - drawW) / 2,
                      y: (CGFloat(size) - drawH) / 2,
                      width: drawW,
                      height: drawH)
// 主 ctx 是 top-left（y 向下）坐标，CGImage 直接 draw 会上下颠倒。
// 标准做法：把原点移到目标 rect 的上边缘后再翻转 y，图像即正向绘制。
ctx.translateBy(x: drawRect.minX, y: drawRect.minY + drawRect.height)
ctx.scaleBy(x: 1, y: -1)
ctx.draw(whiteBolt, in: CGRect(x: 0, y: 0, width: drawW, height: drawH))
ctx.restoreGState()

// 5. Export to PNG.
guard let img = ctx.makeImage() else {
    print("FAIL: cannot make image")
    exit(1)
}
let bitmapRep = NSBitmapImageRep(cgImage: img)
guard let pngData = bitmapRep.representation(
    using: .png,
    properties: [:]
) else {
    print("FAIL: cannot encode PNG")
    exit(1)
}

let outputURL = URL(fileURLWithPath: output)
let dir = outputURL.deletingLastPathComponent()
try? FileManager.default.createDirectory(
    at: dir,
    withIntermediateDirectories: true
)
do {
    try pngData.write(to: outputURL)
    print("OK: wrote \(output) (\(pngData.count) bytes)")
} catch {
    print("FAIL: write error \(error)")
    exit(1)
}
