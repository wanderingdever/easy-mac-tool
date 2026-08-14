import Combine
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Reads temperatures (SMC), CPU/GPU usage, memory, network, disk and power on
/// a background queue. Runs only while `setEnabled(true)` has been called —
/// when disabled it holds no timer and samples nothing (zero idle cost).
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var snapshot = SystemSnapshot()
    /// 内存占用最高的几个运行应用（菜单栏下拉「活动应用内存」区块）。
    @Published private(set) var topMemoryApps: [ActiveAppMemoryInfo] = []

    private let queue = DispatchQueue(label: "com.easymactool.system-monitor", qos: .utility)
    private var timer: Timer?
    private var intervalSeconds = 2
    private var enabled = false
    private var refreshInFlight = false
    private var pendingRefresh = false

    // SMC sensors
    private var smc: SMCClient?
    private var smcTried = false
    private var powerSampler: PowerSampler?
    private var cpuKeys: [SMCClient.Key] = []
    private var preferredCPUKeys: [SMCClient.Key] = []
    private var fallbackCPUKeys: [SMCClient.Key] = []
    private var gpuKeys: [SMCClient.Key] = []
    private var fanKeys: [SMCClient.Key] = []
    private var tempKeysPrepared = false
    private var fanKeysPrepared = false
    private var hasSMC = false
    private var cpuTemperaturePlatform: CPUTemperaturePlatform = .generic

    // Samplers
    private let networkSampler = NetworkSampler()
    private let diskSampler = DiskSampler()

    // Running state
    private var previousCPUTicks: (busy: UInt64, total: UInt64)?
    private var lastCPUUsage: Double?
    private var lastGPUUsage: Double?
    private var missedCPUUsageSamples = 0
    private var missedGPUUsageSamples = 0
    private var memoryCache: CachedMemoryReading?
    private var cpuTemperatureCache: CachedSensorReading?
    private var gpuTemperatureCache: CachedSensorReading?
    private var lastFanSpeeds: [Double] = []
    private var missedFanSpeedSamples = 0
    private var lastDiskReading: DiskReading?
    private var lastPowerReading: PowerReading?

    // History
    private let historyCapacity = 120
    private var cpuHistory: MetricHistory
    private var gpuHistory: MetricHistory
    private var memoryHistory: MetricHistory
    private var memoryAppHistory: MetricHistory
    private var netDownHistory: MetricHistory
    private var netUpHistory: MetricHistory
    private var diskReadHistory: MetricHistory
    private var diskWriteHistory: MetricHistory
    private var powerHistory: MetricHistory

    /// 活动应用内存采样节流计数（后台队列）：每 5 个 tick 才全量枚举进程一次。
    private var appMemoryTick = 0
    /// 后台队列持有的最近一次活动应用内存结果（节流时复用，
    /// 避免在后台线程读取 @Published 的 topMemoryApps 造成数据竞争）。
    private var lastTopMemoryApps: [ActiveAppMemoryInfo] = []

    private struct CachedMemoryReading {
        var used: UInt64
        var appUsed: UInt64
        var total: UInt64
        var pressure: MemoryPressure
        var updatedAt: TimeInterval
        var missedSamples: Int
    }

    private init() {
        cpuHistory = MetricHistory(capacity: historyCapacity)
        gpuHistory = MetricHistory(capacity: historyCapacity)
        memoryHistory = MetricHistory(capacity: historyCapacity)
        memoryAppHistory = MetricHistory(capacity: historyCapacity)
        netDownHistory = MetricHistory(capacity: historyCapacity)
        netUpHistory = MetricHistory(capacity: historyCapacity)
        diskReadHistory = MetricHistory(capacity: historyCapacity)
        diskWriteHistory = MetricHistory(capacity: historyCapacity)
        powerHistory = MetricHistory(capacity: historyCapacity)
    }

    // MARK: - Lifecycle

    /// Total enable switch. When `false` the monitor stops sampling and clears
    /// cached readings — zero resource cost.
    @MainActor
    func setEnabled(_ active: Bool, interval: Int? = nil) {
        if let interval { setInterval(seconds: interval) }
        guard active != enabled else {
            if active { ensureTimer() }
            return
        }
        enabled = active
        if active {
            ensureTimer()
            refresh()
        } else {
            stopTimer()
            snapshot = SystemSnapshot()
            // 清缓存派到后台串行队列执行：避免与在途采样的缓存读写跨线程竞争。
            // 串行队列保证清缓存排在该在途采样之后，不会清掉采样刚写入的值。
            queue.async { [weak self] in self?.resetCaches() }
        }
    }

    @MainActor
    func setInterval(seconds: Int) {
        let clamped = max(1, seconds)
        guard clamped != intervalSeconds else { return }
        intervalSeconds = clamped
        if timer != nil { restartTimer() }
    }

    /// A full monitor surface became visible (Settings preview).
    @MainActor
    func panelDidAppear() {
        guard enabled else { return }
        ensureTimer()
        refresh()
    }

    @MainActor
    func panelDidDisappear() {
        stopTimerIfIdle()
    }

    // MARK: - Timer

    private func ensureTimer() {
        guard enabled, timer == nil else { return }
        startTimer()
    }

    private func stopTimerIfIdle() {
        guard !enabled else { return }
        stopTimer()
    }

    private func startTimer() {
        let t = Timer(timeInterval: TimeInterval(intervalSeconds), repeats: true) { [weak self] _ in
            self?.refresh()
        }
        t.tolerance = TimeInterval(intervalSeconds) * 0.15
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        startTimer()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func resetCaches() {
        smcTried = false
        smc = nil
        powerSampler = nil
        tempKeysPrepared = false
        fanKeysPrepared = false
        previousCPUTicks = nil
        lastCPUUsage = nil
        lastGPUUsage = nil
        lastFanSpeeds = []
        memoryCache = nil
        cpuTemperatureCache = nil
        gpuTemperatureCache = nil
        lastDiskReading = nil
        lastPowerReading = nil
        appMemoryTick = 0
        lastTopMemoryApps = []
    }

    // MARK: - Refresh

    private func refresh() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        guard enabled else {
            stopTimerIfIdle()
            return
        }
        if refreshInFlight {
            pendingRefresh = true
            return
        }
        refreshInFlight = true

        queue.async { [weak self] in
            guard let self else { return }
            self.prepareIfNeeded()
            let now = ProcessInfo.processInfo.systemUptime
            var next = SystemSnapshot()

            // CPU usage
            if let cpu = self.readCPUUsage() {
                self.lastCPUUsage = cpu
                self.missedCPUUsageSamples = 0
                self.cpuHistory.push(cpu)
            } else if self.missedCPUUsageSamples < 3 {
                self.missedCPUUsageSamples += 1
            } else {
                self.lastCPUUsage = nil
            }
            next.cpuUsage = self.lastCPUUsage

            // GPU usage
            if let gpu = Self.readGPUUsage() {
                self.lastGPUUsage = MetricFormat.stabilizedGPUUsage(previous: self.lastGPUUsage, current: gpu)
                self.missedGPUUsageSamples = 0
                if let gpu = self.lastGPUUsage { self.gpuHistory.push(gpu) }
            } else if self.missedGPUUsageSamples < 3 {
                self.missedGPUUsageSamples += 1
            } else {
                self.lastGPUUsage = nil
            }
            next.gpuUsage = self.lastGPUUsage

            // Memory
            if let memory = self.readMemory(now: now) {
                next.memoryUsed = memory.used
                next.memoryAppUsed = memory.appUsed
                next.memoryTotal = memory.total
                next.memoryPressure = memory.pressure
                if memory.isFresh, memory.total > 0 {
                    self.memoryHistory.push(Double(memory.used) / Double(memory.total))
                    self.memoryAppHistory.push(Double(memory.appUsed) / Double(memory.total))
                }
            }

            // Network
            let network = self.networkSampler.sample(now: now)
            next.netDownBytesPerSec = network.downBytesPerSec
            next.netUpBytesPerSec = network.upBytesPerSec
            next.netTotalDown = network.totalDown
            next.netTotalUp = network.totalUp
            if let down = network.downBytesPerSec { self.netDownHistory.push(down) }
            if let up = network.upBytesPerSec { self.netUpHistory.push(up) }

            // Disk
            let disk = self.diskSampler.sample(now: now, refreshMetadata: true)
            self.lastDiskReading = disk
            next.disk = disk
            let ioDevices = disk.uniqueIODevices
            let readValues = ioDevices.compactMap(\.readBytesPerSec)
            let writeValues = ioDevices.compactMap(\.writeBytesPerSec)
            if !readValues.isEmpty { self.diskReadHistory.push(readValues.reduce(0, +)) }
            if !writeValues.isEmpty { self.diskWriteHistory.push(writeValues.reduce(0, +)) }

            // Power
            if let powerSampler = self.powerSampler {
                let power = powerSampler.sample()
                self.lastPowerReading = power
                next.power = power
                if let watts = power.systemWatts { self.powerHistory.push(watts) }
            }

            // Temperatures
            if self.hasSMC {
                let temperatureBridge: TimeInterval = 12
                next.cpuTemperature = TemperatureSensorSelector.stabilizedTemperature(
                    self.cpuTemperature(),
                    cache: &self.cpuTemperatureCache,
                    now: now,
                    maxAge: temperatureBridge,
                    minimum: TemperatureSensorSelector.minimumChipTemperature)
                next.gpuTemperature = TemperatureSensorSelector.stabilizedTemperature(
                    self.maxTemperature(of: self.gpuKeys),
                    cache: &self.gpuTemperatureCache,
                    now: now,
                    maxAge: temperatureBridge,
                    minimum: TemperatureSensorSelector.minimumChipTemperature)
            }

            // Fan speed
            if self.hasSMC, !self.fanKeys.isEmpty {
                if let speeds = self.readFanSpeeds() {
                    self.lastFanSpeeds = speeds
                    self.missedFanSpeedSamples = 0
                } else if self.missedFanSpeedSamples < 3 {
                    self.missedFanSpeedSamples += 1
                } else {
                    self.lastFanSpeeds = []
                }
            }
            next.fanSpeeds = self.lastFanSpeeds

            next.cpuHistory = self.cpuHistory.values
            next.gpuHistory = self.gpuHistory.values
            next.memoryHistory = self.memoryHistory.values
            next.memoryAppHistory = self.memoryAppHistory.values
            next.netDownHistory = self.netDownHistory.values
            next.netUpHistory = self.netUpHistory.values
            next.diskReadHistory = self.diskReadHistory.values
            next.diskWriteHistory = self.diskWriteHistory.values
            next.systemPowerHistory = self.powerHistory.values

            // 运行应用内存占用前 12（活动应用内存监控，列表超出高度可滚动）。
            // 全量枚举进程是重活（proc_listallpids + 逐进程 proc_pidpath/proc_pidinfo），
            // 且菜单栏下拉未打开时该区块不可见。节流为每 5 个 tick（≈10s@2s 间隔）
            // 采样一次，其余 tick 复用上次结果，降低常驻后台 CPU 占用。
            var apps = lastTopMemoryApps
            if appMemoryTick % 5 == 0 {
                apps = AppMemorySampler.sample(limit: 12)
                lastTopMemoryApps = apps
            }
            appMemoryTick &+= 1

            DispatchQueue.main.async {
                guard self.enabled else {
                    self.refreshInFlight = false
                    return
                }
                self.snapshot = next
                self.topMemoryApps = apps
                self.refreshInFlight = false
                if self.pendingRefresh, self.enabled {
                    self.pendingRefresh = false
                    self.refresh()
                }
            }
        }
    }

    private func readMemory(now: TimeInterval) -> (used: UInt64, appUsed: UInt64, total: UInt64, pressure: MemoryPressure, isFresh: Bool)? {
        let pressure = Self.readMemoryPressure()
        if let memory = SystemInfo.memoryUsage(), memory.total > 0 {
            let stablePressure: MemoryPressure
            switch pressure {
            case .unknown:
                stablePressure = memoryCache?.pressure ?? .unknown
            case .normal, .warning, .critical:
                stablePressure = pressure
            }
            memoryCache = CachedMemoryReading(used: memory.used,
                                              appUsed: memory.appUsed,
                                              total: memory.total,
                                              pressure: stablePressure,
                                              updatedAt: now,
                                              missedSamples: 0)
            return (memory.used, memory.appUsed, memory.total, stablePressure, true)
        }

        guard var cached = memoryCache else { return nil }
        cached.missedSamples += 1
        guard cached.missedSamples <= 4, now - cached.updatedAt <= 12 else {
            memoryCache = nil
            return nil
        }
        memoryCache = cached
        return (cached.used, cached.appUsed, cached.total, cached.pressure, false)
    }

    // MARK: - Sensor preparation

    private func prepareIfNeeded() {
        if !smcTried {
            smcTried = true
            if let client = SMCClient() {
                smc = client
                hasSMC = true
                cpuTemperaturePlatform = TemperatureSensorSelector.currentPlatform()
                powerSampler = PowerSampler(smc: client)
            }
        }
        guard let client = smc else { return }

        if !fanKeysPrepared {
            fanKeysPrepared = true
            let count = Self.fanTelemetryCount
            if count > 0 {
                let keys = (0..<count).compactMap { client.key(named: "F\($0)Ac") }
                if keys.count == count { fanKeys = keys }
            }
        }

        guard !tempKeysPrepared else { return }
        tempKeysPrepared = true

        let all = client.keys { name in
            name.hasPrefix("Tp") || name.hasPrefix("Te") || name.hasPrefix("Tg")
        }
        cpuKeys = all.filter { $0.name.hasPrefix("Tp") || $0.name.hasPrefix("Te") }
        preferredCPUKeys = cpuKeys.filter {
            TemperatureSensorSelector.isCPUCoreKey($0.name, platform: cpuTemperaturePlatform)
        }
        let preferredNames = Set(preferredCPUKeys.map(\.name))
        fallbackCPUKeys = cpuKeys.filter { !preferredNames.contains($0.name) }
        gpuKeys = all.filter { $0.name.hasPrefix("Tg") }
    }

    static let fanTelemetryCount: Int = {
        guard let client = SMCClient(),
              let countKey = client.key(named: "FNum"),
              let countValue = client.readValue(countKey) else { return 0 }
        let count = Int(countValue.rounded())
        guard (1...8).contains(count), abs(countValue - countValue.rounded()) < 0.001 else { return 0 }
        let readings = (0..<count).map { index -> Double? in
            guard let key = client.key(named: "F\(index)Ac") else { return nil }
            return client.readValue(key)
        }
        let values = readings.compactMap { $0 }
        guard values.count == count, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 20_000 }) else { return 0 }
        return count
    }()

    static var fanTelemetryAvailable: Bool { fanTelemetryCount > 0 }

    private func readFanSpeeds() -> [Double]? {
        guard let smc, !fanKeys.isEmpty else { return nil }
        let values = fanKeys.compactMap { smc.readValue($0) }
        guard values.count == fanKeys.count,
              values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 20_000 }) else { return nil }
        return values
    }

    private func cpuTemperature() -> Double? {
        guard smc != nil else { return nil }
        var readings = temperatureReadings(of: preferredCPUKeys)
        if let value = TemperatureSensorSelector.displayedCPUTemperature(readings: readings,
                                                                         platform: cpuTemperaturePlatform) {
            return value
        }
        readings += temperatureReadings(of: fallbackCPUKeys)
        return TemperatureSensorSelector.displayedCPUTemperature(readings: readings,
                                                                 platform: cpuTemperaturePlatform)
    }

    private func temperatureReadings(of keys: [SMCClient.Key]) -> [(key: String, value: Double)] {
        guard let smc else { return [] }
        return keys.compactMap { key -> (key: String, value: Double)? in
            guard let value = smc.readValue(key) else { return nil }
            return (key.name, value)
        }
    }

    private func maxTemperature(of keys: [SMCClient.Key]) -> Double? {
        guard let smc else { return nil }
        let values = keys.compactMap { key -> Double? in
            guard let v = smc.readValue(key), v > 1, v < 125 else { return nil }
            return v
        }
        return values.max()
    }

    // MARK: - CPU usage

    private func readCPUUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle

        defer { previousCPUTicks = (busy, total) }
        guard let previous = previousCPUTicks, total > previous.total else { return nil }
        return Double(busy - previous.busy) / Double(total - previous.total)
    }

    // MARK: - GPU usage

    private static func readGPUUsage() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let ref = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                            kCFAllocatorDefault, 0),
                  let stats = ref.takeRetainedValue() as? [String: Any],
                  let utilization = stats["Device Utilization %"] as? Int
            else { continue }
            return Double(utilization) / 100.0
        }
        return nil
    }

    // MARK: - Memory pressure

    private static func readMemoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unknown
        }
        return MemoryPressure(kernelLevel: level)
    }
}