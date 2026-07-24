import AppKit
import CoreGraphics
import CoreText
import Foundation

// Generate a modern macOS Big Sur style app icon (1024x1024 RGBA PNG).
//
// Design:
// - Vibrant diagonal gradient background (system blue → system purple)
// - macOS squircle (continuous-corners rounded rect, ~22.37% corner radius)
// - Bold white "E" glyph (SF Pro Rounded Bold), centered — matches the
//   menu bar E icon style. Subtle drop shadow for depth.
//
// Usage: swift generate_app_icon.swift /path/to/output.png

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/Users/matt/Documents/programs/EasyMacTool/EasyMacTool/Assets.xcassets/AppIcon.appiconset/AppIcon_1024.png"

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

// 2. Fill squircle with a diagonal gradient (top-left blue → bottom-right purple).
let colorSpace = CGColorSpaceCreateDeviceRGB()
let colors = [
    CGColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1.0),    // #0A84FF system blue
    CGColor(red: 0.346, green: 0.337, blue: 0.839, alpha: 1.0),  // #5856D6 system indigo/purple
] as CFArray
let locations: [CGFloat] = [0.0, 1.0]
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

// 4. Draw bold white "E" centered, using SF Pro Rounded Bold to match the
// menu bar E icon style.
let font = NSFont(
    name: "SFProRounded-Bold",
    size: CGFloat(size) * 0.62
) ?? NSFont.systemFont(ofSize: CGFloat(size) * 0.62, weight: .bold)

let eString = NSAttributedString(
    string: "E",
    attributes: [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
)
let line = CTLineCreateWithAttributedString(eString)
let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

// Center the glyph in the canvas.
ctx.saveGState()
let glyphX = (CGFloat(size) - bounds.width) / 2 - bounds.minX
let glyphY = (CGFloat(size) - bounds.height) / 2 - bounds.minY
ctx.textPosition = CGPoint(x: glyphX, y: glyphY)

// Drop shadow for depth (subtle dark glow behind glyph).
ctx.setShadow(offset: CGSize(width: 0, height: -6),
              blur: 18,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))

// Clip glyph drawing to the squircle so nothing leaks past corners.
ctx.addPath(bgPath)
ctx.clip()

CTLineDraw(line, ctx)
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
