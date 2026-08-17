import AppKit
import Combine

/// Manages a separate `NSStatusItem` that renders the pinned system-monitor
/// metric blocks next to the app's menu bar icon. When the monitor is disabled
/// or no metric is enabled, the item is removed — leaving the menu bar clean.
@MainActor
final class SystemMonitorMenuBarController {
    static let shared = SystemMonitorMenuBarController()

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var shownMetrics: [MenuBarMetric] = []

    private init() {
        // Re-render when the settings-driven configuration changes.
        AppSettings.shared.$systemMonitorEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)

        AppSettings.shared.$menuBarMetrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)

        AppSettings.shared.$menuBarMetricOrder
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)

        AppSettings.shared.$temperatureUnit
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)

        // Re-render on every sampling tick.
        SystemMonitor.shared.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
    }

    /// The ordered list of metrics currently enabled in settings.
    private func enabledMetrics() -> [MenuBarMetric] {
        let settings = AppSettings.shared
        let shown = Set(settings.menuBarMetrics.filter { $0.value }.keys)
        let order = settings.menuBarMetricOrder.compactMap(MenuBarMetric.init(rawValue:))
        let ordered = order.filter { shown.contains($0.settingsKey) && $0.isAvailableOnCurrentHardware }
        let remaining = MenuBarMetric.defaultOrder.filter {
            shown.contains($0.settingsKey) && $0.isAvailableOnCurrentHardware && !order.contains($0)
        }
        return ordered + remaining
    }

    /// Reconciles the status item's existence with the current configuration.
    private func update() {
        let settings = AppSettings.shared
        guard settings.systemMonitorEnabled else {
            removeItem()
            return
        }
        let metrics = enabledMetrics()
        shownMetrics = metrics
        guard !metrics.isEmpty else {
            removeItem()
            return
        }
        ensureItem()
        render()
    }

    private func ensureItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = []
        item.isVisible = true
        if let button = item.button {
            button.font = MenuBarMetricsRenderer.statusFont(stacked: false)
            button.alignment = .left
            button.cell?.lineBreakMode = .byClipping
        }
        statusItem = item
    }

    private func render() {
        guard let button = statusItem?.button, !shownMetrics.isEmpty else { return }
        let unit = TemperatureUnit(rawValue: AppSettings.shared.temperatureUnit) ?? .celsius
        let title = MenuBarMetricsRenderer.attributed(for: SystemMonitor.shared.snapshot,
                                                      metrics: shownMetrics,
                                                      temperatureUnit: unit)
        guard !button.attributedTitle.isEqual(to: title) else { return }
        button.attributedTitle = title
    }

    private func removeItem() {
        shownMetrics = []
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }
}
