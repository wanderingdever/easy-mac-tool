import SwiftUI

/// Clipboard-history settings (Aurora v2)：分组卡片布局。
/// 呼出快捷键 / 行为 / 历史 三个 section，每个 = 渐变图标 chip 标题 +
/// 浮起卡片（cardSurface + 发丝描边 + 柔和阴影）。
/// Toggle / Slider 统一品牌 tint；破坏操作保持语义红。
struct ClipboardSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    /// Triggers the "clear all" confirmation alert.
    @State private var showClearAlert = false
    /// Triggers the "delete 7-day-old" confirmation alert.
    @State private var showOldCleanupAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Settings.contentSpacing) {
                hotkeySection
                behaviorSection
                historySection
            }
            .padding(DesignTokens.Settings.contentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Aurora.pageBackground)
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

    /// Section header（Aurora v2）：渐变图标 chip + 15pt semibold 标题。
    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            AuroraIconChip(systemName: systemImage, size: 26)
            Text(title)
                .font(.system(size: DesignTokens.SettingsTypography.subHeader, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    /// 卡片容器：section 内容包一层浮起卡片。
    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .auroraSettingsCard()
    }

    // MARK: - Hotkey

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("快捷键", systemImage: "keyboard")
            sectionCard {
                HStack(spacing: DesignTokens.Settings.formRowGap) {
                    Text("快捷键")
                        .font(.system(size: DesignTokens.SettingsTypography.formLabel))
                        .foregroundStyle(.primary)
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
                Text("按下此组合键可在屏幕底部呼出剪切板历史。再次按下或按 Esc 关闭。")
                    .font(.system(size: DesignTokens.SettingsTypography.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("行为", systemImage: "switch.2")
            sectionCard {
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
                    title: "启用剪切板",
                    desc: "关闭后不再记录剪切板内容，剪切板快捷键也将失效。密码管理器始终自动排除。"
                )
                Rectangle()
                    .fill(DesignTokens.Aurora.insetSeparator)
                    .frame(height: 1)
                toggleRow(
                    isOn: $settings.clipboardAutoPaste,
                    title: "自动粘贴",
                    desc: "选中条目后自动将其粘贴到当前应用。关闭则只写回剪切板。"
                ) 
                Rectangle()
                    .fill(DesignTokens.Aurora.insetSeparator)
                    .frame(height: 1)
                toggleRow(
                    isOn: $settings.clipboardLinkPreviewEnabled,
                    title: "链接预览",
                    desc: "开启后对复制的网页链接后台获取标题与站点图标。默认关闭：复制私有或带访问令牌的链接时，应用会主动访问该地址，可能触发服务端副作用。"
                )
            }
        }
    }

    /// Toggle row：标题 14pt medium + 描述 12pt secondary，
    /// 品牌 tint 的 switch 锚定右上。
    private func toggleRow(isOn: Binding<Bool>, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Settings.formRowGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Text(desc)
                    .font(.system(size: DesignTokens.SettingsTypography.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DesignTokens.Aurora.controlOn)
                .controlSize(.small)
                .padding(.top, 2)
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("历史", systemImage: "tray")
            sectionCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: DesignTokens.Settings.formRowGap) {
                        Text("最大保留")
                            .font(.system(size: DesignTokens.SettingsTypography.formLabel))
                            .foregroundStyle(.primary)
                            .frame(width: DesignTokens.Settings.formLabelWidth, alignment: .leading)
                        Slider(value: historyLimitBinding, in: 50...1000, step: 50)
                            .tint(DesignTokens.Aurora.controlOn)
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
                    .foregroundStyle(.secondary)
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
                .padding(.top, 2)
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

/// 破坏操作按钮（Aurora v2）：透明背景 + 红色发丝描边 + 红色文字/图标，
/// hover/按下时填充浅红 surface，圆角 8 与全应用控件圆角一致。
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.error)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(configuration.isPressed || isHovering
                              ? DesignTokens.Colors.errorSurface
                              : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(DesignTokens.Colors.error.opacity(0.6), lineWidth: 1)
                )
                .animation(DesignTokens.Aurora.standard, value: isHovering)
        }
    }
}
