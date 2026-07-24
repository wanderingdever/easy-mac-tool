import AppKit
import SwiftUI

/// 菜单栏图标：纯净的圆润大写"E"字母，无背景。符合 macOS 设计语言
/// （SF Pro Rounded + template 单色适配明暗模式）。
struct BlackEMenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow
    private static let iconImage: NSImage = BlackEIconRenderer.render()

    var body: some View {
        Image(nsImage: Self.iconImage)
            // label 始终挂载——监听 .openSettings 通知，即使菜单 popover
            // 未打开也能响应（AccessibilityChecker 在启动后 0.5s 发通知）。
            .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                openWindow(id: "settings")
            }
    }
}

/// 用 NSImage 绘制"E"字母：SF Pro Rounded 字体（系统圆体），饱满居中，
/// isTemplate=true 让菜单栏自动用单色渲染（深色模式白、浅色模式黑）。
enum BlackEIconRenderer {
    static func render() -> NSImage {
        // 画布 18pt：菜单栏 status item 标准尺寸。
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        // 圆体设计字体（SF Pro Rounded），契合 macOS 视觉语言。
        // weight=.heavy 保证 E 在 18pt 下视觉饱满少留白；size=15 让字形几乎
        // 填满画布高度（实际字形高度约 11pt，留上下边距以视觉居中）。
        let baseFont = NSFont.systemFont(ofSize: 15, weight: .heavy)
        let descriptor = baseFont.fontDescriptor.withDesign(.rounded) ?? baseFont.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: 15) ?? baseFont

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            // template 模式下颜色被忽略，由菜单栏决定单色。
            .foregroundColor: NSColor.black
        ]
        let str = NSAttributedString(string: "E", attributes: attrs)
        let textSize = str.size()
        // 水平居中；垂直微调 -0.5pt 校正基线，让 E 视觉居中。
        let textOrigin = NSPoint(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2 - 0.5
        )
        str.draw(at: textOrigin)

        image.unlockFocus()
        // isTemplate=true：菜单栏自动用单色渲染，深色模式白色、浅色模式黑色。
        image.isTemplate = true
        return image
    }
}
