import SwiftUI

/// Clipboard-history settings: hotkey recorder, history limit, auto-paste
/// toggle, and history management buttons. Mirrors the look of
/// `WindowSwitcherSettingsView`.
struct ClipboardSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    /// Triggers the "clear all" confirmation alert.
    @State private var showClearAlert = false
    /// Triggers the "delete 7-day-old" confirmation alert.
    @State private var showOldCleanupAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            hotkeySection
            Divider()
            behaviorSection
            Divider()
            historySection
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
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

    // MARK: - Hotkey

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("呼出快捷键", systemImage: "keyboard")
                .font(.headline)
            Text("按下此组合键可在屏幕底部呼出剪切板历史。再次按下或按 Esc 关闭。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("快捷键")
                    .frame(width: 80, alignment: .leading)
                KeyRecorderView(
                    keyCode: $settings.clipboardShortcut.keyCode,
                    modifiers: $settings.clipboardShortcut.modifiers
                )
            }
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("行为", systemImage: "switch.2")
                .font(.headline)
            Toggle(isOn: $settings.clipboardAutoPaste) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动粘贴")
                    Text("选中条目后自动将其粘贴到当前应用。关闭则只写回剪切板。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("历史", systemImage: "tray.full")
                .font(.headline)
            HStack(spacing: 12) {
                Text("最大保留")
                    .frame(width: 80, alignment: .leading)
                Slider(value: historyLimitBinding, in: 50...1000, step: 50) {
                    Text("历史数量上限")
                } minimumValueLabel: {
                    Text("50")
                } maximumValueLabel: {
                    Text("1000")
                }
                Text("\(settings.clipboardHistoryLimit)")
                    .frame(width: 48, alignment: .trailing)
                    .font(.system(.body, design: .monospaced))
            }
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    showOldCleanupAlert = true
                } label: {
                    Label("删除7天前记录", systemImage: "calendar.badge.minus")
                }
                Button(role: .destructive) {
                    showClearAlert = true
                } label: {
                    Label("立即清空历史", systemImage: "trash")
                }
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    /// Bridges the `Int` slider to a `Double` binding.
    private var historyLimitBinding: Binding<Double> {
        Binding(
            get: { Double(settings.clipboardHistoryLimit) },
            set: { settings.clipboardHistoryLimit = Int($0) }
        )
    }
}
