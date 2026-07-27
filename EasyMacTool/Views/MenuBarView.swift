import AppKit
import SwiftUI

/// 菜单栏下拉内容：
/// - 顶部：系统信息面板（仅当 systemMonitor.enabled 时显示）
/// - 底部：设置(左) + 退出(右) 只保留图标
///
/// 监控未启用时下拉菜单只显示底部图标按钮一行，宽度 200pt。
/// 监控启用时顶部多出面板，宽度增至 280pt 容纳 3 列卡片。
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var settings: AppSettings
    @State private var hoveredButton: String?

    private var monitorEnabled: Bool { settings.systemMonitor.enabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if monitorEnabled {
                SystemMonitorPanel()
                Divider()
            }

            // 底部：设置(左) + 退出(右) 只保留图标。
            HStack {
                iconButton(icon: "gearshape", shortcut: "⌘, 设置") {
                    openWindow(id: "settings")
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        NotificationCenter.default.post(name: .openSettings, object: nil)
                    }
                }
                Spacer()
                iconButton(icon: "power", shortcut: "⌘Q 退出") {
                    NSApp.terminate(nil)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(10)
        .frame(width: monitorEnabled ? 280 : 200)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            openWindow(id: "settings")
        }
    }

    /// 圆形 hover 高亮图标按钮。仅图标，无文字，hover 时背景变 accentColor.opacity(0.15)。
    /// tooltip 用 .help() 显示快捷键提示。
    private func iconButton(icon: String, shortcut: String,
                            action: @escaping () -> Void) -> some View {
        let isHovered = hoveredButton == icon
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.accentColor.opacity(0.15) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(shortcut)
        .onHover { hovering in
            hoveredButton = hovering ? icon : nil
        }
    }
}
