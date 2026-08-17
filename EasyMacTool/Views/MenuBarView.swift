import AppKit
import SwiftUI

/// 菜单栏下拉弹窗（Aurora v2 改版）。
///
/// 结构：可选监控面板（开启系统监控时显示）→ 渐变发丝分隔线 → 底部并排的
/// 「设置」「退出」纯图标按钮。
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.systemMonitorEnabled {
                SystemMonitorPanel(monitor: monitor,
                                   unit: TemperatureUnit(rawValue: settings.temperatureUnit) ?? .celsius)
                    .padding(.top, 8)
            }
            gradientDivider
                .padding(.vertical, 6)
            HStack(spacing: 8) {
                IconButton(icon: "gearshape", label: "设置", action: openSettings)
                IconButton(icon: "power", label: "退出", action: { NSApp.terminate(nil) })
            }
        }
        .padding(8)
        .frame(width: settings.systemMonitorEnabled ? 300 : 200)
        .animation(reduceMotion ? nil : DesignTokens.Aurora.standard,
                   value: settings.systemMonitorEnabled)
        .onAppear { monitor.panelDidAppear() }
        .onDisappear { monitor.panelDidDisappear() }
    }

    // MARK: - 渐变发丝分隔线

    /// 渐变发丝分隔线：品牌渐变白中心向两端渐隐，替代生硬的 Divider。
    private var gradientDivider: some View {
        DesignTokens.Aurora.brandHorizontal
            .opacity(0.35)
            .frame(height: 1)
            .mask(
                LinearGradient(
                    colors: [.clear, .black, .black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .padding(.horizontal, 10)
    }

    /// 直接调用 openWindow 打开设置窗口，不再发送 .openSettings 通知——
    /// 通知会被 BlackEMenuBarIcon 接收再次调 openWindow，形成递归。
    private func openSettings() {
        openWindow(id: "settings")
        DispatchQueue.main.async {
            NSApp.activate()
        }
    }
}

/// 纯图标按钮：圆角方块 + 品牌渐变字形，hover 反白填充。用于设置/退出。
private struct IconButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered
                          ? AnyShapeStyle(DesignTokens.Aurora.brandGradient)
                          : AnyShapeStyle(DesignTokens.Aurora.brandGradient.opacity(0.14)))
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isHovered
                                     ? AnyShapeStyle(.white)
                                     : AnyShapeStyle(DesignTokens.Aurora.brandGradient))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .shadow(color: isHovered ? DesignTokens.Aurora.brandGlow : .clear,
                radius: 6, y: 2)
        .auroraHover($isHovered)
    }
}

