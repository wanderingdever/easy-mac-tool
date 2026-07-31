import AppKit
import SwiftUI

/// 菜单栏下拉内容：设置 + 退出两项，图标+文字+快捷键展示。
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var hoveredItem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuItem(icon: "gearshape",
                     title: "设置…",
                     shortcut: "⌘,",
                     action: openSettings)
            Divider().padding(.horizontal, 8).padding(.vertical, 4)
            menuItem(icon: "power",
                     title: "退出",
                     shortcut: "⌘Q",
                     action: { NSApp.terminate(nil) })
        }
        .padding(6)
        .frame(width: 240)
    }

    /// 菜单项：图标 + 标题 + 右侧快捷键。hover 时背景变 accentColor.opacity(0.15)。
    private func menuItem(icon: String,
                          title: String,
                          shortcut: String,
                          action: @escaping () -> Void) -> some View {
        let isHovered = hoveredItem == icon
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer()
                Text(shortcut)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.accentColor.opacity(0.15) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredItem = hovering ? icon : nil
        }
    }

    /// 直接调用 openWindow 打开设置窗口，不再发送 .openSettings 通知——
    /// 通知会被 BlackEMenuBarIcon 接收再次调 openWindow，形成递归。
    private func openSettings() {
        openWindow(id: "settings")
        DispatchQueue.main.async {
            NSApp.activate()
        }
    }
}
