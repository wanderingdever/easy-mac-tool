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
    static func sample(limit: Int? = nil) -> [ActiveAppMemoryInfo] {
        let own = Bundle.main.bundleIdentifier
        let presencePIDs = Self.uiPresencePIDs()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // 1) 候选应用：非 prohibited、非自身、非系统 bundleID、路径非系统服务，
        //    且「用户可见」——普通应用/前台/拥有窗口或菜单栏状态项。
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy != .prohibited else { return false }
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return false }
            guard bundleID != own, !isSystemBundleID(bundleID) else { return false }
            guard let url = app.bundleURL else { return false }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard !isSystemServicePath(path) else { return false }
            if app.activationPolicy == .regular { return true }
            if app.processIdentifier == frontmostPID { return true }
            return presencePIDs.contains(app.processIdentifier)
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

        // 4) 家族归并：同一 family 的多个应用合并为一行（内存求和、取内存最大者作代表）。
        var grouped: [String: (total: UInt64, rep: ActiveAppMemoryInfo)] = [:]
        for item in attributed {
            guard let mem = totals[item.app.processIdentifier], mem > 0 else { continue }
            let info = ActiveAppMemoryInfo(pid: item.app.processIdentifier,
                                           name: item.app.localizedName ?? item.app.bundleIdentifier ?? "?",
                                           bundleID: item.app.bundleIdentifier,
                                           icon: item.app.icon,
                                           memoryBytes: mem)
            let key = Self.familyName(bundleID: item.app.bundleIdentifier,
                                      name: item.app.localizedName) ?? info.name
            if let existing = grouped[key] {
                grouped[key] = (existing.total + mem,
                                existing.rep.memoryBytes >= mem ? existing.rep : info)
            } else {
                grouped[key] = (mem, info)
            }
        }

        // 5) 组装、按内存降序、可选截断。
        let merged = grouped.map { key, entry in
            ActiveAppMemoryInfo(pid: entry.rep.pid,
                                name: key,
                                bundleID: entry.rep.bundleID,
                                icon: entry.rep.icon,
                                memoryBytes: entry.total)
        }
        let sorted = merged.sorted { $0.memoryBytes > $1.memoryBytes }
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }
}