import Foundation
import IOKit
import IOKit.ps

/// Reads power without any special permission. Total system power and adapter
/// input come from the SMC (the same sensors Activity Monitor's energy tab is
/// built on); battery flow and the charger's rating come from AppleSmartBattery.
nonisolated final class PowerSampler: @unchecked Sendable {
    /// Internal-battery presence is immutable for the lifetime of a Mac boot.
    static let hasInternalBattery: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }()

    private let smc: SMCClient?
    private var systemKey: SMCClient.Key?
    private var adapterKey: SMCClient.Key?
    private var resolvedKeys = false
    private var batteryServices: [io_service_t] = []

    private static let systemPowerKeys = ["PSTR"]
    private static let adapterPowerKeys = ["PDTR"]

    init(smc: SMCClient?) {
        self.smc = smc
    }

    deinit {
        batteryServices.forEach { service in
            IOObjectRelease(service)
        }
    }

    func sample() -> PowerReading {
        var reading = PowerReading()

        if let smc {
            if !resolvedKeys {
                resolvedKeys = true
                systemKey = Self.systemPowerKeys.lazy.compactMap { smc.key(named: $0) }.first
                adapterKey = Self.adapterPowerKeys.lazy.compactMap { smc.key(named: $0) }.first
            }
            reading.systemWatts = plausibleWatts(systemKey)
            reading.adapterWatts = plausibleWatts(adapterKey)
        }

        let batteries = batteryProperties()
        if !batteries.isEmpty {
            reading.hasBattery = true
            reading.externalConnected = batteries.contains {
                ($0["ExternalConnected"] as? Bool) == true
            }
            reading.isCharging = batteries.contains {
                ($0["IsCharging"] as? Bool) == true
            }
            reading.timeRemainingSeconds = timeRemainingSeconds(
                externalConnected: reading.externalConnected,
                isCharging: reading.isCharging)

            let watts = batteries.compactMap { props -> Double? in
                let voltageMv = intValue(props["Voltage"]) ?? 0
                let amperageMa = [props["Amperage"], props["InstantAmperage"]]
                    .compactMap(intValue)
                    .first(where: { $0 != 0 }) ?? 0
                guard voltageMv > 0, amperageMa != 0 else { return nil }
                return (Double(voltageMv) / 1000.0) * (Double(amperageMa) / 1000.0)
            }
            if !watts.isEmpty {
                reading.batteryWatts = watts.reduce(0, +)
            }

            let adapterRatings = batteries.compactMap { props -> Int? in
                guard let adapter = props["AdapterDetails"] as? [String: Any] else { return nil }
                return intValue(adapter["Watts"])
            }
            if let rated = adapterRatings.max(), rated > 0 { reading.adapterMaxWatts = Double(rated) }

            let capacities = batteries.reduce(into: (current: 0, maximum: 0)) { total, props in
                total.current += max(0, intValue(props["CurrentCapacity"]) ?? 0)
                total.maximum += max(0, intValue(props["MaxCapacity"]) ?? 0)
            }
            if capacities.maximum > 0 {
                reading.chargePercent = Int((Double(capacities.current) / Double(capacities.maximum) * 100).rounded())
            }
            reading.cycleCount = batteries.compactMap { intValue($0["CycleCount"]) }.max()

            let healthTotals = batteries.reduce(into: (full: 0, design: 0)) { total, props in
                guard let design = batteryInt("DesignCapacity", in: props), design > 0 else { return }
                let full = batteryInt("NominalChargeCapacity", in: props)
                    ?? batteryInt("FullChargeCapacity", in: props)
                    ?? batteryInt("AppleRawMaxCapacity", in: props)
                guard let full, full > 0 else { return }
                total.full += full
                total.design += design
            }
            if healthTotals.design > 0 {
                reading.healthPercent = min(100, Double(healthTotals.full) / Double(healthTotals.design) * 100)
            }
        }

        if reading.systemWatts == nil {
            if reading.externalConnected, let input = reading.adapterWatts {
                reading.systemWatts = input
            } else if let flow = reading.batteryWatts, flow < 0 {
                reading.systemWatts = -flow
            }
        }

        return reading
    }

    private func plausibleWatts(_ key: SMCClient.Key?) -> Double? {
        guard let key, let smc, let watts = smc.readValue(key), watts > 0, watts < 1000 else { return nil }
        return watts
    }

    private func batteryProperties() -> [[String: Any]] {
        resolvedBatteryServices().compactMap { service in
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
                    == kIOReturnSuccess else { return nil }
            return properties?.takeRetainedValue() as? [String: Any]
        }
    }

    private func timeRemainingSeconds(externalConnected: Bool, isCharging: Bool) -> TimeInterval? {
        guard !externalConnected, !isCharging,
              let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue()
        else { return nil }
        let sources = list as [CFTypeRef]
        var weightedMinutes = 0.0
        var totalCapacity = 0.0
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let minutes = intValue(description[kIOPSTimeToEmptyKey]) else { continue }
            guard minutes > 0 else { continue }
            let capacity = Double(max(1, intValue(description[kIOPSCurrentCapacityKey]) ?? 1))
            weightedMinutes += Double(minutes) * capacity
            totalCapacity += capacity
        }
        guard totalCapacity > 0 else { return nil }
        return TimeInterval((weightedMinutes / totalCapacity) * 60)
    }

    private func batteryInt(_ key: String, in props: [String: Any]) -> Int? {
        if let value = intValue(props[key]) {
            return value
        }
        if let batteryData = props["BatteryData"] as? [String: Any] {
            return intValue(batteryData[key])
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            let int64 = value.int64Value
            guard int64 >= Int64(Int.min), int64 <= Int64(Int.max) else { return nil }
            return Int(int64)
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private func resolvedBatteryServices() -> [io_service_t] {
        guard Self.hasInternalBattery else { return [] }
        if !batteryServices.isEmpty { return batteryServices }
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSmartBattery"),
                                           &iterator) == kIOReturnSuccess else { return [] }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            batteryServices.append(service)
            service = IOIteratorNext(iterator)
        }
        return batteryServices
    }
}
