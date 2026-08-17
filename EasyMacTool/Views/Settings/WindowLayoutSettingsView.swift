import CoreGraphics
import SwiftUI

/// Window-layout settings (Aurora v2)：总开关 + 径向菜单 + 布局快捷键三张卡片。
struct WindowLayoutSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    /// 全局录制互斥：同一时刻仅一个录制器可处于录制态。
    @State private var globalRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Settings.contentSpacing) {
            masterToggleSection
            radialSection
            shortcutsSection
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Settings.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Aurora.pageBackground)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .scaledSystemFont(DesignTokens.SettingsTypography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Master toggle

    private var masterToggleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "通用", systemImage: "gear")
            SettingsCard(spacing: 10) {
                SettingsToggleRow(
                    title: "启用窗口布局",
                    description: "通过快捷键或径向菜单快速排布当前窗口。关闭后不监听任何布局快捷键、零开销。",
                    isOn: $settings.windowLayoutEnabled
                )
            }
        }
    }

    // MARK: - Radial menu

    private var radialSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "径向菜单", systemImage: "circle.grid.cross")
            SettingsCard(spacing: 10) {
                SettingsToggleRow(
                    title: "启用径向菜单",
                    description: "按住鼠标中键并移动鼠标，选择方向后松开即可排布窗口；也可设置下方键盘快捷键呼出。",
                    isOn: $settings.windowLayoutRadialEnabled
                )
                SettingsRowDivider()
                HStack(alignment: .center, spacing: DesignTokens.Settings.formRowGap) {
                    Text("键盘触发")
                        .scaledSystemFont(DesignTokens.SettingsTypography.rowLabel)
                        .foregroundStyle(.primary)
                        .frame(width: DesignTokens.Settings.formLabelWidth, alignment: .leading)
                    KeyTriggerRecorderView(trigger: $settings.windowLayoutRadialKeyTrigger,
                                           isGlobalRecording: $globalRecording)
                    Spacer(minLength: 0)
                }
                caption("中心为全屏，四周为上下左右半屏与四角。纯点击（不移动鼠标）不会触发布局。")
            }
        }
    }

    // MARK: - Layout shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "布局快捷键", systemImage: "keyboard")
            SettingsCard(
                spacing: 0,
                contentInsets: EdgeInsets(
                    top: DesignTokens.Settings.groupRowVPadding,
                    leading: DesignTokens.Settings.groupRowHPadding,
                    bottom: DesignTokens.Settings.groupRowVPadding,
                    trailing: DesignTokens.Settings.groupRowHPadding
                )
            ) {
                ForEach(Array(shortcutActions.enumerated()), id: \.element.rawValue) { index, action in
                    layoutActionRow(action: action)
                    if index < shortcutActions.count - 1 {
                        SettingsRowDivider()
                    }
                }
            }
        }
    }

    /// 设置页展示的布局快捷键项（不含四角；四角仅由径向拨盘使用）。
    private var shortcutActions: [WindowLayoutAction] {
        [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .fullScreen]
    }

    private func layoutActionRow(action: WindowLayoutAction) -> some View {
        HStack(spacing: DesignTokens.Settings.formRowGap) {
            Image(systemName: action.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignTokens.Aurora.brandGradient)
                .frame(width: 22)
            Text(action.displayName)
                .scaledSystemFont(DesignTokens.SettingsTypography.rowLabel)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            KeyRecorderView(
                keyCode: Binding(
                    get: { layoutShortcut(for: action).keyCode },
                    set: { newValue in
                        if let i = settings.windowLayoutShortcuts.firstIndex(where: { $0.action == action }) {
                            settings.windowLayoutShortcuts[i].keyCode = newValue
                        } else {
                            settings.windowLayoutShortcuts.append(LayoutShortcut(action: action, keyCode: newValue, modifiers: []))
                        }
                    }
                ),
                modifiers: Binding(
                    get: { layoutShortcut(for: action).modifiers },
                    set: { newValue in
                        if let i = settings.windowLayoutShortcuts.firstIndex(where: { $0.action == action }) {
                            settings.windowLayoutShortcuts[i].modifiersRaw = newValue.rawValue
                        } else {
                            settings.windowLayoutShortcuts.append(LayoutShortcut(action: action, keyCode: 0, modifiers: newValue))
                        }
                    }
                ),
                validationMessage: { keyCode, modifiers in
                    settings.layoutShortcutConflictMessage(keyCode: keyCode,
                                                           modifiers: modifiers,
                                                           excludingAction: action)
                },
                isGlobalRecording: $globalRecording
            )
        }
    }

    /// 视图求值期间只读；缺失项由 Binding setter 在用户编辑时补入。
    private func layoutShortcut(for action: WindowLayoutAction) -> LayoutShortcut {
        settings.windowLayoutShortcuts.first(where: { $0.action == action })
            ?? LayoutShortcut(action: action, keyCode: 0, modifiers: [])
    }

}

/// Records a modifier-hold trigger (with left/right awareness) for summoning
/// the radial menu. Click to arm, hold the desired modifier(s), then release;
/// the held modifier set is captured.
private struct KeyTriggerRecorderView: View {
    @Binding var trigger: RadialKeyTrigger
    @Binding var isGlobalRecording: Bool

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var currentMods: UInt64 = 0
    @State private var recordingTimeout: Timer?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            Text(isRecording ? "按住修饰键…" : trigger.displayString)
                .scaledSystemFont(DesignTokens.SettingsTypography.kbd, design: .monospaced)
                .tracking(0.6)
                .foregroundStyle(isRecording ? DesignTokens.Aurora.tint : DesignTokens.Colors.foreground)
                .frame(minWidth: 90)
                .padding(.vertical, 5)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Settings.navItemRadius + 2, style: .continuous)
                        .fill(DesignTokens.Aurora.cardSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Settings.navItemRadius + 2, style: .continuous)
                        .strokeBorder(
                            isRecording
                            ? AnyShapeStyle(DesignTokens.Aurora.brandGradient)
                            : AnyShapeStyle(DesignTokens.Aurora.cardBorder),
                            lineWidth: isRecording ? 1.5 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("录制径向菜单触发键")
        .accessibilityValue(isRecording ? "正在录制" : trigger.displayString)
        .accessibilityHint(isRecording ? "按住修饰键后松开以确认" : "按下后开始录制修饰键")
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        if isGlobalRecording { return }
        isRecording = true
        isGlobalRecording = true
        currentMods = 0
        HotkeyManager.shared.beginRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            let held = UInt64(event.modifierFlags.rawValue) & ModifierBits.deviceMask
            if held != 0 {
                currentMods = held
            } else if currentMods != 0 {
                // All modifiers released: confirm the captured set.
                trigger.modifiersRaw = currentMods
                currentMods = 0
                stopRecording()
            }
            return event
        }
        let timeout = Timer(timeInterval: 10, repeats: false) { _ in
            Task { @MainActor in stopRecording() }
        }
        RunLoop.main.add(timeout, forMode: .common)
        recordingTimeout = timeout
    }

    private func stopRecording() {
        recordingTimeout?.invalidate()
        recordingTimeout = nil
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard isRecording else { return }
        isRecording = false
        isGlobalRecording = false
        HotkeyManager.shared.endRecording()
    }
}
