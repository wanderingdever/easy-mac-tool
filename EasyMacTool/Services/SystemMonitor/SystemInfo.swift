import Darwin
import Foundation
import IOKit.ps

nonisolated struct BatteryInfo: Sendable {
    let percent: Int
    let isCharging: Bool
    let isOnBattery: Bool
}

/// Point-in-time system facts that need no special permissions.
nonisolated enum SystemInfo {
    static func batterySnapshot() -> BatteryInfo? {
        guard PowerSampler.hasInternalBattery else { return nil }
        guard let blobRef = IOPSCopyPowerSourcesInfo() else { return nil }
        let blob = blobRef.takeRetainedValue()
        guard let listRef = IOPSCopyPowerSourcesList(blob) else { return nil }
        let list = listRef.takeRetainedValue() as [AnyObject]
        guard let first = list.first,
              let descRef = IOPSGetPowerSourceDescription(blob, first),
              let desc = descRef.takeUnretainedValue() as? [String: Any]
        else { return nil }

        let current = desc["Current Capacity"] as? Int ?? 0
        let max = desc["Max Capacity"] as? Int ?? 100
        let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
        let charging = desc["Is Charging"] as? Bool ?? false
        let state = desc["Power Source State"] as? String ?? ""
        return BatteryInfo(percent: percent,
                           isCharging: charging,
                           isOnBattery: state == "Battery Power")
    }

    static func memoryUsage() -> (used: UInt64, appUsed: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let total = ProcessInfo.processInfo.physicalMemory
        var kernelPageSize: vm_size_t = 0
        guard host_page_size(host, &kernelPageSize) == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(kernelPageSize)
        let used = MetricFormat.memoryUsed(totalBytes: total,
                                           pageSize: pageSize,
                                           freePages: UInt64(stats.free_count),
                                           speculativePages: UInt64(stats.speculative_count),
                                           fileBackedPages: UInt64(stats.external_page_count))
        let appUsed = MetricFormat.appMemory(totalBytes: total,
                                             pageSize: pageSize,
                                             internalPages: UInt64(stats.internal_page_count),
                                             purgeablePages: UInt64(stats.purgeable_count))
        return (used, appUsed, total)
    }
}
