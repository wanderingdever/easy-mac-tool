import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 系统监控设置页（Aurora v2）：总开关 + 采样配置 + 菜单栏指标编排 + 面板可见性。
struct SystemMonitorSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Settings.contentSpacing) {
                masterSection
                if settings.systemMonitorEnabled {
                    samplingSection
                    menuBarMetricsSection
                    showSectionsSection
                }
            }
            .padding(DesignTokens.Settings.contentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Aurora.pageBackground)
        .onAppear { SystemMonitor.shared.panelDidAppear() }
        .onDisappear { SystemMonitor.shared.panelDidDisappear() }
    }

    // MARK: - Total switch

    private var masterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "通用", systemImage: "gear")
            SettingsCard {
                SettingsToggleRow(
                    title: "启用系统监控",
                    description: "关闭时不采样、不监控、不占用任何资源。开启后在菜单栏显示实时指标。",
                    isOn: Binding(
                        get: { settings.systemMonitorEnabled },
                        set: { newValue in
                            if settings.systemMonitorEnabled != newValue {
                                settings.systemMonitorEnabled = newValue
                                SystemMonitor.shared.setEnabled(newValue, interval: settings.monitorInterval)
                            }
                        }
                    )
                )
            }
        }
    }

    // MARK: - Sampling

    private var samplingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "采样", systemImage: "timer")
            SettingsCard {
                HStack(spacing: DesignTokens.Settings.formRowGap) {
                    Text("刷新间隔")
                        .scaledSystemFont(DesignTokens.SettingsTypography.formLabel)
                        .foregroundStyle(.primary)
                        .frame(width: DesignTokens.Settings.formLabelWidth, alignment: .leading)
                    Picker("刷新间隔", selection: intervalBinding) {
                        Text("1 秒").tag(1)
                        Text("2 秒").tag(2)
                        Text("5 秒").tag(5)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    Spacer(minLength: 0)
                }
                SettingsRowDivider()
                HStack(spacing: DesignTokens.Settings.formRowGap) {
                    Text("温度单位")
                        .scaledSystemFont(DesignTokens.SettingsTypography.formLabel)
                        .foregroundStyle(.primary)
                        .frame(width: DesignTokens.Settings.formLabelWidth, alignment: .leading)
                    Picker("温度单位", selection: $settings.temperatureUnit) {
                        Text("°C").tag(TemperatureUnit.celsius.rawValue)
                        Text("°F").tag(TemperatureUnit.fahrenheit.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { settings.monitorInterval },
            set: { newValue in
                if settings.monitorInterval != newValue {
                    settings.monitorInterval = newValue
                    SystemMonitor.shared.setInterval(seconds: newValue)
                }
            }
        )
    }

    // MARK: - Menu bar metrics

    private var menuBarMetricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "菜单栏指标", systemImage: "menubar.rectangle")
            SettingsCard {
                Text("选择要在菜单栏显示的指标，可按住拖拽排序。")
                    .scaledSystemFont(DesignTokens.SettingsTypography.caption)
                    .foregroundStyle(.secondary)
                ForEach(orderedMetrics) { metric in
                    metricRow(metric: metric)
                    if metric != orderedMetrics.last {
                        SettingsRowDivider()
                    }
                }
            }
        }
    }

    /// Metrics in persisted order, falling back to the default order.
    private var orderedMetrics: [MenuBarMetric] {
        MenuBarMetric.allCases.filter {
            $0.isAvailableOnCurrentHardware
        }.sorted { lhs, rhs in
            let order = settings.menuBarMetricOrder
            let li = order.firstIndex(of: lhs.rawValue) ?? MenuBarMetric.defaultOrder.firstIndex(of: lhs) ?? Int.max
            let ri = order.firstIndex(of: rhs.rawValue) ?? MenuBarMetric.defaultOrder.firstIndex(of: rhs) ?? Int.max
            return li < ri
        }
    }

    private func metricRow(metric: MenuBarMetric) -> some View {
        HStack(spacing: 10) {
            Image(systemName: metric.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(metric.title)
                .scaledSystemFont(DesignTokens.SettingsTypography.toggleTitle, weight: .medium)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Toggle("", isOn: metricIsOn(metric))
                .labelsHidden()
                .accessibilityLabel("在菜单栏显示\(metric.title)")
                .toggleStyle(.switch)
                .tint(DesignTokens.Aurora.controlOn)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func metricIsOn(_ metric: MenuBarMetric) -> Binding<Bool> {
        Binding(
            get: { settings.menuBarMetrics[metric.settingsKey] ?? false },
            set: { newValue in
                settings.menuBarMetrics[metric.settingsKey] = newValue
                if newValue,
                   !settings.menuBarMetricOrder.contains(metric.rawValue) {
                    settings.menuBarMetricOrder.append(metric.rawValue)
                }
            }
        )
    }

    // MARK: - Show sections (preview surface)

    private var showSectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "监控内容", systemImage: "chart.bar")
            SettingsCard {
                SettingsToggleRow(
                    title: "CPU 使用率与温度",
                    description: "显示 CPU 使用率、CPU 温度。",
                    isOn: $settings.monitorShowCPU)
                SettingsRowDivider()
                SettingsToggleRow(
                    title: "GPU 使用率与温度",
                    description: "显示 GPU 使用率、GPU 温度。",
                    isOn: $settings.monitorShowGPU)
                SettingsRowDivider()
                SettingsToggleRow(
                    title: "内存",
                    description: "显示内存占用与压力状态。",
                    isOn: $settings.monitorShowMemory)
                SettingsRowDivider()
                SettingsToggleRow(
                    title: "网络",
                    description: "显示上行/下行速率。",
                    isOn: $settings.monitorShowNetwork)
                SettingsRowDivider()
                SettingsToggleRow(
                    title: "磁盘",
                    description: "显示磁盘 IO 与占用。",
                    isOn: $settings.monitorShowDisk)
                SettingsRowDivider()
                SettingsToggleRow(
                    title: "功耗",
                    description: "显示整机功耗。",
                    isOn: $settings.monitorShowPower)
            }
        }
    }
}
