import SwiftUI

/// 下拉菜单顶部的系统信息面板：
/// - 第一排：CPU 温度 | 内存 | 网速（3 个指标卡片）
/// - 第二排：磁盘占用情况（横向进度条）
///
/// 仅当 SystemMonitorConfig.enabled == true 时由 MenuBarView 渲染，
/// 关闭时整个面板不显示，菜单栏下拉只剩底部图标按钮。
struct SystemMonitorPanel: View {
    @ObservedObject private var monitor = SystemMonitorManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 第一排：3 个指标卡片。
            HStack(spacing: 8) {
                MetricCard(
                    kind: .cpuTemperature,
                    value: monitor.metrics.cpuTemperature,
                    subtitle: monitor.metrics.fanSpeeds?.first.map { "\($0) RPM" }
                )
                MetricCard(
                    kind: .memory,
                    value: monitor.metrics.memoryUsage,
                    subtitle: subtitleMemory()
                )
                MetricCard(
                    kind: .network,
                    value: monitor.metrics.networkDownload,
                    subtitle: subtitleNetwork()
                )
            }

            // 第二排：磁盘占用进度条。
            DiskUsageBar(
                usage: monitor.metrics.diskUsage,
                usedGB: monitor.metrics.diskUsedGB,
                totalGB: monitor.metrics.diskTotalGB
            )
        }
    }

    // MARK: - Subtitle helpers

    private func subtitleMemory() -> String? {
        guard let used = monitor.metrics.memoryUsedGB,
              let total = monitor.metrics.memoryTotalGB else { return nil }
        return "\(String(format: "%.1f", used))/\(String(format: "%.0f", total)) GB"
    }

    private func subtitleNetwork() -> String? {
        guard let up = monitor.metrics.networkUpload else { return nil }
        return "↑ \(formatSpeed(up))"
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 {
            return String(format: "%.1f M/s", bytesPerSec / 1_048_576)
        } else if bytesPerSec >= 1024 {
            return String(format: "%.0f K/s", bytesPerSec / 1024)
        } else {
            return "\(Int(bytesPerSec)) B/s"
        }
    }
}

/// 单个指标卡片：图标 + 标题 + 大数值 + 副标题。
/// 异常值着色（橙/红），常态单色。
struct MetricCard: View {
    let kind: SystemMetricKind
    let value: Double?
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(kind.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let v = value {
                Text(mainValue(v))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(colorFor(v))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("—")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // 副标题行：温度卡显示风扇转速，内存卡显示 X/Y GB，网速卡显示上传速度。
            Text(subtitle ?? " ")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func mainValue(_ v: Double) -> String {
        switch kind {
        case .cpuTemperature: return "\(Int(v.rounded()))°C"
        case .memory:         return "\(Int(v * 100))%"
        case .network:        return formatSpeed(v)
        default:              return "\(Int(v * 100))%"
        }
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 {
            return String(format: "%.1f M/s", bytesPerSec / 1_048_576)
        } else if bytesPerSec >= 1024 {
            return String(format: "%.0f K/s", bytesPerSec / 1024)
        } else {
            return "\(Int(bytesPerSec)) B/s"
        }
    }

    private func colorFor(_ v: Double) -> Color {
        if let danger = kind.dangerThreshold, v >= danger { return .red }
        if let warning = kind.warningThreshold, v >= warning { return .orange }
        return .primary
    }
}

/// 磁盘占用横向进度条：渐变填充 + 已用/总容量文本。
struct DiskUsageBar: View {
    let usage: Double?          // 0.0-1.0
    let usedGB: Double?
    let totalGB: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("磁盘")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let u = usage {
                    Text("\(Int(u * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(colorFor(u))
                }
                if let used = usedGB, let total = totalGB {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("\(String(format: "%.0f", used))/\(String(format: "%.0f", total)) GB")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            // 进度条：常态蓝色，warning 橙，danger 红。
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary.opacity(0.5))
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * (usage ?? 0))
                }
            }
            .frame(height: 6)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var barColor: Color {
        guard let u = usage else { return .accentColor }
        if let danger = SystemMetricKind.disk.dangerThreshold, u >= danger { return .red }
        if let warning = SystemMetricKind.disk.warningThreshold, u >= warning { return .orange }
        return .accentColor
    }

    private func colorFor(_ v: Double) -> Color {
        if let danger = SystemMetricKind.disk.dangerThreshold, v >= danger { return .red }
        if let warning = SystemMetricKind.disk.warningThreshold, v >= warning { return .orange }
        return .primary
    }
}
