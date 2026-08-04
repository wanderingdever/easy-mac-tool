import Combine
import SwiftUI

/// Window-switcher settings: a global multi-screen target picker at the top,
/// and below it a master-detail list of configurable shortcuts. Layout
/// follows the same design language as the clipboard/permissions pages:
/// 17pt semibold section headers with muted-foreground icons, card background,
/// and group-cards (secondary surface / 8pt radius / 1px border) for the
/// shortcut detail sections.
struct WindowSwitcherSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedShortcutID: ShortcutConfig.ID?
    /// Tracks the proportional width of the left column. Default 0.2 (20%),
    /// so the shortcut list is narrow and the detail editor is wide (80%).
    @State private var splitFraction: CGFloat = 0.2

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Settings.contentSpacing) {
            displayTargetSection
            Divider()
            shortcutSection
        }
        .padding(DesignTokens.Settings.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Colors.card)
        .onAppear { selectFirstShortcutIfNeeded() }
        .onChange(of: selectedShortcutID) { _, newValue in
            if newValue == nil {
                selectedShortcutID = settings.shortcuts.first?.id
            }
        }
    }

    // MARK: - Section header

    /// Section header: 17pt semibold title + 18pt muted-foreground icon, gap 8.
    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.mutedForeground)
            Text(title)
                .font(.system(size: DesignTokens.SettingsTypography.sectionHeader, weight: .semibold))
                .tracking(-0.01)
                .foregroundStyle(DesignTokens.Colors.foreground)
        }
    }

    // MARK: - Multi-screen target (global)

    private var displayTargetSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("多屏幕", systemImage: "display")
            VStack(alignment: .leading, spacing: DesignTokens.Settings.sectionBodyGap) {
                Picker("显示于", selection: $settings.displayTarget) {
                    ForEach(AppSettings.DisplayTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)
                Text("切换窗口面板在哪个屏幕弹出。当前：\(settings.displayTarget.displayName)")
                    .font(.system(size: DesignTokens.SettingsTypography.caption))
                    .foregroundStyle(DesignTokens.Colors.mutedForeground)
            }
            .padding(.top, DesignTokens.Settings.sectionBodyTop)
        }
    }

    // MARK: - Shortcuts

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("快捷键", systemImage: "keyboard")

            // Custom split: left column at `splitFraction` of width, draggable
            // divider in the middle, right column fills the rest. Default 20/80.
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let dividerWidth: CGFloat = 8
                let leftWidth = max(180, min(totalWidth - 380 - dividerWidth,
                                             totalWidth * splitFraction - dividerWidth / 2))
                HStack(spacing: 0) {
                    shortcutListColumn
                        .frame(width: leftWidth)
                    // Draggable divider
                    Rectangle()
                        .fill(DesignTokens.Colors.border)
                        .frame(width: 1)
                        .overlay(
                            Rectangle()
                                .fill(.clear)
                                .frame(width: dividerWidth)
                                .contentShape(Rectangle())
                                .cursor(NSCursor.resizeLeftRight)
                                .gesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            let proposed = leftWidth + value.translation.width
                                            let newFraction = proposed / totalWidth
                                            splitFraction = max(0.15, min(0.6, newFraction))
                                        }
                                )
                        )
                    shortcutDetail
                        .frame(maxWidth: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Settings.splitRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Settings.splitRadius, style: .continuous)
                        .strokeBorder(DesignTokens.Colors.border, lineWidth: 1)
                )
            }
            .frame(minHeight: 280)
            .padding(.top, DesignTokens.Settings.sectionBodyTop)
        }
    }

    /// Left column: the shortcut list on top, add/delete buttons at the bottom
    /// (matching macOS System Settings layout). Background is secondarySurface;
    /// the outer split container provides the border + radius.
    private var shortcutListColumn: some View {
        VStack(spacing: 0) {
            shortcutList
            Divider()
            // Toolbar with + / − buttons at the bottom, like macOS settings.
            HStack(spacing: 4) {
                ShortcutToolbarButton(icon: "plus") {
                    let new = ShortcutConfig(name: "快捷键 \(settings.shortcuts.count + 1)",
                                             keyCode: 0x30,
                                             modifiers: [.maskCommand, .maskAlternate])
                    settings.shortcuts.append(new)
                    selectedShortcutID = new.id
                }
                ShortcutToolbarButton(icon: "minus", disabled: !canDeleteSelected) {
                    deleteSelectedShortcut()
                }
                Spacer()
            }
            .padding(6)
        }
        .background(DesignTokens.Colors.secondarySurface)
    }

    private var shortcutList: some View {
        ScrollView {
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
        }
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
            ))
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

