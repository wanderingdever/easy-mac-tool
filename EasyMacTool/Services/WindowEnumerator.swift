import AppKit
import ApplicationServices
import os
import ScreenCaptureKit

/// Snapshots the current set of windows via ScreenCaptureKit + AX, applying a
/// shortcut's filter settings (showMinimized / showHidden).
///
/// 窗口获取策略（按 说明.md 架构）：
/// - visible 窗口：从 SCShareableContent 获取（有 SCWindow，可捕获预览）
/// - minimized 窗口：完全通过 AX 获取（SCShareableContent/CGWindowList 不返回 minimized 窗口）
/// - hidden 窗口：完全通过 AX 获取（SCShareableContent 可能不返回 hidden app 的窗口）
/// - closed/released 窗口：不获取（AX 中已不可达）
///
/// AX 是离屏窗口的唯一数据源。SCShareableContent 仅用于 visible 窗口（需要 SCWindow
/// 来启动 SCStream 捕获预览）。
@MainActor
final class WindowEnumerator {
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowServer",
        "com.apple.controlcenter",
        "com.apple.systemuiserver"
    ]

    private let ownBundleID = Bundle.main.bundleIdentifier ?? ""
    /// static：AX 辅助方法改为 static 后可在 Task.detached 后台线程批量
    /// 调用，无需捕获 @MainActor 隔离的 self（Sendable 安全）。
    private static let logger = Logger(subsystem: "com.easymactool", category: "WindowEnumerator")

    /// AX 获取的窗口信息。windowID 可为 nil（某些 app 不支持 AXWindowID 属性）。
    struct AXWindowInfo: Sendable {
        let windowID: CGWindowID?
        let title: String
        let frame: CGRect
    }

    /// AX 窗口状态：信息 + 是否最小化。
    struct AXWindowState: Sendable {
        let info: AXWindowInfo
        let isMinimized: Bool
    }

    /// 单个 app 的 AX 预取结果（后台线程批量获取，主线程消费）。
    /// states 为空可能表示"无需 AX"（开关未开/权限缺失）或"无离屏窗口"。
    private struct AXAppSnapshot: Sendable {
        let isHidden: Bool
        let states: [AXWindowState]
    }

    func snapshot(filter: ShortcutConfig) async -> [WindowItem] {
        // 1. 检查 AX 权限——如果没有授权，AX 调用全部静默失败，
        //    minimized/hidden 窗口将完全无法检测。
        let axTrusted = AXIsProcessTrusted()
        Self.logger.debug("snapshot: axTrusted=\(axTrusted), showMinimized=\(filter.showMinimized) showHidden=\(filter.showHidden)")
        if !axTrusted {
            Self.logger.error("AX not trusted! minimized/hidden windows will not be detected. Grant Accessibility permission.")
        }

        // 2. SCShareableContent 仅用于获取 visible 窗口（需要 SCWindow 来捕获预览）。
        //    onScreenWindowsOnly 始终为 true——离屏窗口由 AX 获取，不依赖 SCShareableContent。
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            Self.logger.error("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        // Group visible windows by app PID.
        var visibleWindowsByApp: [pid_t: [SCWindow]] = [:]
        for window in content.windows {
            guard let app = window.owningApplication else { continue }
            visibleWindowsByApp[app.processID, default: []].append(window)
        }
        Self.logger.debug("SCShareableContent visible windows: \(content.windows.count)")

        // 构建 windowID → kCGWindowLayer 映射，用于过滤弹出层（layer != 0）。
        // 整个 snapshot 只调用一次 CGWindowList，所有 app 共用。
        // layer == 0 是普通文档窗口，layer > 0 是浮动面板/菜单/下拉框等。
        // 与 macOS 原生 Cmd+Tab / Mission Control 行为一致。
        let layerMap = windowLayerMap()
        Self.logger.debug("windowLayerMap: \(layerMap.count) entries")

        // 对账清理 MRU 中"窗口已关闭但 app 未退出"的 stale 条目，
        // 避免活窗口排序被不再存在的 windowID 顶后。
        AppUsageTracker.shared.pruneStaleWindows()

        // 当前焦点 windowID（window 级）：用于精确标记 active 窗口。
        let focusedWindowID = AppUsageTracker.shared.focusedWindowID

        var items: [WindowItem] = []
        // 已添加的 windowID 集合，用于 AX 补充获取时去重
        var addedWindowIDs: Set<CGWindowID> = []
        let runningApps = NSWorkspace.shared.runningApplications
        // PID 过滤自身：bundleIdentifier 在极端情况下（未签名 / Info.plist 异常）可能为 nil，
        // 此时 ownBundleID 为空字符串，bundleID == ownBundleID 永远 false，自身窗口会被枚举。
        // 用 PID 双重保证自身窗口始终被排除。
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // 候选 app 过滤规则与主循环一致，供 AX 预取与主循环共用。
        func isCandidate(_ app: NSRunningApplication) -> Bool {
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier ?? ""
            if pid == ownPID { return false }
            guard app.activationPolicy == .regular, !bundleID.isEmpty else { return false }
            if Self.excludedBundleIDs.contains(bundleID) || bundleID == ownBundleID { return false }
            return true
        }
        let candidateApps = runningApps.filter(isCandidate)

        // 预取所有候选 app 的 AX 数据（后台线程）。
        // AXUIElementCopyAttributeValue 是同步跨进程 IPC，每个 app 需数次调用。
        // 之前在主线程循环内逐 app 调用，运行 app 较多（或某 app AX 响应慢）
        // 时阻塞主线程，Cmd+Tab 呼出可感知卡顿。现在用 Task.detached 一次性
        // 批量获取（AX API 允许非主线程调用），主线程只做 WindowItem 构建。
        let axSnapshots: [pid_t: AXAppSnapshot]
        if axTrusted {
            let candidatePids = candidateApps.map(\.processIdentifier)
            let showMin = filter.showMinimized
            let showHid = filter.showHidden
            axSnapshots = await Task.detached(priority: .userInitiated) {
                var map: [pid_t: AXAppSnapshot] = [:]
                for pid in candidatePids {
                    let hidden = Self.isAppHidden(pid)
                    var states: [AXWindowState] = []
                    // 与原主循环的 needAX 判断一致：显示最小化 或（显示隐藏且 app 已隐藏）
                    if showMin || (showHid && hidden) {
                        states = Self.axWindowStates(for: pid)
                    }
                    map[pid] = AXAppSnapshot(isHidden: hidden, states: states)
                }
                return map
            }.value
        } else {
            axSnapshots = [:]
        }

        for runningApp in candidateApps {
            let pid = runningApp.processIdentifier

            let visibleWindows = visibleWindowsByApp[pid] ?? []
            let appName = runningApp.localizedName ?? "Unknown"

            // 用 AX 判断 app 隐藏状态（比 NSRunningApplication.isHidden 更准确）。
            // AX 数据已在上面后台批量预取，此处只读结果，不做同步 IPC。
            let axHidden = axSnapshots[pid]?.isHidden ?? false
            Self.logger.debug("app \(appName, privacy: .public) pid=\(pid): visibleSCWindows=\(visibleWindows.count) axHidden=\(axHidden)")

            // Step 1: 处理 SCShareableContent 返回的 visible 窗口
            var hasVisibleItem = false
            // 过滤弹出层 UI（Edge 地址栏下拉、IME 候选框、菜单、tooltip 等）。
            // 多信号检测，任一命中即判为弹出层：
            //
            // 信号 1：kCGWindowLayer != 0 → 弹出层/浮动面板/菜单。
            //   layer == 0：普通文档窗口（主窗口、次级文档窗口、全屏游戏）。
            //   layer  > 0：浮动层（Cmd+Tab 和 Mission Control 也不显示这些）。
            //   这与 macOS 原生 Cmd+Tab 行为一致——不是启发式，是系统语义。
            //   SCWindow.windowID 与 kCGWindowNumber 是同一个 WindowServer ID，
            //   可直接匹配，开销极低。
            //
            // 信号 2：frame 被同 app 更大窗口完全包含 → 弹出层。
            //   Edge/Chrome 地址栏下拉（omnibox popup）是主窗口的子窗口，
            //   kCGWindowLayer 为 0，但 frame 完全落在主窗口内。
            //
            // 信号 3：无标题 且与同 app 更大窗口重叠面积 ≥60% → 弹出层。
            //   覆盖"半包含"场景：窗口较矮时地址栏下拉会从窗口底边探出
            //   （完全包含判定失败）；JetBrains IDE 的补全/文档弹窗也是
            //   layer 0、无标题、与编辑器窗口部分重叠的重量级窗口。
            //   合法文档窗口几乎都有标题，误伤风险低。
            let largeWindows = visibleWindows.filter {
                $0.frame.width >= 400 && $0.frame.height >= 300
            }
            let validVisibleWindows = visibleWindows.filter { window in
                guard window.frame.width >= 80 && window.frame.height >= 80 else { return false }
                // 信号 1：layer != 0 是弹出层
                if let layer = layerMap[window.windowID], layer != 0 {
                    Self.logger.debug("  filtered out by layer=\(layer, privacy: .public): title=\(window.title ?? "nil", privacy: .public)")
                    return false
                }
                let windowArea = window.frame.width * window.frame.height
                // 比 window 更大的同 app 窗口（等大的不算，避免两个主窗口互判）
                let biggerWindows = largeWindows.filter {
                    $0.windowID != window.windowID
                        && $0.frame.width * $0.frame.height > windowArea
                }
                // 信号 2：被更大窗口完全包含
                let isContained = biggerWindows.contains { $0.frame.contains(window.frame) }
                if isContained {
                    Self.logger.debug("  filtered out as contained popup: title=\(window.title ?? "nil", privacy: .public)")
                    return false
                }
                // 信号 3：无标题 + 与更大窗口高重叠（探出边界的下拉/补全弹窗）
                let hasTitle = !(window.title?.isEmpty ?? true)
                if !hasTitle {
                    let isOverlappingPopup = biggerWindows.contains { main in
                        let overlap = main.frame.intersection(window.frame)
                        guard !overlap.isNull else { return false }
                        return (overlap.width * overlap.height) / windowArea >= 0.6
                    }
                    if isOverlappingPopup {
                        Self.logger.debug("  filtered out as untitled overlapping popup for app \(appName, privacy: .public)")
                        return false
                    }
                }
                return true
            }

            for window in validVisibleWindows {
                hasVisibleItem = true
                let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? appName
                let windowAppName = window.owningApplication?.applicationName ?? appName
                let cachedImage = WindowPreviewCache.shared.image(for: window.windowID, pid: pid)
                let isFocusedWindow = (focusedWindowID == window.windowID)
                items.append(WindowItem(
                    id: window.windowID,
                    pid: pid,
                    appName: windowAppName,
                    appIcon: runningApp.icon,
                    title: title,
                    frame: window.frame,
                    scWindow: window,
                    windowState: .visible,
                    isActiveWindow: isFocusedWindow,
                    initialImage: cachedImage
                ))
                addedWindowIDs.insert(window.windowID)
            }

            // Step 2: 通过 AX 获取离屏窗口（minimized / hidden）
            // SCShareableContent 不返回 minimized 窗口，hidden app 的窗口也可能不返回。
            // AX 是离屏窗口的唯一数据源。
            // AX 数据已在上面后台批量预取：未授权（axSnapshots 为空）或无需 AX
            // （开关未开）时 states 为空，循环自然不执行——语义与原
            // guard axTrusted / needAX 一致。
            let axStates = axSnapshots[pid]?.states ?? []
            Self.logger.debug("  axWindowStates: count=\(axStates.count)")

            for state in axStates {
                let info = state.info
                // 用 windowID 去重（如果有的话）
                if let wid = info.windowID, addedWindowIDs.contains(wid) { continue }

                // 判断窗口状态：优先按窗口自身的 isMinimized 分类，
                // 再判断 app 级 hidden。这样隐藏 app 内的最小化窗口仍归为
                // .minimized（受 showMinimized 控制），而非被强制归为
                // .hidden（受 showHidden 控制）——用户开了"显示最小化窗口"
                // 但未开"显示隐藏窗口"时能看到隐藏 app 内的最小化窗口。
                let windowState: WindowState
                if state.isMinimized {
                    windowState = .minimized
                } else if axHidden {
                    windowState = .hidden
                } else {
                    // AX 返回的窗口既不是 minimized 也不是 hidden——可能是 visible
                    // 但 SCShareableContent 没返回（罕见）。跳过避免重复。
                    continue
                }

                // 根据开关过滤
                switch windowState {
                case .minimized:
                    guard filter.showMinimized else { continue }
                case .hidden:
                    guard filter.showHidden else { continue }
                case .visible:
                    continue
                }

                let title = info.title.isEmpty ? appName : info.title
                // 如果有 windowID 用 windowID，否则用 pid + title + frame 哈希生成降级 ID
                let itemID: CGWindowID
                if let wid = info.windowID {
                    itemID = wid
                } else {
                    // 用 pid + title + frame.origin 生成降级 ID，降低冲突概率：
                    // 仅用 pid + title 时，同 app 多个无 title/同名窗口会生成相同 ID，
                    // 被 addedWindowIDs 去重逻辑误判为已添加而漏显示。
                    var hasher = Hasher()
                    hasher.combine(pid)
                    hasher.combine(title)
                    hasher.combine(info.frame.origin.x)
                    hasher.combine(info.frame.origin.y)
                    // 高位标记 0xF0000000：避开系统分配的真实 windowID 区段。
                    // 否则降级 ID 理论上可能与其他窗口的真实 ID 碰撞，导致
                    // WindowActivator 按 AXWindowID 精确匹配到错误窗口
                    //（close 会误关未保存文档）。配合 hasRealWindowID=false，
                    // Activator 对此类 item 跳过精确匹配、直接走 frame 兜底。
                    let hashed = CGWindowID(truncatingIfNeeded: hasher.finalize()) & 0x0FFFFFFF
                    itemID = 0xF0000000 | hashed
                }
                items.append(WindowItem(
                    id: itemID,
                    pid: pid,
                    appName: appName,
                    appIcon: runningApp.icon,
                    title: title,
                    frame: info.frame,
                    scWindow: nil,  // 离屏窗口无 SCWindow
                    windowState: windowState,
                    isActiveWindow: false,
                    initialImage: nil,
                    hasRealWindowID: info.windowID != nil
                ))
                if let wid = info.windowID {
                    addedWindowIDs.insert(wid)
                }
            }
        }

        Self.logger.debug("snapshot total items: \(items.count)")

        // Sort by most-recently-focused (per-window MRU) — mirrors Windows Alt+Tab.
        // Off-screen windows always sort to the END.
        items.sort { lhs, rhs in
            let lhsOff = lhs.isOffScreen
            let rhsOff = rhs.isOffScreen
            if lhsOff && !rhsOff { return false }
            if !lhsOff && rhsOff { return true }
            let lhsRank = AppUsageTracker.shared.rank(ofWindow: lhs.id)
            let rhsRank = AppUsageTracker.shared.rank(ofWindow: rhs.id)
            if lhsRank != rhsRank {
                // 有 MRU 记录的窗口始终排在无记录（Int.max）之前，符合 Windows Alt+Tab 语义。
                // 旧逻辑仅当两者都有记录时才比较 rank，导致有记录的窗口可能因 pidRank 排在无记录窗口之后。
                if lhsRank == Int.max { return false }
                if rhsRank == Int.max { return true }
                return lhsRank < rhsRank
            }
            // 两者 rank 相等且都有记录：按 id 稳定排序
            if lhsRank != Int.max { return lhs.id < rhs.id }
            // 两者都无窗口级记录：fall through 到 pid MRU
            let lhsPidRank = AppUsageTracker.shared.rank(of: lhs.pid)
            let rhsPidRank = AppUsageTracker.shared.rank(of: rhs.pid)
            if lhsPidRank != rhsPidRank { return lhsPidRank < rhsPidRank }
            return lhs.id < rhs.id
        }
        return items
    }

    // MARK: - CGWindowList helpers

    /// 构建 windowID → kCGWindowLayer 映射，用于过滤弹出层。
    /// layer == 0：普通文档窗口（主窗口、次级文档窗口、全屏游戏）。
    /// layer  > 0：浮动面板/菜单/下拉框/IME 候选框/tooltip 等。
    /// macOS 原生 Cmd+Tab 和 Mission Control 也只显示 layer == 0 的窗口。
    private func windowLayerMap() -> [CGWindowID: Int] {
        guard let array = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }
        var map: [CGWindowID: Int] = [:]
        for info in array {
            guard let windowNumber = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int else { continue }
            map[CGWindowID(windowNumber)] = layer
        }
        return map
    }

    // MARK: - AX helpers

    /// 通过 AX 判断 app 是否被隐藏（Cmd+H）。
    /// kAXHiddenAttribute 是 application element 的属性，返回 Bool。
    nonisolated private static func isAppHidden(_ pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var hiddenRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp,
                                                    kAXHiddenAttribute as CFString,
                                                    &hiddenRef)
        guard result == .success else {
            Self.logger.debug("isAppHidden: kAXHiddenAttribute query failed for pid=\(pid), error=\(result.rawValue)")
            return false
        }
        return (hiddenRef as? NSNumber)?.boolValue == true
    }

    /// 通过 AX 获取 app 的所有窗口及其 minimized 状态。
    /// 合并了原来的 minimizedWindows / allAXWindows / minimizedWindowIDs 三个方法。
    nonisolated private static func axWindowStates(for pid: pid_t) -> [AXWindowState] {
        guard let windows = axWindows(for: pid) else { return [] }
        var result: [AXWindowState] = []
        for window in windows {
            guard let info = axWindowInfo(for: window) else { continue }
            var minimizedRef: CFTypeRef?
            let minResult = AXUIElementCopyAttributeValue(window,
                                                           kAXMinimizedAttribute as CFString,
                                                           &minimizedRef)
            let isMinimized = (minResult == .success) && ((minimizedRef as? NSNumber)?.boolValue == true)
            if minResult != .success {
                Self.logger.debug("axWindowStates: kAXMinimizedAttribute query failed, error=\(minResult.rawValue)")
            }
            result.append(AXWindowState(info: info, isMinimized: isMinimized))
        }
        return result
    }

    /// AX kAXWindowsAttribute 返回的窗口列表（[AXUIElement]）。
    nonisolated private static func axWindows(for pid: pid_t) -> [AXUIElement]? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp,
                                                    kAXWindowsAttribute as CFString,
                                                    &windowsRef)
        guard result == .success else {
            Self.logger.debug("axWindows: kAXWindowsAttribute failed for pid=\(pid), error=\(result.rawValue)")
            return nil
        }
        guard let windows = windowsRef as? [AXUIElement] else {
            Self.logger.debug("axWindows: windowsRef is not [AXUIElement] for pid=\(pid)")
            return nil
        }
        return windows
    }

    /// 从 AXUIElement 提取窗口信息（windowID / title / frame）。
    /// windowID 可为 nil（某些 app 不支持 AXWindowID 属性）。
    nonisolated private static func axWindowInfo(for window: AXUIElement) -> AXWindowInfo? {
        // 获取 windowID（可能不被某些 app 支持）
        var idRef: CFTypeRef?
        let idResult = AXUIElementCopyAttributeValue(window, "AXWindowID" as CFString, &idRef)
        let windowID: CGWindowID? = {
            guard idResult == .success, let idNumber = idRef as? NSNumber else {
                Self.logger.debug("axWindowInfo: AXWindowID not supported (error=\(idResult.rawValue)), using hash fallback")
                return nil
            }
            return CGWindowID(idNumber.uint32Value)
        }()

        // 获取标题
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""

        // 获取 frame（position + size）
        // 用 CFGetTypeID 运行时类型检查 + as!：as? 对 CF 类型会被编译器拒绝，
        // 纯 as! 不做运行时类型验证，个别 app 返回非 AXValue 类型会崩溃。
        // CFGetTypeID 预检查后 as! 安全（类型已验证）。
        var position = CGPoint.zero
        var posRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
           let value = posRef,
           CFGetTypeID(value) == AXValueGetTypeID() {
            let axVal = value as! AXValue
            AXValueGetValue(axVal, .cgPoint, &position)
        }
        var size = CGSize.zero
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let value = sizeRef,
           CFGetTypeID(value) == AXValueGetTypeID() {
            let axVal = value as! AXValue
            AXValueGetValue(axVal, .cgSize, &size)
        }

        return AXWindowInfo(
            windowID: windowID,
            title: title,
            frame: CGRect(origin: position, size: size)
        )
    }

}
