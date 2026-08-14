import AppKit
import SwiftUI

/// Top-level settings window (Aurora v2)：自定义侧栏（品牌头部 + 渐变选中
/// 导航）+ 分组卡片内容区。侧栏用 sidebarBackground 与内容区
/// pageBackground 拉开层次；选中导航项使用品牌渐变实底 + 白字 + 外发光，
/// 与菜单栏弹窗、剪切板、切换器的选中语言一致。
struct SettingsRootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case windowSwitcher = "窗口切换"
        case windowLayout = "窗口布局"
        case clipboard = "剪切板"
        case systemMonitor = "系统监控"
        case uninstaller = "卸载器"
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
        // 从菜单栏「系统监控」入口定位到系统监控 section。
        .onReceive(NotificationCenter.default.publisher(for: .focusSystemMonitorSection)) { _ in
            selection = .systemMonitor
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
                        .font(.system(size: DesignTokens.SettingsTypography.sidebarTitle, weight: .semibold))
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
        // 去掉顶部页面标题栏（原 toolbar 44pt 标题 + 渐变发丝线），
        // 让设置内容直接顶到顶部显示。各内容页自带 padding 与背景。
        detail
            .background(DesignTokens.Aurora.pageBackground)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .windowSwitcher:
            WindowSwitcherSettingsView()
        case .windowLayout:
            WindowLayoutSettingsView()
        case .clipboard:
            ClipboardSettingsView()
        case .systemMonitor:
            SystemMonitorSettingsView()
        case .uninstaller:
            UninstallerSettingsView()
        case .permissions:
            PermissionsSettingsView()
        case .about:
            AboutView()
        }
    }

    private func iconName(for section: Section) -> String {
        switch section {
        case .windowSwitcher: return "square.grid.2x2"
        case .windowLayout: return "rectangle.split.2x2"
        case .clipboard: return "list.clipboard"
        case .systemMonitor: return "gauge"
        case .uninstaller: return "trash"
        case .permissions: return "shield"
        case .about: return "info"
        }
    }

    /// Activates the app and brings the settings window to the front.
    private func activateAndBringToFront() {
        DispatchQueue.main.async {
            // 先激活 app，再显示窗口：确保首帧以正确外观渲染，避免
            // 偶发的「整页按钮全灰」渲染闪烁（此前先 orderFront 后 activate，
            // 首帧可能在 app 激活前完成，品牌渐变/语义色未解析）。
            NSApp.activate()
            // OverlayPanel.canBecomeMain=false、ClipboardPanel 同理、
            // MenuBarExtra 窗口也不能成为 main，因此设置窗口是唯一
            // canBecomeMain=true 的窗口，无需依赖标题字符串。
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
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
        .focusEffectDisabled()
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
