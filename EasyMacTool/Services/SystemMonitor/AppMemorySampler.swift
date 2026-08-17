import AppKit
import Darwin

/// Matches a process executable path to the nearest enclosing app bundle in
/// O(path depth), instead of scanning every running app for every process.
nonisolated struct ProcessPathOwnerIndex {
    private let ownersByPrefix: [String: pid_t]

    init(_ entries: [(prefix: String, pid: pid_t)]) {
        ownersByPrefix = Dictionary(entries.map { ($0.prefix, $0.pid) },
                                    uniquingKeysWith: { first, _ in first })
    }

    func ownerPID(for executablePath: String) -> pid_t? {
        guard executablePath.first == "/" else { return nil }
        var end = executablePath.endIndex
        while end > executablePath.startIndex {
            guard let slash = executablePath[..<end].lastIndex(of: "/") else { return nil }
            let prefixEnd = executablePath.index(after: slash)
            if let owner = ownersByPrefix[String(executablePath[..<prefixEnd])] {
                return owner
            }
            end = slash
        }
        return nil
    }
}

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
nonisolated enum AppMemorySampler {
    struct Candidate: Sendable {
        let pid: pid_t
        let name: String
        let bundleID: String
        let executablePrefix: String
        let isRegular: Bool
        let isFrontmost: Bool
    }

    struct Sample: Sendable {
        let pid: pid_t
        let name: String
        let bundleID: String?
        let memoryBytes: UInt64
    }

    /// 单个进程的内存采样。
    private struct ProcessSample {
        let pid: pid_t
        let path: String       // 可执行路径，可能为空串
        let memoryBytes: UInt64
    }

    /// 逐进程物理占用（phys_footprint，字节）。相比 RSS，footprint 会扣除
    /// 大部分可回收/共享页，更接近活动监视器的“内存”口径，聚合 Helper 时
    /// 也不容易重复放大共享映射。
    private static func footprintBytes(for pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        return withUnsafeMutablePointer(to: &info) { pointer in
            var raw: rusage_info_t? = UnsafeMutableRawPointer(pointer)
            guard proc_pid_rusage(pid, RUSAGE_INFO_V2, &raw) == 0 else { return nil }
            return pointer.pointee.ri_phys_footprint
        }
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
        result.reserveCapacity(validCount)
        var pathBuffer = [CChar](repeating: 0, count: pathBufferSize)
        for pid in pids.prefix(validCount) {
            let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = len > 0
                ? String(decoding: pathBuffer.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                : ""
            result.append(ProcessSample(pid: pid, path: path, memoryBytes: footprintBytes(for: pid) ?? 0))
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

    /// 拥有可见 UI 的 PID 集合：普通/浮动/模态窗口（layer 0...8）或菜单栏
    /// 状态项（layer 25）。用于把「有界面」的应用与「纯后台无 UI」的代理区分开：
    /// 后台 agent 即使 activationPolicy 非 prohibited，只要没有窗口/状态项就被剔除。
    private static func uiPresencePIDs() -> Set<pid_t> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var pids = Set<pid_t>()
        for info in list {
            guard let layerNum = info[kCGWindowLayer as String] as? NSNumber else { continue }
            let layer = layerNum.intValue
            let isWindow = (0...8).contains(layer)
            let isStatusItem = layer == 25
            guard isWindow || isStatusItem else { continue }
            guard let pidNum = info[kCGWindowOwnerPID as String] as? NSNumber,
                  pidNum.intValue > 0 else { continue }
            pids.insert(pid_t(pidNum.intValue))
        }
        return pids
    }

    /// 家族归并：同一产品体系的多个 bundle 合并为一行。返回家族名，nil 表示独立应用。
    /// 基于本机实际运行的微信体系 bundleID（lsappinfo list）校准：
    ///   - com.tencent.xinWeChat        → 微信本体
    ///   - com.tencent.flue.WeChatAppEx / WeApp / helper.renderer → 小程序容器/渲染进程
    private static func familyName(bundleID: String?, name: String?) -> String? {
        let id = (bundleID ?? "").lowercased()
        let n = (name ?? "").lowercased()
        // 微信体系：微信本体 + 小程序容器/渲染（com.tencent.flue.*）
        if id.hasPrefix("com.tencent.xinwechat") || id.hasPrefix("com.tencent.flue.") { return "微信" }
        // 企业微信体系
        if id.hasPrefix("com.tencent.wework") || id.hasPrefix("com.tencent.wecom") { return "企业微信" }
        // 名称兜底（某些无 bundleID 或 bundleID 变化的版本）
        if n.contains("企业微信") || n.contains("wecom") || n.contains("wework") { return "企业微信" }
        if n.contains("wechat") || n.contains("weixin") || n.contains("微信") { return "微信" }
        return nil
    }

    /// 返回运行中「用户可见应用」的内存快照（聚合其全部进程，含 Helper）。
    /// - 候选集：普通应用（Dock）、前台应用、或拥有普通窗口/菜单栏状态项的应用；
    ///   纯后台无 UI 的代理被剔除（对齐用户对 macOS「强制退出」列表的认知）。
    /// - 家族归并：同一产品体系（如微信 + 小程序）合并为一行，内存求和。
    /// - 排序：按聚合内存降序；`limit` 为 nil 时返回全部（列表可滚动）。
    @MainActor
    static func captureCandidates() -> [Candidate] {
        let own = Bundle.main.bundleIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy != .prohibited else { return nil }
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
            guard bundleID != own, !isSystemBundleID(bundleID) else { return nil }
            guard let url = app.bundleURL else { return nil }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard !isSystemServicePath(path) else { return nil }
            return Candidate(pid: app.processIdentifier,
                             name: app.localizedName ?? bundleID,
                             bundleID: bundleID,
                             executablePrefix: path + "/",
                             isRegular: app.activationPolicy == .regular,
                             isFrontmost: app.processIdentifier == frontmostPID)
        }
    }

    static func sample(candidates: [Candidate], limit: Int? = nil) -> [Sample] {
        let presencePIDs = Self.uiPresencePIDs()
        let attributed = candidates.filter {
            $0.isRegular || $0.isFrontmost || presencePIDs.contains($0.pid)
        }

        // 3) 先计入各应用主进程 RSS（兜底，即使路径匹配失败也保证有数据），
        //    再按路径前缀把子进程内存归并到对应应用（主进程已在兜底计入，跳过避免重复）。
        let mainPIDs = Set(attributed.map(\.pid))
        let ownerIndex = ProcessPathOwnerIndex(
            attributed.map { (prefix: $0.executablePrefix, pid: $0.pid) }
        )
        var totals: [pid_t: UInt64] = [:]
        for item in attributed {
            totals[item.pid, default: 0] += Self.footprintBytes(for: item.pid) ?? 0
        }
        for proc in allProcesses() where !proc.path.isEmpty {
            guard !mainPIDs.contains(proc.pid) else { continue }
            guard let ownerPID = ownerIndex.ownerPID(for: proc.path) else { continue }
            totals[ownerPID, default: 0] += proc.memoryBytes
        }

        // 4) 家族归并：同一 family 的多个应用合并为一行（内存求和、取内存最大者作代表）。
        var grouped: [String: (total: UInt64, rep: Sample)] = [:]
        for item in attributed {
            guard let mem = totals[item.pid], mem > 0 else { continue }
            let info = Sample(pid: item.pid, name: item.name,
                              bundleID: item.bundleID, memoryBytes: mem)
            let key = Self.familyName(bundleID: item.bundleID, name: item.name) ?? info.name
            if let existing = grouped[key] {
                grouped[key] = (existing.total + mem,
                                existing.rep.memoryBytes >= mem ? existing.rep : info)
            } else {
                grouped[key] = (mem, info)
            }
        }

        // 5) 组装、按内存降序、可选截断。
        let merged = grouped.map { key, entry in
            Sample(pid: entry.rep.pid, name: key,
                   bundleID: entry.rep.bundleID, memoryBytes: entry.total)
        }
        let sorted = merged.sorted { $0.memoryBytes > $1.memoryBytes }
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }

    @MainActor
    static func displayInfo(from samples: [Sample]) -> [ActiveAppMemoryInfo] {
        let appsByPID = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return samples.map { sample in
            ActiveAppMemoryInfo(pid: sample.pid,
                                name: sample.name,
                                bundleID: sample.bundleID,
                                icon: appsByPID[sample.pid]?.icon,
                                memoryBytes: sample.memoryBytes)
        }
    }
}
