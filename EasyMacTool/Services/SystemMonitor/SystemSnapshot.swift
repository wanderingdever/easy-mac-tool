import Foundation

/// Memory pressure as reported by the kernel.
nonisolated enum MemoryPressure: Sendable {
    case normal, warning, critical, unknown

    init(kernelLevel: Int32) {
        switch kernelLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }
}

/// One refresh tick of the system monitor. Optionals stay nil when a reading
/// is unavailable on the current hardware.
nonisolated struct SystemSnapshot: Sendable {
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var cpuUsage: Double?
    var gpuUsage: Double?
    var memoryUsed: UInt64?
    var memoryAppUsed: UInt64?
    var memoryTotal: UInt64?
    var memoryPressure: MemoryPressure = .unknown
    var fanSpeeds: [Double] = []

    // Network
    var netDownBytesPerSec: Double?
    var netUpBytesPerSec: Double?
    var netTotalDown: UInt64?
    var netTotalUp: UInt64?

    // Power
    var power: PowerReading?

    // Disk
    var disk: DiskReading?

    // History (oldest → newest)
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    var memoryAppHistory: [Double] = []
    var netDownHistory: [Double] = []
    var netUpHistory: [Double] = []
    var diskReadHistory: [Double] = []
    var diskWriteHistory: [Double] = []
    var systemPowerHistory: [Double] = []
}

nonisolated struct DiskReading: Sendable {
    var devices: [DiskDeviceReading]

    var uniqueIODevices: [DiskDeviceReading] {
        var seen = Set<String>()
        return devices.filter { d in
            guard let id = d.ioCounterID else { return false }
            return seen.insert(id).inserted
        }
    }
}

nonisolated struct DiskDeviceReading: Sendable {
    var id: String
    var name: String
    var mountPath: String
    var bsdName: String?
    var wholeDisk: String?
    var ioCounterID: String?
    var fileSystem: String?
    var totalBytes: UInt64?
    var freeBytes: UInt64?
    var usedBytes: UInt64?
    var isInternal: Bool
    var isRemovable: Bool
    var isEjectable: Bool
    var readBytesPerSec: Double?
    var writeBytesPerSec: Double?
    var totalReadBytes: UInt64?
    var totalWrittenBytes: UInt64?

    var usedFraction: Double {
        guard let total = totalBytes, total > 0, let used = usedBytes else { return 0 }
        return Double(used) / Double(total)
    }
}

nonisolated struct PowerReading: Sendable {
    var systemWatts: Double?
    var adapterWatts: Double?
    var adapterMaxWatts: Double?
    var batteryWatts: Double?
    var chargePercent: Int?
    var timeRemainingSeconds: TimeInterval?
    var healthPercent: Double?
    var cycleCount: Int?
    var isCharging = false
    var externalConnected = false
    var hasBattery = false

    var isEmpty: Bool {
        systemWatts == nil && adapterWatts == nil && adapterMaxWatts == nil
            && batteryWatts == nil && !hasBattery
    }
}
