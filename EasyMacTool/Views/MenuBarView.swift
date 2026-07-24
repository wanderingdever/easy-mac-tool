import AppKit
import SwiftUI

/// Content shown in the menu bar popover. Minimal: just settings + quit.
/// Each item has an icon on the left and shortcut hint on the right.
/// Rows highlight with accent background on hover — matching macOS native
/// menu bar popover styling.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var hoveredLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            menuButton(icon: "gearshape", label: "设置", shortcut: "⌘,") {
                openWindow(id: "settings")
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
            }

            Divider()

            menuButton(icon: "power", label: "退出", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
        .padding(8)
        .frame(width: 200)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            openWindow(id: "settings")
        }
    }

    /// A menu row with an icon on the left, label in the middle, and a
    /// monospaced shortcut hint on the right — matching macOS menu style.
    /// On hover the row fills with an accent-tinted rounded background,
    /// mirroring the system's menu item highlight.
    private func menuButton(icon: String, label: String, shortcut: String,
                            action: @escaping () -> Void) -> some View {
        let isHovered = hoveredLabel == label
        return Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                Text(label)
                    .foregroundStyle(isHovered ? Color.accentColor : .primary)
                Spacer()
                Text(shortcut)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isHovered ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.7))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.accentColor.opacity(0.2) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredLabel = hovering ? label : nil
        }
    }
}
