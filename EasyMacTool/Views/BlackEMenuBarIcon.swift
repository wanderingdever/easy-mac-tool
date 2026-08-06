import AppKit
import SwiftUI

/// 菜单栏图标（Aurora v2）：新 Logo 剪影——圆角方块 + 闪电镂空。
/// isTemplate=true 让菜单栏自动用单色渲染（深色模式白、浅色模式黑），
/// 镂空闪电透过 alpha 通道呈现，与应用内 Aurora 品牌图标形态一致。
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

/// 用 NSImage 绘制新 Logo 剪影：实心圆角方块中镂空一道闪电。
/// 与 Aurora 品牌图标（渐变方块 + 白色 bolt）同形态，template 模式
/// 下单色呈现：方块部分取菜单栏前景色，闪电处透明。
enum BlackEIconRenderer {
    static func render() -> NSImage {
        // 画布 22pt，与系统 status item 默认高度一致。
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        // 圆角方块：18×18 居中，圆角 4.5（与品牌图标 0.25 比例一致）。
        let rectSide: CGFloat = 18
        let rect = NSRect(x: (size.width - rectSide) / 2,
                          y: (size.height - rectSide) / 2,
                          width: rectSide,
                          height: rectSide)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5).fill()

        // 闪电镂空：用 destinationOut 混合模式把 bolt.fill 从方块中擦除，
        // 形成透明闪电（template 渲染时呈现为菜单栏背景色）。
        if let bolt = NSImage(systemSymbolName: "bolt.fill",
                              accessibilityDescription: nil) {
            let boltSide: CGFloat = 10.5
            let config = NSImage.SymbolConfiguration(pointSize: boltSide, weight: .bold)
            let configured = bolt.withSymbolConfiguration(config) ?? bolt
            let boltSize = configured.size
            let boltRect = NSRect(x: (size.width - boltSize.width) / 2,
                                  y: (size.height - boltSize.height) / 2,
                                  width: boltSize.width,
                                  height: boltSize.height)
            configured.draw(in: boltRect,
                            from: .zero,
                            operation: .destinationOut,
                            fraction: 1.0)
        }

        image.unlockFocus()
        // isTemplate=true：菜单栏自动用单色渲染，深色模式白色、浅色模式黑色。
        image.isTemplate = true
        return image
    }
}
