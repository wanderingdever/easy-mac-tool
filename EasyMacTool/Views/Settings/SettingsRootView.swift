import AppKit
import SwiftUI

/// Top-level settings window: a custom sidebar (180pt, secondary surface)
/// paired with a detail panel. Replaces `NavigationSplitView` so the sidebar
/// can match the design spec exactly — solid brand-blue selected nav item,
/// inline `EasyMacTool` title, version footer — instead of the native
/// sidebar chrome which uses a muted highlight.
struct SettingsRootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case windowSwitcher = "窗口切换"
        case clipboard = "剪切板"
        case permissions = "权限"
        case about = "关于"
        var id: String { rawValue }
    }

    @State private var selection: Section = .windowSwitcher

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailPanel
        }
        .background(DesignTokens.Colors.background)
        .frame(minWidth: 760, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            activateAndBringToFront()
        }
        // 权限缺失时跳转到「权限设置」section，让用户立即看到各项权限状态。
        .onReceive(NotificationCenter.default.publisher(for: .focusPermissionSection)) { _ in
            selection = .permissions
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            // Title row. Real traffic lights overlay the window's top-left
            // corner; the leading padding clears them (~70pt) so "EasyMacTool"
            // sits to their right, matching the design's sidebar-top layout.

            VStack(spacing: 2) {
                ForEach(Section.allCases) { section in
                    SidebarNavItem(
                        section: section,
                        isSelected: selection == section,
                        iconName: iconName(for: section)
                    ) {
                        selection = section
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)

            // 侧栏底部版本号（设计稿：11pt, muted-foreground）
            Text("v\(appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(width: DesignTokens.Settings.sidebarWidth)
        .background(DesignTokens.Colors.sidebar)
    }

    // MARK: - Detail

    private var detailPanel: some View {
        VStack(spacing: 0) {
            // Detail toolbar: 40pt high, border-bottom, section title.
            HStack {
                Text(selection.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: DesignTokens.Settings.toolbarHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DesignTokens.Colors.border)
                    .frame(height: 1)
            }

            // Content area — each page manages its own padding/scroll.
            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .windowSwitcher:
            WindowSwitcherSettingsView()
        case .clipboard:
            ClipboardSettingsView()
        case .permissions:
            PermissionsSettingsView()
        case .about:
            AboutView()
        }
    }

    private func iconName(for section: Section) -> String {
        switch section {
        case .windowSwitcher: return "square.grid.2x2"
        case .clipboard: return "list.clipboard"
        case .permissions: return "shield"
        case .about: return "info"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version).\(build)"
    }

    /// Activates the app and brings the settings window to the front.
    private func activateAndBringToFront() {
        DispatchQueue.main.async {
            // OverlayPanel.canBecomeMain=false、ClipboardPanel 同理、
            // MenuBarExtra 窗口也不能成为 main，因此设置窗口是唯一
            // canBecomeMain=true 的窗口，无需依赖标题字符串。
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
        }
    }
}

/// A single sidebar navigation item with hover background and selection state.
/// Selected = primary fill + white text; hovered (not selected) = light bg.
private struct SidebarNavItem: View {
    let section: SettingsRootView.Section
    let isSelected: Bool
    let iconName: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DesignTokens.Settings.navItemGap) {
            Image(systemName: iconName)
                .font(.system(size: DesignTokens.Settings.navItemIconSize, weight: .regular))
                .frame(width: DesignTokens.Settings.navItemIconSize,
                       height: DesignTokens.Settings.navItemIconSize)
            Text(section.rawValue)
                .font(.system(size: DesignTokens.SettingsTypography.navItem))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? DesignTokens.Colors.primaryForeground : DesignTokens.Colors.foreground)
        .padding(.vertical, DesignTokens.Settings.navItemVPadding)
        .padding(.horizontal, DesignTokens.Settings.navItemHPadding)
        .frame(minHeight: DesignTokens.Settings.navItemHeight)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Settings.navItemRadius, style: .continuous)
                .fill(backgroundColor)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            action()
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return DesignTokens.Colors.primary
        } else if isHovered {
            return DesignTokens.Colors.border.opacity(0.5)
        } else {
            return Color.clear
        }
    }
}
