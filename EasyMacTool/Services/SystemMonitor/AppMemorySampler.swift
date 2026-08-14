import AppKit
import Darwin

/// 运行中应用的内存用量快照（主进程 PID + 聚合内存），用于菜单栏下拉的「活动应用内存」区块。
struct ActiveAppMemoryInfo: Identifiable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage?
    let memoryBytes: UInt64

    var id: pid_t { pid }
}

/// 枚举运行中的用户应用，聚合其全部进程（含 Helper）的物理内存，排除系统服务，
/// 返回占用最高的前 N 个。参考 Vorssaint 的进程表聚合方式。
enum AppMemorySampler {
    /// 单个进程的内存采样。
    private struct ProcessSample {
        let pid: pid_t
        let path: String       // 可执行路径，可能为空串
        let memoryBytes: UInt64
    }

    /// 逐进程物理内存（RSS，字节）。`proc_pidinfo` 读取基本进程信息无需特殊权限。
    private static func residentBytes(for pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
        guard ret == size else { return nil }
        return info.pti_resident_size
    }

    /// `PROC_PIDPATHINFO_MAXSIZE`（4 * MAXPATHLEN）在 Swift 中不可用作宏，手动定义同值。
    private static let pathBufferSize = 4096

    /// 枚举系统中的全部进程及其内存。
    private static func allProcesses() -> [ProcessSample] {
        let bytes = proc_listallpids(nil, 0)
        guard bytes > 0 else { return [] }
        let capacity = Int(bytes) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        let validCount = min(pids.count, Int(written) / MemoryLayout<pid_t>.size)
        var result: [ProcessSample] = []
        for pid in pids.prefix(validCount) {
            var pathBuf = [CChar](repeating: 0, count: pathBufferSize)
            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = len > 0 ? String(cString: pathBuf) : ""
            result.append(ProcessSample(pid: pid, path: path, memoryBytes: residentBytes(for: pid) ?? 0))
        }
        return result
    }

    /// 系统进程路径判定：无路径（内核/launchd 等）或位于系统目录视为系统服务。
    private static func isSystemServicePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return true }
        let excluded = [
            "/System/",
            "/usr/",
            "/Library/Apple/",
            // "/Applications/Utilities/", // 预留：仅当需要排除系统自带工具时启用
        ]
        return excluded.contains { path.hasPrefix($0) }
    }

    /// 系统 bundleID 黑名单（聚焦、Dock、控制中心、菜单栏服务、输入法、WindowServer 等）。
    private static func isSystemBundleID(_ id: String?) -> Bool {
        guard let id else { return false }
        if id.hasPrefix("com.apple.inputmethod.") { return true } // 输入法
        let system: Set<String> = [
            "com.apple.Spotlight", "com.apple.dock", "com.apple.controlcenter",
            "com.apple.systemuiserver", "com.apple.WindowManager", "com.apple.loginwindow",
            "com.apple.notificationcenterui", "com.apple.coreauthui",
        ]
        return system.contains(id)
    }

    /// 返回内存占用最高的 `limit` 个运行用户应用（聚合其全部进程）。
    static func sample(limit: Int = 5) -> [ActiveAppMemoryInfo] {
        let own = Bundle.main.bundleIdentifier

        // 1) 候选用户应用：非 prohibited、非自身、非系统 bundleID、路径非系统服务。
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy != .prohibited else { return false }
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return false }
            guard bundleID != own, !isSystemBundleID(bundleID) else { return false }
            guard let url = app.bundleURL else { return false }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            return !isSystemServicePath(path)
        }

        // 2) 计算每个应用的 bundle 根路径前缀。
        let attributed: [(app: NSRunningApplication, prefix: String)] = apps.compactMap { app in
            guard let url = app.bundleURL else { return nil }
            return (app, url.resolvingSymlinksInPath().standardizedFileURL.path + "/")
        }

        // 3) 先计入各应用主进程 RSS（兜底，即使路径匹配失败也保证有数据），
        //    再按路径前缀把子进程内存归并到对应应用（主进程已在兜底计入，跳过避免重复）。
        let mainPIDs = Set(attributed.map { $0.app.processIdentifier })
        var totals: [pid_t: UInt64] = [:]
        for item in attributed {
            totals[item.app.processIdentifier, default: 0] += Self.residentBytes(for: item.app.processIdentifier) ?? 0
        }
        for proc in allProcesses() where !proc.path.isEmpty {
            guard !mainPIDs.contains(proc.pid) else { continue }
            guard let owner = attributed.first(where: { proc.path.hasPrefix($0.prefix) }) else { continue }
            totals[owner.app.processIdentifier, default: 0] += proc.memoryBytes
        }

        // 4) 组装、按内存降序、取前 limit。
        return attributed.compactMap { item -> ActiveAppMemoryInfo? in
            guard let mem = totals[item.app.processIdentifier], mem > 0 else { return nil }
            return ActiveAppMemoryInfo(pid: item.app.processIdentifier,
                                       name: item.app.localizedName ?? item.app.bundleIdentifier ?? "?",
                                       bundleID: item.app.bundleIdentifier,
                                       icon: item.app.icon,
                                       memoryBytes: mem)
        }
        .sorted { $0.memoryBytes > $1.memoryBytes }
        .prefix(limit)
        .map { $0 }
    }
}