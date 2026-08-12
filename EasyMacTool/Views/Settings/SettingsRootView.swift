import AppKit
import SwiftUI

/// Top-level settings window (Aurora v2)：自定义侧栏（品牌头部 + 渐变选中
/// 导航）+ 分组卡片内容区。侧栏用 sidebarBackground 与内容区
/// pageBackground 拉开层次；选中导航项使用品牌渐变实底 + 白字 + 外发光，
/// 与菜单栏弹窗、剪切板、切换器的选中语言一致。
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
            // 渐变发丝分隔线替代生硬 Divider。
            Rectangle()
                .fill(DesignTokens.Aurora.cardBorder)
                .frame(width: 1)
            detailPanel
        }
        .background(DesignTokens.Aurora.pageBackground)
        .frame(minWidth: 760, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            activateAndBringToFront()
        }
        // 权限缺失时跳转到「权限设置」section，让用户立即看到各项权限状态。
        .onReceive(NotificationCenter.default.publisher(for: .focusPermissionSection)) { _ in
            selection = .permissions
        }
    }

    // MARK: - 	

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 品牌头部：渐变实底图标 + 名称。
            // 红绿灯按钮在窗口左上角（约占 top 0~28pt），用 top padding
            // 纵向避让；横向与下方导航项左对齐（导航列表 .horizontal 10 +
            // 项内 leading 10 ≈ 图标起始 x=20，此处 leading 12 使 chip 与
            // 导航图标视觉对齐），消除之前的横向错位。
            HStack(spacing: 9) {
                AuroraIconChip(systemName: "bolt.fill", size: 28, solid: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("EasyMacTool")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 14)
		
            VStack(spacing: 3) {
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

            // 侧栏底部提示（弱化）。
            Text("让 Mac 更轻松")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(width: DesignTokens.Settings.sidebarWidth)
        .background(DesignTokens.Aurora.sidebarBackground)
    }

    // MARK: - Detail

    private var detailPanel: some View {
        VStack(spacing: 0) {
            // Detail toolbar：44pt 高，17pt semibold 页面标题 + 底部渐变发丝线。
            HStack(spacing: 8) {
                Text(selection.rawValue)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 48)
            .overlay(alignment: .bottom) {
                DesignTokens.Aurora.brandHorizontal
                    .opacity(0.25)
                    .frame(height: 1)
                    .mask(
                        LinearGradient(colors: [.black, .black, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                    )
            }

            // Content area — each page manages its own padding/scroll.
            detail
        }
        .background(DesignTokens.Aurora.pageBackground)
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

/// 侧栏导航项（Aurora v2）：图标 + 标题。
/// 选中 = 品牌渐变实底 + 白字 + 品牌色外发光；hover（未选中）= 极淡填充。
/// 选中/悬停切换使用统一 Aurora 过渡动画。
private struct SidebarNavItem: View {
    let section: SettingsRootView.Section
    let isSelected: Bool
    let iconName: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: DesignTokens.Settings.navItemGap) {
                Image(systemName: iconName)
                    .font(.system(size: DesignTokens.Settings.navItemIconSize, weight: .medium))
                    .frame(width: DesignTokens.Settings.navItemIconSize,
                           height: DesignTokens.Settings.navItemIconSize)
                Text(section.rawValue)
                    .font(.system(size: DesignTokens.SettingsTypography.navItem,
                                  weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.vertical, DesignTokens.Settings.navItemVPadding)
            .padding(.horizontal, DesignTokens.Settings.navItemHPadding)
            .frame(minHeight: DesignTokens.Settings.navItemHeight)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Settings.navItemRadius + 2, style: .continuous)
                    .fill(backgroundFill)
            )
            .shadow(color: isSelected ? DesignTokens.Aurora.brandGlow : .clear,
                    radius: 6, y: 2)
            .contentShape(Rectangle())
            .animation(DesignTokens.Aurora.standard, value: isSelected)
            .animation(DesignTokens.Aurora.standard, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var backgroundFill: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(DesignTokens.Aurora.brandGradient)
        } else if isHovered {
            return AnyShapeStyle(Color.primary.opacity(0.06))
        } else {
            return AnyShapeStyle(.clear)
        }
    }
}
