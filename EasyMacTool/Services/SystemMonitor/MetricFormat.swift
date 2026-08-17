import Foundation

/// Cumulative interface byte counters (since boot), read from the kernel.
nonisolated struct NetworkCounters: Equatable, Sendable {
    var received: UInt64 = 0
    var sent: UInt64 = 0
}

nonisolated struct DiskIOCounters: Equatable, Sendable {
    var read: UInt64 = 0
    var written: UInt64 = 0
}

/// Pure, deterministic helpers for the system monitor: number formatting, the
/// fixed-size history buffer, network speed math and interface filtering.
nonisolated enum MetricFormat {
    // MARK: Memory

    static func memoryUsed(totalBytes: UInt64,
                           pageSize: UInt64,
                           freePages: UInt64,
                           speculativePages: UInt64,
                           fileBackedPages: UInt64) -> UInt64 {
        guard totalBytes > 0, pageSize > 0 else { return 0 }
        let freeAndSpeculative = freePages.addingReportingOverflow(speculativePages)
        guard !freeAndSpeculative.overflow else { return 0 }
        let availablePages = freeAndSpeculative.partialValue.addingReportingOverflow(fileBackedPages)
        guard !availablePages.overflow else { return 0 }
        let availableBytes = availablePages.partialValue.multipliedReportingOverflow(by: pageSize)
        guard !availableBytes.overflow else { return 0 }
        return availableBytes.partialValue >= totalBytes ? 0 : totalBytes - availableBytes.partialValue
    }

    static func appMemory(totalBytes: UInt64,
                          pageSize: UInt64,
                          internalPages: UInt64,
                          purgeablePages: UInt64) -> UInt64 {
        guard totalBytes > 0, pageSize > 0 else { return 0 }
        let activePages = internalPages.subtractingReportingOverflow(purgeablePages)
        guard !activePages.overflow else { return 0 }
        let activeBytes = activePages.partialValue.multipliedReportingOverflow(by: pageSize)
        guard !activeBytes.overflow else { return 0 }
        return min(activeBytes.partialValue, totalBytes)
    }

    static func menuBarMemoryPercent(used: UInt64?, total: UInt64?) -> String {
        guard let used, let total, total > 0 else { return "--%" }
        return percent(Double(used) / Double(total))
    }

    // MARK: Byte sizes

    static func scale(_ bytes: Double) -> (value: Double, unit: String) {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(0, bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return (value, units[index])
    }

    private static func number(_ value: Double, unit: String) -> String {
        if unit == "B" { return String(format: "%.0f", value) }
        return value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }

    static func bytes(_ bytes: UInt64) -> String {
        let (value, unit) = scale(Double(bytes))
        return "\(number(value, unit: unit)) \(unit)"
    }

    static func bytesPerSec(_ bytesPerSecond: Double) -> String {
        let (value, unit) = scale(bytesPerSecond)
        return "\(number(value, unit: unit)) \(unit)/s"
    }

    static func bytesPerSecCompact(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G", "T", "P"]
        var value = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        while index < units.count - 1 {
            if index == 0 {
                guard value.rounded() >= 1024 else { break }
            } else if value >= 10 {
                guard value.rounded() >= 1024 else { break }
            } else {
                break
            }
            value /= 1024
            index += 1
        }
        if index == 0 {
            return "\(Int(value.rounded()))B"
        }
        if value < 10 {
            let rounded = (value * 10).rounded() / 10
            if rounded >= 10 {
                return "\(Int(rounded.rounded()))\(units[index])"
            }
            return String(format: "%.1f%@", rounded, units[index])
        }
        return "\(Int(value.rounded()))\(units[index])"
    }

    // MARK: Watts & percentages

    static func watts(_ value: Double) -> String {
        let magnitude = abs(value)
        return magnitude < 10 ? String(format: "%.1f W", value) : String(format: "%.0f W", value)
    }

    static func wattsCompact(_ value: Double) -> String {
        String(format: "%.0fW", value.rounded())
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    static func stabilizedGPUUsage(previous: Double?, current: Double) -> Double {
        let value = current.isFinite ? max(0, min(1, current)) : 0
        guard let previous, previous.isFinite else { return value }
        let baseline = max(0, min(1, previous))
        if value > baseline {
            return min(value, baseline + 0.20)
        }
        return baseline * 0.35 + value * 0.65
    }

    static func temperature(_ celsius: Double, unit: TemperatureUnit) -> String {
        switch unit {
        case .celsius:
            return String(format: "%.0f °C", celsius)
        case .fahrenheit:
            return String(format: "%.0f °F", celsius * 9 / 5 + 32)
        }
    }

    static func temperatureCompact(_ celsius: Double, unit: TemperatureUnit) -> String {
        switch unit {
        case .celsius:
            return String(format: "%.0f°", celsius)
        case .fahrenheit:
            return String(format: "%.0f°", celsius * 9 / 5 + 32)
        }
    }

    static func temperatureUnitSuffix(_ unit: TemperatureUnit) -> String {
        switch unit {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }

    static func uptime(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)min" }
        return "\(minutes)min"
    }

    // MARK: Network speed & filtering

    static func netSpeed(previous: NetworkCounters,
                         current: NetworkCounters,
                         elapsed: Double) -> (down: Double, up: Double) {
        guard elapsed > 0 else { return (0, 0) }
        let down = current.received >= previous.received
            ? Double(current.received - previous.received) / elapsed : 0
        let up = current.sent >= previous.sent
            ? Double(current.sent - previous.sent) / elapsed : 0
        return (down, up)
    }

    static func diskSpeed(previous: DiskIOCounters,
                          current: DiskIOCounters,
                          elapsed: Double) -> (read: Double, write: Double) {
        guard elapsed > 0 else { return (0, 0) }
        let read = current.read >= previous.read
            ? Double(current.read - previous.read) / elapsed : 0
        let write = current.written >= previous.written
            ? Double(current.written - previous.written) / elapsed : 0
        return (read, write)
    }

    static func includeNetworkInterface(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let excluded = ["lo", "gif", "stf", "awdl", "llw", "nan", "utun", "bridge",
                        "ap", "anpi", "p2p", "XHC", "vmenet", "tap", "tun"]
        return !excluded.contains { name.hasPrefix($0) }
    }
}

nonisolated enum TemperatureUnit: String, Sendable {
    case celsius
    case fahrenheit
}

/// Fixed-size ring of recent samples (oldest → newest) for the history graphs.
nonisolated struct MetricHistory: Sendable {
    let capacity: Int
    private var storage: [Double] = []
    private var startIndex = 0

    var values: [Double] {
        guard storage.count == capacity, startIndex != 0 else { return storage }
        return Array(storage[startIndex...]) + Array(storage[..<startIndex])
    }

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func push(_ value: Double) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[startIndex] = value
            startIndex = (startIndex + 1) % capacity
        }
    }
}
