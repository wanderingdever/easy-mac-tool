import Foundation

/// A live reading that can be pinned next to the menu bar icon.
enum MenuBarMetric: String, CaseIterable, Identifiable, Hashable {
    case cpu
    case cpuTemperature
    case gpu
    case gpuTemperature
    case memory
    case network
    case diskUsage
    case power
    case fanSpeed

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .cpu, .cpuTemperature: return "cpu"
        case .gpu, .gpuTemperature: return "rectangle.connected.to.line.below"
        case .memory: return "memorychip"
        case .network: return "network"
        case .diskUsage: return "internaldrive"
        case .power: return "powerplug.fill"
        case .fanSpeed: return "fanblades"
        }
    }

    var title: String {
        switch self {
        case .cpu: return "CPU 使用率"
        case .cpuTemperature: return "CPU 温度"
        case .gpu: return "GPU 使用率"
        case .gpuTemperature: return "GPU 温度"
        case .memory: return "内存"
        case .network: return "网络"
        case .diskUsage: return "磁盘占用"
        case .power: return "功耗"
        case .fanSpeed: return "风扇转速"
        }
    }

    var isAvailableOnCurrentHardware: Bool {
        switch self {
        case .fanSpeed:
            return SystemMonitor.fanTelemetryAvailable
        default:
            return true
        }
    }

    /// The default order metrics appear in the menu bar.
    static let defaultOrder: [MenuBarMetric] = [
        .cpu, .cpuTemperature,
        .gpu, .gpuTemperature,
        .memory,
        .network, .diskUsage, .power, .fanSpeed,
    ]

    /// Returns one canonical order for both the settings list and the status
    /// item. Persisted entries come first; missing or newly added metrics keep
    /// their default relative order.
    static func ordered(using persistedRawValues: [String]) -> [MenuBarMetric] {
        var seen = Set<MenuBarMetric>()
        var result: [MenuBarMetric] = []
        for rawValue in persistedRawValues {
            guard let metric = MenuBarMetric(rawValue: rawValue),
                  seen.insert(metric).inserted else { continue }
            result.append(metric)
        }
        for metric in defaultOrder where seen.insert(metric).inserted {
            result.append(metric)
        }
        for metric in allCases where seen.insert(metric).inserted {
            result.append(metric)
        }
        return result
    }
}

extension MenuBarMetric {
    /// The settings key used inside `AppSettings.menuBarMetrics` (RawValue).
    var settingsKey: String { rawValue }
}