/// A single shortcut item in the left-column list. Two-line layout:
/// name + badge on top, key combo below. Selected = primary-fill.
private struct ShortcutItemView: View {
    let shortcut: ShortcutConfig
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(shortcut.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if shortcut.isDefault {
                        Text("默认")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(badgeBg))
                            .foregroundStyle(badgeFg)
                    }
                }
                Text(shortcut.displayString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isSelected ? DesignTokens.Colors.primaryForeground.opacity(0.8) : DesignTokens.Colors.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return DesignTokens.Colors.primary
        } else if isHovered {
            return DesignTokens.Colors.border.opacity(0.4)
        } else {
            return Color.clear
        }
    }

    private var badgeBg: Color {
        isSelected ? DesignTokens.Colors.primaryForeground.opacity(0.22) : DesignTokens.Colors.primary.opacity(0.15)
    }

    private var badgeFg: Color {
        isSelected ? DesignTokens.Colors.primaryForeground.opacity(0.95) : DesignTokens.Colors.primary
    }
}

/// A + / − toolbar button with hover highlight.
private struct ShortcutToolbarButton: View {
    let icon: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hoverBackground)
                )
                .foregroundStyle(disabled ? DesignTokens.Colors.mutedForeground : DesignTokens.Colors.foreground)
                .opacity(disabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            guard !disabled else { return }
            isHovered = hovering
        }
    }

    private var hoverBackground: Color {
        (!disabled && isHovered) ? DesignTokens.Colors.border.opacity(0.5) : Color.clear
    }
}

/// The right-hand detail editor for a single shortcut. Uses the same
/// group-card pattern as the permissions page (secondary surface card +
/// 13pt semibold group header) instead of SwiftUI's `Form` so the look is
/// consistent across all settings tabs.
struct ShortcutDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    @Binding var shortcut: ShortcutConfig
    // 辅助功能权限状态：2s 定时刷新。显示最小化/隐藏窗口依赖 AX 枚举，
    // 未授权时两个开关无效却无任何反馈，需显式提示用户。
    @State private var axGranted = AccessibilityChecker.isTrusted
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Settings.contentSpacing) {
                groupCard("基本信息") {
                    row("名称") {
                        if shortcut.isDefault {
                            Text(shortcut.name)
                                .foregroundStyle(DesignTokens.Colors.mutedForeground)
                        } else {
                            TextField("名称", text: $shortcut.name)
                                .textFieldStyle(.plain)
                        }
                    }
                    divider
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
                                        })
                    }
                }
                groupCard("预览图大小") {
                    Picker("大小", selection: $shortcut.previewSize) {
                        ForEach(AppSettings.PreviewSize.allCases) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("此快捷键切换窗口时的缩略图大小。当前：\(shortcut.previewSize.displayName)")
                        .font(.system(size: DesignTokens.SettingsTypography.caption))
                        .foregroundStyle(DesignTokens.Colors.mutedForeground)
                        .padding(.top, 6)
                }
                groupCard("显示窗口") {
                    Toggle("显示最小化窗口", isOn: $shortcut.showMinimized)
                        .help("在切换器中显示最小化到 Dock 的窗口（显示应用图标）")
                    divider
                    Toggle("显示隐藏窗口", isOn: $shortcut.showHidden)
                        .help("在切换器中显示被 Cmd+H 隐藏的应用的窗口（显示应用图标）")
                    if !axGranted {
                        Label("显示最小化/隐藏窗口需要『辅助功能』权限，当前未授予，开关暂不生效。",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                    }
                    Text("最小化和隐藏的窗口无法实时捕获预览，将显示应用图标和窗口标题")
                        .font(.system(size: DesignTokens.SettingsTypography.caption))
                        .foregroundStyle(DesignTokens.Colors.mutedForeground)
                        .padding(.top, 6)
                }
                groupCard("释放行为") {
                    Picker("快捷键释放后", selection: $shortcut.releaseBehavior) {
                        ForEach(ShortcutConfig.ReleaseBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }
            .padding(4)
        }
        .onReceive(permissionTimer) { _ in
            axGranted = AccessibilityChecker.isTrusted
        }
    }

    /// Group card: secondary surface, 8pt radius, 1px border, 14pt padding.
    private func groupCard<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: DesignTokens.SettingsTypography.groupHeader, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.foreground)
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.vertical, DesignTokens.Settings.groupRowVPadding)
            .padding(.horizontal, DesignTokens.Settings.groupRowHPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Settings.groupCardRadius, style: .continuous)
                    .fill(DesignTokens.Colors.secondarySurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Settings.groupCardRadius, style: .continuous)
                    .strokeBorder(DesignTokens.Colors.border, lineWidth: 1)
            )
        }
    }

    private var divider: some View {
        Divider()
            .opacity(0.6)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Settings.formRowGap) {
            Text(label)
                .font(.system(size: DesignTokens.SettingsTypography.rowLabel))
                .foregroundStyle(DesignTokens.Colors.foreground)
                .frame(width: DesignTokens.Settings.formLabelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

private extension View {
    /// Applies a system cursor over the view's frame. Used for the split divider.
    /// 使用 NSCursor.set() 替代 push()/pop()：push/pop 操作全局 cursor 栈，
    /// 视图销毁时若 onHover(false) 未触发会导致栈不平衡，残留错误光标。
    /// set() 直接替换当前光标，无需平衡；离开时恢复 arrow，onDisappear 兜底。
    @ViewBuilder
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onDisappear { NSCursor.arrow.set() }
    }
}
