import SwiftUI

/// 菜单栏组合 Label：E 图标 + 选中指标的数值（用 | 分隔）。
///
/// 仅当 SystemMonitorConfig.enabled == true 时展示数值；
/// 关闭监控时只显示 E 图标（保持原始菜单栏外观）。
///
/// 数值样式（混合）：常态单色（跟随系统深浅色，与 E 图标 template 一致），
/// 异常值着色：warning 阈值变橙、danger 阈值变红。
struct MenuBarLabel: View {
    @ObservedObject private var monitor = SystemMonitorManager.shared
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            BlackEMenuBarIcon()

            // 仅当监控启动且有勾选项时展示数值。无勾选项时仅显示 E 图标，
            // 保持菜单栏紧凑。
            if settings.systemMonitor.enabled,
               !settings.systemMonitor.menuBarItems.isEmpty {
                let items = settings.systemMonitor.menuBarItems.sorted { $0.rawValue < $1.rawValue }
                ForEach(Array(items.enumerated()), id: \.element) { idx, kind in
                    if idx > 0 {
                        Text("|")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    MetricLabel(
                        kind: kind,
                        value: monitor.metrics.value(for: kind),
                        memoryUsedGB: monitor.metrics.memoryUsedGB,
                        memoryTotalGB: monitor.metrics.memoryTotalGB,
                        diskUsedGB: monitor.metrics.diskUsedGB,
                        diskTotalGB: monitor.metrics.diskTotalGB,
                        networkUpload: monitor.metrics.networkUpload
                    )
                }
            }
        }
        // 关键：覆盖默认的 firstTextBaseline 对齐，让 E 图标（NSImage 18pt）
        // 与数值 Text 在垂直中心对齐。否则 SwiftUI 会按 Text 基线对齐导致错位。
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
    }
}

/// 单个指标的菜单栏显示。常态单色（template 跟随系统深浅色），
/// 异常值（超过 warning/danger 阈值）变橙/红。
///
/// 字号 11pt monospaced，与 E 图标（18×18）视觉对齐。
/// 高度未固定，由 SwiftUI 自适应菜单栏高度。
struct MetricLabel: View {
    let kind: SystemMetricKind
    let value: Double?
    // 内存/磁盘/网速等需要多字段格式化时透传。
    let memoryUsedGB: Double?
    let memoryTotalGB: Double?
    let diskUsedGB: Double?
    let diskTotalGB: Double?
    let networkUpload: Double?

    var body: some View {
        if let v = value {
            Text(formattedText(v))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(textColor(v))
        } else {
            // 采集失败（如 SMC 不可用）显示占位符，保持菜单栏宽度稳定。
            Text("—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Formatting

    /// 菜单栏数值格式化（紧凑模式）：
    /// - 百分比：`62%`
    /// - 温度：`45°C`
    /// - 风扇：`1523`（不显示 RPM 单位节省空间，下拉面板显示完整单位）
    /// - 内存/磁盘：仅显示百分比（菜单栏空间有限）
    /// - 网速：`↓2.3M` 单值（主指标下载），上传在悬浮提示
    private func formattedText(_ value: Double) -> String {
        switch kind {
        case .cpuTemperature:
            return "\(Int(value.rounded()))°"
        case .fanSpeed:
            return "\(Int(value))"
        case .memory, .disk, .cpuUsage, .gpu:
            return "\(Int(value * 100))%"
        case .network:
            return "↓\(formatSpeed(value))"
        }
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 {
            return String(format: "%.1fM", bytesPerSec / 1_048_576)
        } else if bytesPerSec >= 1024 {
            return String(format: "%.0fK", bytesPerSec / 1024)
        } else {
            return "\(Int(bytesPerSec))B"
        }
    }

    // MARK: - Color

    private func textColor(_ value: Double) -> Color {
        if let danger = kind.dangerThreshold, value >= danger { return .red }
        if let warning = kind.warningThreshold, value >= warning { return .orange }
        // 常态跟随系统主色——SwiftUI Text 在菜单栏 label 中会自动按深浅色
        // 渲染为白色（深色菜单栏）或黑色（浅色菜单栏）。
        return .primary
    }
}
