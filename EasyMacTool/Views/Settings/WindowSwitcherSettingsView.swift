import AppKit
import Combine
import SwiftUI

/// Window-switcher settings (Aurora v2)：分组卡片布局。
/// 顶部「多屏幕」全局卡片 + 下方「快捷键」master-detail 卡片。
/// 每个 section = 渐变图标 chip 标题 + 浮起卡片（cardSurface / 发丝描边 /
/// 柔和阴影），与剪切板、权限页保持一致的视觉语言。
struct WindowSwitcherSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedShortcutID: ShortcutConfig.ID?
    /// 多屏幕分段的本地状态：避免直接在视图更新阶段写回 @Published 触发
    /// "Publishing changes from within view updates" 警告，改由 onChange 写回。
    @State private var displayTarget: AppSettings.DisplayTarget = .active
    @State private var globalRecording = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Settings.contentSpacing) {
                globalToggleSection
                displayTargetSection
                shortcutSection
            }
            .padding(DesignTokens.Settings.contentPadding)
            .frame(maxWidth: .infinity, alignment: .top)
            .onAppear {
                displayTarget = settings.displayTarget
                selectFirstShortcutIfNeeded()
            }
            .onChange(of: displayTarget) { _, newValue in
                settings.displayTarget = newValue
            }
            .onChange(of: selectedShortcutID) { _, newValue in
                if newValue == nil {
                    selectedShortcutID = settings.shortcuts.first?.id
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Aurora.pageBackground)
    }

    // MARK: - Global toggle

    /// 窗口切换功能全局开关：关闭后所有窗口切换快捷键恢复系统原生行为。
    private var globalToggleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "通用", systemImage: "gear")
            SettingsCard(spacing: 10) {
                SettingsToggleRow(
                    title: "启用窗口切换",
                    description: "关闭后所有窗口切换快捷键将恢复系统默认行为（原生 Cmd+Tab）。",
                    isOn: $settings.windowSwitcherEnabled
                )
                SettingsToggleRow(
                    title: "悬停自动选中",
                    description: "鼠标悬停到缩略图上时直接移动键盘选中项，点击仍然立即激活。",
                    isOn: $settings.mouseHoverSelects
                )
                SettingsToggleRow(
                    title: "触控板滑动切换",
                    description: "三指左右滑动呼出切换器；已打开时继续滑动切换选中项。",
                    isOn: $settings.trackpadSwipeEnabled
                )
                Picker("展示模式", selection: $settings.switcherStyle) {
                    ForEach(AppSettings.SwitcherStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
            }
        }
    }

    // MARK: - Multi-screen target (global)

    private var displayTargetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "多屏幕", systemImage: "display")
            SettingsCard(spacing: 10) {
                // 与「预览图大小」的 segmented Picker 一致：非空 label + .labelsHidden()，
                // 不包 HStack，直接放在 VStack(.leading) 里顶格，避免前导空格。
                Picker("显示于", selection: $displayTarget) {
                    ForEach(AppSettings.DisplayTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480, alignment: .leading)
                Text("切换窗口面板在哪个屏幕弹出。当前：\(settings.displayTarget.displayName)")
                    .scaledSystemFont(DesignTokens.SettingsTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "快捷键", systemImage: "keyboard")

            // 快捷键详情直接展开：右侧不再内嵌滚动视图，整页由外层
            // ScrollView 承接，避免卡片高度被压死并出现内部滚动条。
            HStack(spacing: 0) {
                shortcutListColumn
                    .frame(width: 220)
                Rectangle()
                    .fill(DesignTokens.Aurora.insetSeparator)
                    .frame(width: 1)
                shortcutDetail
                    .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .auroraSettingsCard()
        }
    }

    /// Left column: the shortcut list on top, add/delete buttons at the bottom
    /// (matching macOS System Settings layout). Aurora v2：列表区用比卡片
    /// 略深的表面，与右侧详情形成层次。
    private var shortcutListColumn: some View {
        VStack(spacing: 0) {
            shortcutList
            Spacer(minLength: 0)
            SettingsRowDivider()
            // Toolbar with + / − buttons at the bottom, like macOS settings.
            HStack(spacing: 4) {
                ShortcutToolbarButton(icon: "plus", accessibilityLabel: "添加快捷键") {
                    let new = ShortcutConfig(name: nextShortcutName(),
                                             keyCode: 0x30,
                                             modifiers: [.maskCommand, .maskAlternate])
                    settings.shortcuts.append(new)
                    selectedShortcutID = new.id
                }
                ShortcutToolbarButton(icon: "minus",
                                      accessibilityLabel: "删除快捷键",
                                      disabled: !canDeleteSelected) {
                    deleteSelectedShortcut()
                }
                Spacer()
            }
            .padding(6)
        }
        .background(Color.primary.opacity(0.025))
    }

    private var shortcutList: some View {
        VStack(spacing: 4) {
            ForEach(settings.shortcuts) { shortcut in
                ShortcutItemView(
                    shortcut: shortcut,
                    isSelected: selectedShortcutID == shortcut.id
                ) {
                    selectedShortcutID = shortcut.id
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canDeleteSelected: Bool {
        guard let id = selectedShortcutID,
              let shortcut = settings.shortcuts.first(where: { $0.id == id }) else { return false }
        return !shortcut.isDefault
    }

    private func deleteSelectedShortcut() {
        guard let id = selectedShortcutID,
              let index = settings.shortcuts.firstIndex(where: { $0.id == id }),
              !settings.shortcuts[index].isDefault else { return }
        settings.shortcuts.remove(at: index)
        let newIndex = min(index, settings.shortcuts.count - 1)
        selectedShortcutID = settings.shortcuts.indices.contains(newIndex)
            ? settings.shortcuts[newIndex].id
            : settings.shortcuts.first?.id
    }

    private func nextShortcutName() -> String {
        let existing = Set(settings.shortcuts.map(\.name))
        var suffix = 2
        while existing.contains("快捷键 \(suffix)") { suffix += 1 }
        return "快捷键 \(suffix)"
    }

    @ViewBuilder
    private var shortcutDetail: some View {
        if let index = settings.shortcuts.firstIndex(where: { $0.id == selectedShortcutID }) {
            ShortcutDetailView(shortcut: Binding(
                get: { settings.shortcuts[index] },
                set: { newValue in
                    if settings.shortcuts[index] != newValue {
                        settings.shortcuts[index] = newValue
                    }
                }
            ), isGlobalRecording: $globalRecording)
        } else {
            ContentUnavailableView("未选择快捷键",
                                   systemImage: "keyboard",
                                   description: Text("从左侧选择一个快捷键进行编辑"))
        }
    }

    private func selectFirstShortcutIfNeeded() {
        if selectedShortcutID == nil, let first = settings.shortcuts.first {
            selectedShortcutID = first.id
        }
    }
}

/// A single shortcut item in the left-column list (Aurora v2)。
/// 两行布局：名称 + 徽标在上，按键组合在下。
/// 选中 = 品牌渐变实底 + 白字 + 外发光；hover = 极淡填充。
private struct ShortcutItemView: View {
    let shortcut: ShortcutConfig
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(shortcut.name)
                        .scaledSystemFont(13, weight: .medium)
                        .lineLimit(1)
                    if shortcut.isDefault {
                        Text("默认")
                            .scaledSystemFont(10, weight: .medium, relativeTo: .caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(badgeBg))
                            .foregroundStyle(badgeFg)
                    }
                }
                Text(shortcut.displayString)
                    .scaledSystemFont(12, design: .monospaced, relativeTo: .caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundFill)
            )
            .shadow(color: isSelected ? DesignTokens.Aurora.brandGlow : .clear,
                    radius: 5, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .animation(DesignTokens.Aurora.standard, value: isSelected)
        .animation(DesignTokens.Aurora.standard, value: isHovered)
        .auroraHover($isHovered, animated: false)
    }

    private var backgroundFill: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(DesignTokens.Aurora.brandGradient)
        } else if isHovered {
            return AnyShapeStyle(Color.primary.opacity(0.05))
        } else {
            return AnyShapeStyle(.clear)
        }
    }

    private var badgeBg: Color {
        isSelected ? Color.white.opacity(0.22) : DesignTokens.Aurora.tint.opacity(0.14)
    }

    private var badgeFg: Color {
        isSelected ? Color.white.opacity(0.95) : DesignTokens.Aurora.tint
    }
}

