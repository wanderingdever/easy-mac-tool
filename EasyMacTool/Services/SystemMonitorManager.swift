import AppKit
import Combine
import Foundation
import IOKit
import IOKit.ps

/// 系统监控单例服务：1 秒轮询采集 7 项指标（CPU/内存/磁盘/网络/温度/风扇/GPU）。
/// 采集失败时对应字段为 nil，UI 静默隐藏该项（机型兼容降级）。
///
/// 启停由 AppCoordinator 监听 AppSettings.$systemMonitor.enabled 控制，
/// 避免监控关闭时仍在后台轮询消耗资源。
@MainActor
final class SystemMonitorManager: ObservableObject {
    static let shared = SystemMonitorManager()

    @Published private(set) var metrics: SystemMetrics = .empty
    @Published private(set) var isRunning: Bool = false

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.easy.easymactool.systemmonitor",
                                      qos: .utility)

    // CPU 占用需要两次采样差值。
    private var lastCpuLoadInfo: host_cpu_load_info?
    private var lastSampleTime: Date?

    // 网速需要两次采样差值。
    private var lastNetworkBytes: (up: UInt64, down: UInt64)?

    private init() {}

    // MARK: - Public

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // 立即采样一次（首次只有内存/磁盘/温度等即时数据，CPU/网速需第二次采样后才有）。
        sample()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.sample() }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
        metrics = .empty
        lastCpuLoadInfo = nil
        lastSampleTime = nil
        lastNetworkBytes = nil
    }

    // MARK: - Sample

    private func sample() {
        var snapshot = SystemMetrics()

        // 内存。
        if let mem = sampleMemory() {
            snapshot.memoryUsage = mem.usage
            snapshot.memoryUsedGB = mem.usedGB
            snapshot.memoryTotalGB = mem.totalGB
        }

        // 磁盘。
        if let disk = sampleDisk() {
            snapshot.diskUsage = disk.usage
            snapshot.diskUsedGB = disk.usedGB
            snapshot.diskTotalGB = disk.totalGB
        }

        // CPU 占用（基于上次采样）。
        if let cpu = sampleCPUUsage() {
            snapshot.cpuUsage = cpu
        }

        // 网速（基于上次采样）。
        if let net = sampleNetwork() {
            snapshot.networkUpload = net.up
            snapshot.networkDownload = net.down
        }

        // SMC：CPU 温度 + 风扇转速（同步调用，IOKit 调用较快 < 5ms）。
        snapshot.cpuTemperature = SMCReader.readCPUTemperature()
        snapshot.fanSpeeds = SMCReader.readFanSpeeds()

        // GPU 占用。
        snapshot.gpuUsage = sampleGPU()

        // 更新采样时间戳。
        lastSampleTime = Date()
        metrics = snapshot
    }

    // MARK: - Memory

    private func sampleMemory() -> (usage: Double, usedGB: Double, totalGB: Double)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = Double(vm_kernel_page_size)

        // 物理内存总量通过 sysctl hw.memsize 获取（最可靠）。
        let totalBytes = physicalMemoryTotal()
        guard totalBytes > 0 else { return nil }
        let totalGB = Double(totalBytes) / 1_073_741_824

        // macOS Activity Monitor "已用" = active + wired + compressed。
        let active = Double(stats.active_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize

        let usedBytes = active + wired + compressed
        let usedGB = usedBytes / 1_073_741_824
        let usage = usedBytes / Double(totalBytes)

        return (usage, usedGB, totalGB)
    }

    /// 通过 sysctl 获取物理内存总量（字节）。
    private func physicalMemoryTotal() -> UInt64 {
        var size: UInt64 = 0
        var sizeOfVar = MemoryLayout<UInt64>.size
        let name = "hw.memsize"
        return name.withCString { cName in
            if sysctlbyname(cName, &size, &sizeOfVar, nil, 0) == 0 {
                return size
            }
            return 0
        }
    }

    // MARK: - Disk

    private func sampleDisk() -> (usage: Double, usedGB: Double, totalGB: Double)? {
        // 启动磁盘根目录。
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        let totalBytes = Int64(total)
        let availableBytes = Int64(available)
        let usedBytes = totalBytes - availableBytes
        guard totalBytes > 0 else { return nil }
        return (
            Double(usedBytes) / Double(totalBytes),
            Double(usedBytes) / 1_073_741_824,
            Double(totalBytes) / 1_073_741_824
        )
    }

    // MARK: - CPU Usage

    /// CPU 占用率：基于 host_statistics(HOST_CPU_LOAD_INFO) 两次采样差值计算。
    /// 首次调用 lastCpuLoadInfo 为 nil，返回 nil（第二次采样才有数据）。
    private func sampleCPUUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        defer { lastCpuLoadInfo = info }

        guard let prev = lastCpuLoadInfo else { return nil }

        // cpu_tick 类型是 unsigned int；用 UInt32 强转避免符号问题。
        let userDelta = UInt32(info.cpu_ticks.0) &- UInt32(prev.cpu_ticks.0)
        let systemDelta = UInt32(info.cpu_ticks.1) &- UInt32(prev.cpu_ticks.1)
        let idleDelta = UInt32(info.cpu_ticks.2) &- UInt32(prev.cpu_ticks.2)
        let niceDelta = UInt32(info.cpu_ticks.3) &- UInt32(prev.cpu_ticks.3)

        let total = Double(userDelta &+ systemDelta &+ idleDelta &+ niceDelta)
        guard total > 0 else { return nil }

        let busy = Double(userDelta &+ systemDelta &+ niceDelta)
        return min(1.0, busy / total)
    }

    // MARK: - Network

    /// 网速（bytes/s）：基于 getifaddrs() 遍历 AF_LINK 接口取收发字节数，
    /// 与上次采样差值除以间隔时间。返回 nil 表示首次采样或读取失败。
    private func sampleNetwork() -> (up: Double, down: Double)? {
        var bytes: (up: UInt64, down: UInt64) = (0, 0)

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return nil
        }
        defer { freeifaddrs(firstAddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let iface = cursor {
            let info = iface.pointee
            // 仅 IPv4/IPv6 流量接口（AF_LINK 是底层链路层，但下行字节数记录在 AF_INET/AF_INET6 上）。
            // 改用 ifa_data 中 ifa_data 的 if_data.ifi_obytes/ifi_ibytes，仅 AF_LINK 上可用。
            if info.ifa_addr?.pointee.sa_family == sa_family_t(AF_LINK), let dataPtr = info.ifa_data {
                // ifa_data 指向 if_data 结构体。我们只关心 ifi_obytes/ifi_ibytes。
                // macOS if_data 布局：前 8 字节是版本信息，9-12 字节 ifi_mtu，
                // 之后是各种计数。ifi_ibytes 在 u32 数组的第 4 个位置（偏移 16），
                // ifi_obytes 在第 6 个位置（偏移 24）。
                let ifData = dataPtr.assumingMemoryBound(to: UInt8.self)
                ifData.withMemoryRebound(to: UInt32.self, capacity: 8) { u32Ptr in
                    let iBytes = UInt64(u32Ptr[4])    // ifi_ibytes
                    let oBytes = UInt64(u32Ptr[6])    // ifi_obytes
                    bytes.down += iBytes
                    bytes.up += oBytes
                }
            }
            cursor = info.ifa_next
        }

        defer { lastNetworkBytes = bytes }

        guard let prev = lastNetworkBytes,
              let lastTime = lastSampleTime else {
            return nil
        }

        let elapsed = Date().timeIntervalSince(lastTime)
        guard elapsed > 0 else { return nil }

        let up = Double(bytes.up &- prev.up) / elapsed
        let down = Double(bytes.down &- prev.down) / elapsed
        return (up, down)
    }

    // MARK: - GPU

    /// GPU 占用率：Metal 公开 API 不暴露 utilization，私有 KVC 在 Swift 协议
    /// 类型上不可调用。返回 nil 让 UI 静默隐藏该项。
    /// 若后续 macOS 提供 MTLDevice.utilization 公开 API，在此实现即可。
    private func sampleGPU() -> Double? {
        return nil
    }
}
