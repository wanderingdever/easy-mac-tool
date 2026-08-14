import Foundation
import IOKit
import IOKit.ps

/// Reads power without any special permission. Total system power and adapter
/// input come from the SMC (the same sensors Activity Monitor's energy tab is
/// built on); battery flow and the charger's rating come from AppleSmartBattery.
final class PowerSampler {
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
    private var batteryService: io_service_t = 0

    private static let systemPowerKeys = ["PSTR", "PDTR"]
    private static let adapterPowerKeys = ["PDTR"]

    init(smc: SMCClient?) {
        self.smc = smc
    }

    deinit {
        if batteryService != 0 {
            IOObjectRelease(batteryService)
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

        if let props = batteryProperties() {
            reading.hasBattery = true
            reading.externalConnected = (props["ExternalConnected"] as? Bool) ?? false
            reading.isCharging = (props["IsCharging"] as? Bool) ?? false
            reading.timeRemainingSeconds = timeRemainingSeconds(
                externalConnected: reading.externalConnected,
                isCharging: reading.isCharging)

            let voltageMv = (props["Voltage"] as? Int) ?? 0
            let amperageMa = (props["Amperage"] as? Int) ?? (props["InstantAmperage"] as? Int) ?? 0
            if voltageMv > 0, amperageMa != 0 {
                reading.batteryWatts = (Double(voltageMv) / 1000.0) * (Double(amperageMa) / 1000.0)
            }

            if let adapter = props["AdapterDetails"] as? [String: Any],
               let rated = adapter["Watts"] as? Int, rated > 0 {
                reading.adapterMaxWatts = Double(rated)
            }

            if let capacity = props["CurrentCapacity"] as? Int,
               let maxCapacity = props["MaxCapacity"] as? Int, maxCapacity > 0 {
                reading.chargePercent = Int((Double(capacity) / Double(maxCapacity) * 100).rounded())
            }
            if let cycles = props["CycleCount"] as? Int { reading.cycleCount = cycles }
            if let design = batteryInt("DesignCapacity", in: props), design > 0 {
                let fullCharge = batteryInt("NominalChargeCapacity", in: props)
                    ?? batteryInt("FullChargeCapacity", in: props)
                    ?? batteryInt("AppleRawMaxCapacity", in: props)
                if let fullCharge, fullCharge > 0 {
                    reading.healthPercent = min(100, Double(fullCharge) / Double(design) * 100)
                }
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

    private func batteryProperties() -> [String: Any]? {
        let service = resolvedBatteryService()
        guard service != 0 else { return nil }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = properties?.takeRetainedValue() as? [String: Any]
        else {
            IOObjectRelease(service)
            batteryService = 0
            return nil
        }
        return dict
    }

    private func timeRemainingSeconds(externalConnected: Bool, isCharging: Bool) -> TimeInterval? {
        guard !externalConnected, !isCharging,
              let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue()
        else { return nil }
        let sources = list as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let minutes = intValue(description[kIOPSTimeToEmptyKey]) else { continue }
            guard minutes > 0 else { return nil }
            return TimeInterval(minutes * 60)
        }
        return nil
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

    private func resolvedBatteryService() -> io_service_t {
        guard Self.hasInternalBattery else { return 0 }
        if batteryService != 0 { return batteryService }
        batteryService = IOServiceGetMatchingService(kIOMainPortDefault,
                                                     IOServiceMatching("AppleSmartBattery"))
        return batteryService
    }
}