/// A + / − toolbar button with hover highlight.
private struct ShortcutToolbarButton: View {
    let icon: String
    let accessibilityLabel: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hoverBackground)
                )
                .foregroundStyle(disabled ? Color.secondary : Color.primary)
                .opacity(disabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .focusEffectDisabled()
        .disabled(disabled)
        .onHover { hovering in
            guard !disabled else { return }
            isHovered = hovering
        }
    }

    private var hoverBackground: Color {
        (!disabled && isHovered) ? Color.primary.opacity(0.07) : Color.clear
    }
}

/// The right-hand detail editor for a single shortcut (Aurora v2)。
/// 分组卡片：cardSurface 浮起卡 + 渐变 chip 组标题，
/// Toggle 统一品牌 tint，与全设置页一致。
struct ShortcutDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    @Binding var shortcut: ShortcutConfig
    @Binding var isGlobalRecording: Bool
    // 辅助功能权限状态：2s 定时刷新。显示最小化/隐藏窗口依赖 AX 枚举，
    // 未授权时两个开关无效却无任何反馈，需显式提示用户。
    @State private var axGranted = AccessibilityChecker.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
                groupCard("基本信息", systemImage: "info.circle") {
                    row("名称") {
                        if shortcut.isDefault {
                            Text(shortcut.name)
                                .foregroundStyle(.secondary)
                        } else {
                            TextField("名称", text: $shortcut.name)
                                .textFieldStyle(.plain)
                        }
                    }
                    SettingsRowDivider()
                    row("快捷键") {
                        KeyRecorderView(keyCode: $shortcut.keyCode,
                                        modifiers: Binding(
                                            get: { shortcut.modifiers },
                                            set: { shortcut.modifiersRaw = $0.rawValue }
                                        ),
                                        validationMessage: { keyCode, modifiers in
                                            settings.shortcutConflictMessage(
                                                keyCode: keyCode,
                                                modifiers: modifiers,
                                                excludingWindowShortcutID: shortcut.id
                                            )
                                        },
                                        isGlobalRecording: $isGlobalRecording)
                    }
                }
                groupCard("预览图大小", systemImage: "photo") {
                    Picker("大小", selection: $shortcut.previewSize) {
                        ForEach(AppSettings.PreviewSize.allCases) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("此快捷键切换窗口时的缩略图大小。当前：\(shortcut.previewSize.displayName)")
                        .scaledSystemFont(DesignTokens.SettingsTypography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                groupCard("显示窗口", systemImage: "macwindow") {
                    Toggle("仅当前桌面窗口", isOn: $shortcut.currentSpaceOnly)
                        .toggleStyle(.switch)
                        .tint(DesignTokens.Aurora.controlOn)
                        .controlSize(.small)
                        .help("仅显示当前桌面上的窗口")
                    Text("关闭后切换器会显示其他桌面上的窗口（跨桌面切换）。默认开启，仅显示当前桌面可见窗口。")
                        .scaledSystemFont(DesignTokens.SettingsTypography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    SettingsRowDivider()
                    Toggle("每个应用仅显示主窗口", isOn: $shortcut.showMainWindowOnly)
                        .toggleStyle(.switch)
                        .tint(DesignTokens.Aurora.controlOn)
                        .controlSize(.small)
                    SettingsRowDivider()
                    Picker("屏幕范围", selection: $shortcut.screensToShow) {
                        ForEach(SwitcherScreensToShow.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                    SettingsRowDivider()
                    Picker("标签页", selection: $shortcut.tabGrouping) {
                        ForEach(SwitcherTabGrouping.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                    SettingsRowDivider()
                    Picker("应用范围", selection: $shortcut.appsToShow) {
                        ForEach(SwitcherAppsToShow.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                    SettingsRowDivider()
                    Picker("排序方式", selection: $shortcut.windowOrder) {
                        ForEach(SwitcherWindowOrder.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                    SettingsRowDivider()
                    Toggle("显示最小化窗口", isOn: $shortcut.showMinimized)
                        .toggleStyle(.switch)
                        .tint(DesignTokens.Aurora.controlOn)
                        .controlSize(.small)
                        .help("在切换器中显示最小化到 Dock 的窗口（显示最后已知预览或应用图标）")
                    SettingsRowDivider()
                    Toggle("显示隐藏窗口", isOn: $shortcut.showHidden)
                        .toggleStyle(.switch)
                        .tint(DesignTokens.Aurora.controlOn)
                        .controlSize(.small)
                        .help("在切换器中显示被 Cmd+H 隐藏的应用的窗口（显示最后已知预览或应用图标）")
                    SettingsRowDivider()
                    Toggle("显示全屏窗口", isOn: $shortcut.showFullscreen)
                        .toggleStyle(.switch)
                        .tint(DesignTokens.Aurora.controlOn)
                        .controlSize(.small)
                    SettingsRowDivider()
                    Toggle("显示无窗口应用", isOn: $shortcut.showWindowless)
                        .toggleStyle(.switch)
                        .tint(DesignTokens.Aurora.controlOn)
                        .controlSize(.small)
                    if !axGranted {
                        Label("显示最小化/隐藏窗口需要『辅助功能』权限，当前未授予，开关暂不生效。",
                              systemImage: "exclamationmark.triangle.fill")
                            .scaledSystemFont(11, relativeTo: .caption)
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                    }
                    Text("最小化和隐藏的窗口无法实时捕获，将显示最后已知预览或应用图标和窗口标题")
                        .scaledSystemFont(DesignTokens.SettingsTypography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                groupCard("释放行为", systemImage: "hand.raised") {
                    Picker("快捷键释放后", selection: $shortcut.releaseBehavior) {
                        ForEach(ShortcutConfig.ReleaseBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .tint(DesignTokens.Aurora.controlOn)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { refreshAccessibilityStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshAccessibilityStatus()
            }
    }

    /// Group card（Aurora v2）：渐变 chip 标题 + 浮起卡片。
    private func groupCard(_ title: String, systemImage: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AuroraIconChip(systemName: systemImage, size: 20)
                Text(title)
                    .scaledSystemFont(DesignTokens.SettingsTypography.groupHeader, weight: .semibold)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.vertical, DesignTokens.Settings.groupRowVPadding)
            .padding(.horizontal, DesignTokens.Settings.groupRowHPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .auroraSettingsCard()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Settings.formRowGap) {
            Text(label)
                .scaledSystemFont(DesignTokens.SettingsTypography.rowLabel)
                .foregroundStyle(.primary)
                .frame(width: DesignTokens.Settings.formLabelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func refreshAccessibilityStatus() {
        axGranted = AccessibilityChecker.isTrusted
    }
}
