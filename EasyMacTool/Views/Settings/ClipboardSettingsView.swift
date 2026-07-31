import SwiftUI

/// Clipboard-history settings: hotkey recorder, history limit, auto-paste
/// toggle, and history management buttons. Mirrors the look of
/// `WindowSwitcherSettingsView`. Layout follows `设置 · 剪切板.html`:
/// 17pt semibold section headers with muted-foreground icons, 12pt captions
/// 6pt below, section body margin-top 14 + gap 12, form rows with 80pt label
/// + 14pt gap.
struct ClipboardSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    /// Triggers the "clear all" confirmation alert.
    @State private var showClearAlert = false
    /// Triggers the "delete 7-day-old" confirmation alert.
    @State private var showOldCleanupAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Settings.contentSpacing) {
            hotkeySection
            Divider()
            behaviorSection
            Divider()
            historySection
        }
        .padding(DesignTokens.Settings.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Colors.card)
        .alert("清空全部剪切板历史？", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                ClipboardManager.shared.clearHistory()
            }
        } message: {
            Text("此操作不可撤销，将删除所有 \(ClipboardManager.shared.items.count) 条记录。")
        }
        .alert("删除7天前的记录？", isPresented: $showOldCleanupAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                ClipboardManager.shared.removeOlderThan(days: 7)
            }
        } message: {
            Text("将删除创建时间超过7天的所有剪切板记录。")
        }
    }

    // MARK: - Section helpers

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

    /// Wraps section body rows with margin-top 14 + 12pt inter-row gap.
    private func sectionBody<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Settings.sectionBodyGap) {
            content()
        }
        .padding(.top, DesignTokens.Settings.sectionBodyTop)
    }

    // MARK: - Hotkey

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("呼出快捷键", systemImage: "keyboard")
            Text("按下此组合键可在屏幕底部呼出剪切板历史。再次按下或按 Esc 关闭。")
                .font(.system(size: DesignTokens.SettingsTypography.caption))
                .foregroundStyle(DesignTokens.Colors.mutedForeground)
                .padding(.top, 6)
            sectionBody {
                HStack(spacing: DesignTokens.Settings.formRowGap) {
                    Text("快捷键")
                        .font(.system(size: DesignTokens.SettingsTypography.formLabel))
                        .foregroundStyle(DesignTokens.Colors.foreground)
                        .frame(width: DesignTokens.Settings.formLabelWidth, alignment: .leading)
                    KeyRecorderView(
                        keyCode: $settings.clipboardShortcut.keyCode,
                        modifiers: $settings.clipboardShortcut.modifiers,
                        validationMessage: { keyCode, modifiers in
                            settings.shortcutConflictMessage(
                                keyCode: keyCode,
                                modifiers: modifiers,
                                includeClipboardShortcut: false
                            )
                        }
                    )
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("行为", systemImage: "switch.2")
            sectionBody {
                toggleRow(
                    isOn: $settings.clipboardAutoPaste,
                    title: "自动粘贴",
                    desc: "选中条目后自动将其粘贴到当前应用。关闭则只写回剪切板。"
                )
                toggleRow(
                    isOn: Binding(
                        get: { settings.clipboardCapturingEnabled },
                        set: { newValue in
                            if settings.clipboardCapturingEnabled != newValue {
                                settings.clipboardCapturingEnabled = newValue
                                ClipboardManager.shared.setCapturing(newValue)
                            }
                        }
                    ),
                    title: "记录剪切板历史",
                    desc: "关闭后不会读取新的剪切板内容；密码管理器会始终自动排除。"
                )
            }
        }
    }

    /// Toggle row matching the design: title 15pt medium + desc 12pt muted,
    /// vertical gap 2pt, toggle anchored top-right.
    private func toggleRow(isOn: Binding<Bool>, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Settings.formRowGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: DesignTokens.SettingsTypography.toggleTitle, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.foreground)
                Text(desc)
                    .font(.system(size: DesignTokens.SettingsTypography.caption))
                    .foregroundStyle(DesignTokens.Colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 2)
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("历史", systemImage: "tray")
            sectionBody {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: DesignTokens.Settings.formRowGap) {
                        Text("最大保留")
                            .font(.system(size: DesignTokens.SettingsTypography.formLabel))
                            .foregroundStyle(DesignTokens.Colors.foreground)
                            .frame(width: DesignTokens.Settings.formLabelWidth, alignment: .leading)
                        Slider(value: historyLimitBinding, in: 50...1000, step: 50)
                        Text("\(settings.clipboardHistoryLimit)")
                            .font(.system(size: DesignTokens.SettingsTypography.sliderValue, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                    // Range labels aligned under the slider track (clearing
                    // the form label column on the left and the value on the
                    // right), matching the design's slider-range-labels.
                    HStack {
                        Text("50")
                            .frame(width: DesignTokens.Settings.formLabelWidth, alignment: .leading)
                        Spacer()
                        Text("1000")
                            .frame(width: 48, alignment: .trailing)
                    }
                    .font(.system(size: DesignTokens.SettingsTypography.sliderRange))
                    .foregroundStyle(DesignTokens.Colors.mutedForeground)
                }
                HStack(spacing: DesignTokens.Spacing.sm) {
                    DestructiveOutlineButton {
                        showOldCleanupAlert = true
                    } label: {
                        Label("删除7天前记录", systemImage: "calendar.badge.minus")
                    }
                    DestructiveOutlineButton {
                        showClearAlert = true
                    } label: {
                        Label("立即清空历史", systemImage: "trash")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
        }
    }

    /// Bridges the `Int` slider to a `Double` binding.
    private var historyLimitBinding: Binding<Double> {
        Binding(
            get: { Double(settings.clipboardHistoryLimit) },
            set: { newValue in
                let intVal = Int(newValue)
                if settings.clipboardHistoryLimit != intVal {
                    settings.clipboardHistoryLimit = intVal
                }
            }
        )
    }
}

/// 设计稿 `.btn-destructive` 样式：透明背景 + 红色描边 + 红色文字/图标，
/// hover/按下时填充浅红 surface（`--state-error-surface` #ffecea / dark）。
/// 对应 `settings-clipboard.html` 中的 .btn-destructive 规则。
/// ButtonStyle 无法持有 hover 状态，用 View 包装实现 hover fill。
private struct DestructiveOutlineButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action) { label() }
            .buttonStyle(HoverStyle(isHovering: isHovering))
            .onHover { isHovering = $0 }
    }

    private struct HoverStyle: ButtonStyle {
        var isHovering: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.Colors.error)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(configuration.isPressed || isHovering
                              ? DesignTokens.Colors.errorSurface
                              : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(DesignTokens.Colors.error, lineWidth: 1)
                )
        }
    }
}
