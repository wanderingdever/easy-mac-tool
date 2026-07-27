import Combine
import SwiftUI

/// 系统信息设置页：
/// - 启动状态总开关：关闭后 SystemMonitorManager 不采样、菜单栏与下拉面板都不展示。
/// - 菜单栏展示项：勾选哪些指标在菜单栏 E 图标旁显示。
/// - 实时预览：勾选启动后展示 7 项指标当前值，1 秒刷新。
struct SystemInfoSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var monitor = SystemMonitorManager.shared

    // 实时预览刷新计时器：1 秒间隔（与 SystemMonitorManager 采样同步）。
    private let previewTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("系统信息").font(.title2).fontWeight(.semibold)

            // MARK: - 启动状态
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("启动状态", isOn: $settings.systemMonitor.enabled)
                        .tint(.accentColor)
                    Text("关闭后不监控任何系统指标，菜单栏与下拉面板也不显示监控数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - 菜单栏展示项 + 实时预览
            if settings.systemMonitor.enabled {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("菜单栏展示项")
                            .font(.headline)
                        Text("勾选的指标将出现在菜单栏 E 图标右侧，用 | 分隔。常态单色跟随系统深浅色，异常值（如 CPU>80°C）变橙红。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(spacing: 0) {
                            ForEach(SystemMetricKind.allCases) { kind in
                                Toggle(isOn: menuBarItemBinding(kind)) {
                                    HStack(spacing: 8) {
                                        Image(systemName: kind.symbol)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 18)
                                        Text(kind.displayName)
                                        if let live = monitor.metrics.value(for: kind) {
                                            Spacer()
                                            Text(formatValue(live, for: kind))
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                .tint(.accentColor)
                                Divider().padding(.vertical, 4)
                            }
                        }
                    }
                }

                // MARK: - 实时预览完整快照
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("实时预览").font(.headline)
                        Text("当前系统各项指标快照（1 秒刷新）。首次启动需 1-2 秒收集数据。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        metricPreviewGrid
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(previewTimer) { _ in
            // SystemMonitorManager 是 ObservableObject，metrics 变化会自动触发重绘，
            // 这里只是确保 timer 持续活跃（防止系统节能暂停）。
        }
    }

    // MARK: - Subviews

    /// 实时预览网格：2 列布局展示 7 项指标。
    private var metricPreviewGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(SystemMetricKind.allCases) { kind in
                previewCard(kind)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func previewCard(_ kind: SystemMetricKind) -> some View {
        let value = monitor.metrics.value(for: kind)
        let hasValue = value != nil
        return HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(hasValue ? formatValue(value!, for: kind) : "—")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(colorFor(value: value, kind: kind))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
    }

    // MARK: - Helpers

    /// 双向绑定到 settings.systemMonitor.menuBarItems 中某个 kind 的勾选状态。
    private func menuBarItemBinding(_ kind: SystemMetricKind) -> Binding<Bool> {
        Binding(
            get: { settings.systemMonitor.menuBarItems.contains(kind) },
            set: { isOn in
                if isOn { settings.systemMonitor.menuBarItems.insert(kind) }
                else    { settings.systemMonitor.menuBarItems.remove(kind) }
            }
        )
    }

    /// 格式化指标数值为字符串。kind.unit 用于非百分比项，百分比取整后加 %。
    private func formatValue(_ value: Double, for kind: SystemMetricKind) -> String {
        switch kind {
        case .cpuTemperature:
            return "\(Int(value.rounded()))°C"
        case .fanSpeed:
            return "\(Int(value)) RPM"
        case .memory:
            if let used = monitor.metrics.memoryUsedGB,
               let total = monitor.metrics.memoryTotalGB {
                return "\(String(format: "%.1f", used))/\(String(format: "%.0f", total)) GB · \(Int(value * 100))%"
            }
            return "\(Int(value * 100))%"
        case .disk:
            if let used = monitor.metrics.diskUsedGB,
               let total = monitor.metrics.diskTotalGB {
                return "\(String(format: "%.0f", used))/\(String(format: "%.0f", total)) GB · \(Int(value * 100))%"
            }
            return "\(Int(value * 100))%"
        case .cpuUsage, .gpu:
            return "\(Int(value * 100))%"
        case .network:
            // value 是下载速度，额外展示上传速度。
            if let up = monitor.metrics.networkUpload {
                return "↑\(formatSpeed(up)) ↓\(formatSpeed(value))"
            }
            return "↓\(formatSpeed(value))"
        }
    }

    /// 自适应格式化网速（K/M/G）。
    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_073_741_824 {
            return String(format: "%.1fG", bytesPerSec / 1_073_741_824)
        } else if bytesPerSec >= 1_048_576 {
            return String(format: "%.1fM", bytesPerSec / 1_048_576)
        } else if bytesPerSec >= 1024 {
            return String(format: "%.0fK", bytesPerSec / 1024)
        } else {
            return "\(Int(bytesPerSec))B"
        }
    }

    /// 异常值着色逻辑：danger → 红，warning → 橙，否则跟随系统主色。
    private func colorFor(value: Double?, kind: SystemMetricKind) -> Color {
        guard let v = value else { return .secondary }
        if let danger = kind.dangerThreshold, v >= danger { return .red }
        if let warning = kind.warningThreshold, v >= warning { return .orange }
        return .primary
    }
}