/// 菜单栏下拉中的系统监控面板：上层三张放大卡片（CPU 温度、CPU 占用、内存占用），
/// 下层为其余可用参数（GPU、网络、磁盘、功耗、风扇）。数值随快照每 tick 刷新。
private struct SystemMonitorPanel: View {
    @ObservedObject var monitor: SystemMonitor
    let unit: TemperatureUnit
    @State private var pendingTermination: ActiveAppMemoryInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MetricCard(icon: metricIcon("thermometer.medium"),
                           label: "CPU 温度",
                           value: temperatureText(monitor.snapshot.cpuTemperature))
                MetricCard(icon: metricIcon("cpu"),
                           label: "CPU 占用",
                           value: usageText(monitor.snapshot.cpuUsage))
                MetricCard(icon: metricIcon("memorychip"),
                           label: "内存占用",
                           value: memoryText)
            }

            // 活动应用内存（超出高度可滚动）
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignTokens.Aurora.brandGradient)
                    Text("活动应用内存")
                        .scaledSystemFont(10, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(monitor.topMemoryApps) { app in
                            ActiveAppRow(app: app) {
                                pendingTermination = app
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)   // 固定高度，约 5 行，超出滚动
            }

            Rectangle()
                .fill(DesignTokens.Aurora.insetSeparator)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 4) {
                if monitor.snapshot.gpuUsage != nil || monitor.snapshot.gpuTemperature != nil {
                    valueRow(icon: "rectangle.connected.to.line.below",
                             label: "GPU",
                             value: gpuCombinedText)
                }
                if let down = monitor.snapshot.netDownBytesPerSec,
                   let up = monitor.snapshot.netUpBytesPerSec {
                    valueRow(icon: "network",
                             label: "网络",
                             value: "↓\(MetricFormat.bytesPerSecCompact(down)) ↑\(MetricFormat.bytesPerSecCompact(up))")
                }
                if let disk = primaryDisk(from: monitor.snapshot.disk) {
                    valueRow(icon: "internaldrive",
                             label: "磁盘占用",
                             value: MetricFormat.percent(disk.usedFraction))
                }
                if let watts = monitor.snapshot.power?.systemWatts {
                    valueRow(icon: "powerplug.fill",
                             label: "功耗",
                             value: MetricFormat.watts(watts))
                }
                if !monitor.snapshot.fanSpeeds.isEmpty {
                    valueRow(icon: "fanblades",
                             label: "风扇转速",
                             value: monitor.snapshot.fanSpeeds.map { String(Int($0.rounded())) }.joined(separator: "/"))
                }
            }
        }
        .alert("退出应用？", isPresented: Binding(
            get: { pendingTermination != nil },
            set: { if !$0 { pendingTermination = nil } }
        )) {
            Button("取消", role: .cancel) { pendingTermination = nil }
            Button("退出", role: .destructive) {
                if let app = pendingTermination {
                    NSRunningApplication(processIdentifier: app.pid)?.terminate()
                }
                pendingTermination = nil
            }
        } message: {
            Text("将请求 \(pendingTermination?.name ?? "该应用") 退出，请先确认未保存的内容。")
        }
        .padding(.horizontal, 8)
    }

    private func valueRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.Aurora.brandGradient)
                .frame(width: 16)
            Text(label)
                .scaledSystemFont(11, weight: .medium, relativeTo: .caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .scaledSystemFont(11, weight: .semibold, design: .monospaced,
                                  relativeTo: .caption)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    private func temperatureText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return MetricFormat.temperatureCompact(value, unit: unit)
    }

    private func usageText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return MetricFormat.percent(value)
    }

    /// 单个指标图标：品牌渐变、统一尺寸。
    private func metricIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(DesignTokens.Aurora.brandGradient)
    }

    private var gpuCombinedText: String {
        let usage = monitor.snapshot.gpuUsage.map { usageText($0) }
        let temp = monitor.snapshot.gpuTemperature.map { temperatureText($0) }
        switch (usage, temp) {
        case let (u?, t?): return "\(u)｜\(t)"
        case let (u?, nil): return u
        case let (nil, t?): return t
        case (nil, nil): return "--"
        }
    }

    private var memoryText: String {
        let used = monitor.snapshot.memoryUsed
        let total = monitor.snapshot.memoryTotal
        guard let used, let total, total > 0 else { return "--" }
        return "\(MetricFormat.bytes(used)) / \(MetricFormat.bytes(total))"
    }

    private func primaryDisk(from reading: DiskReading?) -> DiskDeviceReading? {
        guard let devices = reading?.devices, !devices.isEmpty else { return nil }
        return devices.first(where: { $0.isInternal }) ?? devices.first
    }
}

/// 上层放大卡片：徽章内放大图标 + 小数值纵向排布（不重叠），徽章下方为标签。
private struct MetricCard<Icon: View>: View {
    let icon: Icon
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 5) {
            VStack(spacing: 4) {
                icon
                Text(value)
                    .scaledSystemFont(11, weight: .semibold, design: .rounded,
                                      relativeTo: .caption)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DesignTokens.Aurora.brandGradient.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(DesignTokens.Aurora.cardBorder, lineWidth: 1)
                    )
            )
            Text(label)
                .scaledSystemFont(9, weight: .medium, relativeTo: .caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

/// 活动应用内存行：图标 + 名称 + 内存大小；hover 时行尾出现关闭按钮，点击退出该应用。
private struct ActiveAppRow: View {
    let app: ActiveAppMemoryInfo
    let onRequestTermination: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "app")
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
            }
            Text(app.name)
                .scaledSystemFont(11, weight: .medium, relativeTo: .caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(MetricFormat.bytes(app.memoryBytes))
                .scaledSystemFont(11, weight: .semibold, design: .monospaced,
                                  relativeTo: .caption)
                .monospacedDigit()
                .foregroundStyle(isHovered ? .primary : .secondary)
            if isHovered {
                Button {
                    onRequestTermination()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignTokens.Aurora.brandGradient)
                }
                .buttonStyle(.plain)
                .help("关闭将直接退出应用，请注意保存数据")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered
                      ? AnyShapeStyle(DesignTokens.Aurora.brandGradient.opacity(0.10))
                      : AnyShapeStyle(.clear))
        )
        .auroraHover($isHovered)
        .accessibilityLabel(app.name)
    }
}
