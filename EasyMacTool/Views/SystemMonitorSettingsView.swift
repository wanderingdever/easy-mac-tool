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
            sectionHeader("系统监控", systemImage: "gauge")
            sectionCard {
                toggleRow(
                    isOn: Binding(
                        get: { settings.systemMonitorEnabled },
                        set: { newValue in
                            if settings.systemMonitorEnabled != newValue {
                                settings.systemMonitorEnabled = newValue
                                SystemMonitor.shared.setEnabled(newValue, interval: settings.monitorInterval)
                            }
                        }
                    ),
                    title: "启用系统监控",
                    desc: "关闭时不采样、不监控、不占用任何资源。开启后在菜单栏显示实时指标。"
                )
            }
        }
    }

    // MARK: - Sampling

    private var samplingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("采样", systemImage: "timer")
            sectionCard {
                HStack(spacing: DesignTokens.Settings.formRowGap) {
                    Text("刷新间隔")
                        .font(.system(size: DesignTokens.SettingsTypography.formLabel))
                        .foregroundStyle(.primary)
                        .frame(width: DesignTokens.Settings.formLabelWidth, alignment: .leading)
                    Picker("", selection: intervalBinding) {
                        Text("1 秒").tag(1)
                        Text("2 秒").tag(2)
                        Text("5 秒").tag(5)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    Spacer(minLength: 0)
                }
                Rectangle()
                    .fill(DesignTokens.Aurora.insetSeparator)
                    .frame(height: 1)
                HStack(spacing: DesignTokens.Settings.formRowGap) {
                    Text("温度单位")
                        .font(.system(size: DesignTokens.SettingsTypography.formLabel))
                        .foregroundStyle(.primary)
                        .frame(width: DesignTokens.Settings.formLabelWidth, alignment: .leading)
                    Picker("", selection: $settings.temperatureUnit) {
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
            sectionHeader("菜单栏指标", systemImage: "menubar.rectangle")
            sectionCard {
                Text("选择要在菜单栏显示的指标，可按住拖拽排序。")
                    .font(.system(size: DesignTokens.SettingsTypography.caption))
                    .foregroundStyle(.secondary)
                ForEach(orderedMetrics) { metric in
                    metricRow(metric: metric)
                    if metric != orderedMetrics.last {
                        Rectangle()
                            .fill(DesignTokens.Aurora.insetSeparator)
                            .frame(height: 1)
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
                .font(.system(size: DesignTokens.SettingsTypography.toggleTitle, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Toggle("", isOn: metricIsOn(metric))
                .labelsHidden()
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
            sectionHeader("监控内容", systemImage: "chart.bar")
            sectionCard {
                toggleRow(
                    isOn: $settings.monitorShowCPU,
                    title: "CPU 使用率与温度",
                    desc: "显示 CPU 使用率、CPU 温度。")
                Rectangle()
                    .fill(DesignTokens.Aurora.insetSeparator)
                    .frame(height: 1)
                toggleRow(
                    isOn: $settings.monitorShowGPU,
                    title: "GPU 使用率与温度",
                    desc: "显示 GPU 使用率、GPU 温度。")
                Rectangle()
                    .fill(DesignTokens.Aurora.insetSeparator)
                    .frame(height: 1)
                toggleRow(
                    isOn: $settings.monitorShowMemory,
                    title: "内存",
                    desc: "显示内存占用与压力状态。")
                Rectangle()
                    .fill(DesignTokens.Aurora.insetSeparator)
                    .frame(height: 1)
                toggleRow(
                    isOn: $settings.monitorShowNetwork,
                    title: "网络",
                    desc: "显示上行/下行速率。")
                Rectangle()
                    .fill(DesignTokens.Aurora.insetSeparator)
                    .frame(height: 1)
                toggleRow(
                    isOn: $settings.monitorShowDisk,
                    title: "磁盘",
                    desc: "显示磁盘 IO 与占用。")
                Rectangle()
                    .fill(DesignTokens.Aurora.insetSeparator)
                    .frame(height: 1)
                toggleRow(
                    isOn: $settings.monitorShowPower,
                    title: "功耗",
                    desc: "显示整机功耗。")
            }
        }
    }

    // MARK: - Shared helpers (mirror ClipboardSettingsView)

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            AuroraIconChip(systemName: systemImage, size: 26)
            Text(title)
                .font(.system(size: DesignTokens.SettingsTypography.subHeader, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .auroraSettingsCard()
    }

    private func toggleRow(isOn: Binding<Bool>, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Settings.formRowGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: DesignTokens.SettingsTypography.toggleTitle, weight: .medium))
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
}