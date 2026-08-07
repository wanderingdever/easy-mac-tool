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
        // 系统 UI 守护进程
        "com.apple.dock",
        "com.apple.WindowServer",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        // 系统服务 agent(.accessory,路径在 /System/ 下)。路径过滤(isCandidate
        // 中的 /System/ + .accessory 判定)已覆盖,此处显式列出作为双重保险
        // + 文档化,避免路径判断因边缘情况失效时漏网。
        // 这些 agent 在 showHidden=true 时会通过 AX 枚举出隐藏窗口,污染切换器列表。
        "com.apple.UserNotificationCenter",
        "com.apple.Spotlight",
        "com.apple.universalaccess",
        "com.apple.loginwindow",
    ]

    /// AX 预取的最大 app 数量（按 MRU 排序取前 N）。
    /// 运行 80+ app 时对全部候选发起 isAppHidden + axWindowStates 是数百次跨进程
    /// IPC，是 Cmd+Tab 呼出延迟的主要来源。MRU 排名靠后的 app（>30）用户极少
    /// 通过切换器切到，其离屏窗口（minimized/hidden）不预取——用户开启
    /// showMin/showHid 是为看到最近用过的 app 的离屏窗口，而非全部历史 app。
    /// 这些 app 的 visible 窗口仍由 SCShareableContent 正常枚举，仅离屏窗口缺失。
    private static let maxAXPrefetchCount = 30

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

        // 一次 CGWindowList 查询同时构建 layerMap（windowID→层级，过滤弹出层与
        // 系统 UI）与 onscreenWindowIDs（C2 分类兜底用）。合并原来两次
        // .optionOnScreenOnly + .optionAll 调用，减少跨进程 IPC。
        // 保留层级 [0, 8]（normal/floating/modalPanel——含设置类面板），
        // 排除 ≥19 的 utility/dock/menubar/status/popup 层。
        let (layerMap, onscreenWindowIDs) = windowLayerAndOnscreenMaps()
        Self.logger.debug("windowLayerMap: \(layerMap.count) entries, onscreen: \(onscreenWindowIDs.count)")

        // 当前焦点 windowID（window 级）：用于精确标记 active 窗口。
        let focusedWindowID = AppUsageTracker.shared.focusedWindowID

        var items: [WindowItem] = []
        // 已添加的 windowID 集合，用于 AX 补充获取时去重
        var addedWindowIDs: Set<CGWindowID> = []
        let runningApps = NSWorkspace.shared.runningApplications
        // 候选 app 过滤规则与主循环一致，供 AX 预取与主循环共用。
        func isCandidate(_ app: NSRunningApplication) -> Bool {
            let bundleID = app.bundleIdentifier ?? ""
            // 不再排除本应用自身窗口：本应用的「设置」窗口是普通 level-0
            // 窗口，用户希望能切换到它；而剪贴板/切换器/菜单栏等 OverlayPanel
            // 的窗口层级为 .statusBar(25)，会在后面的 layer 过滤（仅保留
            // [0,8]）中被排除，不会混入列表。
            //
            // activationPolicy：.regular（普通 app）与 .accessory（菜单栏 agent
            // app，如各类菜单栏工具——含本应用）都纳入，Mission Control 同样显示
            // accessory app 的窗口（典型场景：菜单栏 app 的设置窗）。
            // 只排除 .prohibited（纯后台守护进程，无 UI）。
            // accessory app 的 status item / 下拉浮层窗口层级很高（≥24），
            // 会在后面的 layer 过滤中被排除，不会混入列表。
            guard app.activationPolicy != .prohibited, !bundleID.isEmpty else { return false }
            if Self.excludedBundleIDs.contains(bundleID) { return false }
            // 系统服务进程过滤:位于 /System/ 路径下且 activationPolicy == .accessory
            // 的进程是系统 agent(UserNotificationCenter/Spotlight/universalAccessAuthW 等)。
            // 它们的窗口是系统 UI,不应出现在切换器中——showHidden=true 时尤其会通过
            // AX 枚举出隐藏窗口污染列表。
            // .regular 的系统 app(Finder/System Settings/Activity Monitor)保留——
            // 它们是用户可交互的 GUI app。第三方菜单栏 app(.accessory 但不在 /System/ 下,
            // 含本应用)也保留。
            if app.activationPolicy == .accessory,
               let url = app.bundleURL ?? app.executableURL,
               url.path.hasPrefix("/System/") {
                return false
            }
            return true
        }
        let candidateApps = runningApps.filter(isCandidate)

        // 预取候选 app 的 AX 数据（后台线程）。
        // AXUIElementCopyAttributeValue 是同步跨进程 IPC，每个 app 需数次调用。
        // 之前在主线程循环内逐 app 调用，运行 app 较多（或某 app AX 响应慢）
        // 时阻塞主线程，Cmd+Tab 呼出可感知卡顿。现在用 Task.detached 一次性
        // 批量获取（AX API 允许非主线程调用），主线程只做 WindowItem 构建。
        let showMin = filter.showMinimized
        let showHid = filter.showHidden
        // AX 预取仅在需要离屏窗口时执行：默认 showMin=false && showHid=false 时
        // 完全跳过，避免对全部候选 app 发起 isAppHidden/axWindowStates 的跨进程
        // IPC（80+ app 时数百次调用，是 Cmd+Tab 呼出延迟的主要来源）。
        // 开关开启时仅预取 MRU 前 N 个 app（见 maxAXPrefetchCount）——
        // 用户极少通过切换器切到 30 名开外的 app，其离屏窗口不预取可显著
        // 减少跨进程 IPC（80+ app 时从数百次降至 ~60 次）。这些 app 的
        // visible 窗口仍由 SCShareableContent 正常枚举，仅离屏窗口缺失。
        let axSnapshots: [pid_t: AXAppSnapshot]
        if axTrusted && (showMin || showHid) {
            // 用 AppUsageTracker 的 app 级 rank 排序候选 pid，取前 maxAXPrefetchCount。
            // rank(of:) 返回 Int.max 表示无 MRU 记录（从未激活过的 app），排在末尾。
            let tracker = AppUsageTracker.shared
            let sortedPids = candidateApps
                .map(\.processIdentifier)
                .sorted { tracker.rank(of: $0) < tracker.rank(of: $1) }
            let prefetchPids = Array(sortedPids.prefix(Self.maxAXPrefetchCount))
            axSnapshots = await Task.detached(priority: .userInitiated) {
                var map: [pid_t: AXAppSnapshot] = [:]
                for pid in prefetchPids {
                    // showHid=false 时无需 isAppHidden：主循环中 hidden 相关分支
                    //（C2 兜底、C1 占位、.hidden 状态）均被 filter.showHidden 守卫，
                    // axHidden=false 不影响结果。
                    let hidden = showHid ? Self.isAppHidden(pid) : false
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

        // 对账清理 MRU 中"窗口已关闭但 app 未退出"的 stale 条目。
        // 移到 AX 预取之后：可以从 axStates 中提取离屏窗口（minimized/hidden）
        // 的 windowID 作为 protectedIDs 传给 pruneStaleWindows，避免隐藏 app 的
        // unmapped 窗口（不在 CGWindowList 中）被误清理 → MRU 排序失效。
        let offScreenWindowIDs: Set<CGWindowID> = {
            var ids = Set<CGWindowID>()
            for snapshot in axSnapshots.values {
                for state in snapshot.states {
                    if let wid = state.info.windowID {
                        ids.insert(wid)
                    }
                }
            }
            return ids
        }()
        AppUsageTracker.shared.pruneStaleWindows(protectedIDs: offScreenWindowIDs)

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
            // 信号 1：kCGWindowLayer 超出 [0, 8] → 弹出层/系统 UI。
            //   macOS 窗口层级语义（CGWindowLevel.h）：
            //   layer 0  kCGNormalWindowLevel      普通文档窗口
            //   layer 3  kCGFloatingWindowLevel    浮动面板——大量设置窗/
            //            工具面板在这一层（NSPanel floatingPanel），
            //            Mission Control 会显示，必须纳入。
            //   layer 8  kCGModalPanelWindowLevel  模态面板——另一类设置窗/
            //            对话框（如部分 app 的偏好设置），Mission Control
            //            同样显示，必须纳入。
            //   layer 19+ utility/dock/menubar/status/popup：Dock(20)、
            //            菜单栏(24)、状态栏(25)、弹出菜单(101)、tooltip、
            //            IME 候选框等——Cmd+Tab/Mission Control 均不显示，排除。
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
                // 信号 1：层级超出 [0, 8]（normal/floating/modalPanel）是弹出层
                // 或系统 UI。layerMap 缺省（CGWindowList 未返回）时不按层级过滤。
                if let layer = layerMap[window.windowID], layer < 0 || layer > 8 {
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
                } else if filter.showHidden,
                          let wid = info.windowID,
                          !addedWindowIDs.contains(wid),
                          !onscreenWindowIDs.contains(wid) {
                    // C2 兜底：isAppHidden 误判（kAXHiddenAttribute 失败）时，
                    // 窗口既非 minimized 也非 hidden。若该窗口有真实 windowID、
                    // SC 未返回（不在 addedWindowIDs）且不在屏幕上
                    // （CGWindowList 无此 ID 或 onscreen == false）→ 确为离屏窗口，
                    // 归为 .hidden 而非直接跳过，保证隐藏 app 的窗口仍可显示。
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
                hasVisibleItem = true
            }

            // C1: 隐藏 app 但 AX 枚举不到任何窗口（kAXWindowsAttribute 失败/空，
            // 部分 app 隐藏时从 AX 树移除窗口）时，生成 app 级占位条目（显示
            // 应用图标），保证用户仍能看到该 app 并切换过去（unhide + activate）。
            // 仅当 showHidden 开启、app 确为 hidden、且该 app 无任何条目时兜底，
            // 避免与正常条目重复。
            if filter.showHidden, axHidden, !hasVisibleItem {
                var hasher = Hasher()
                hasher.combine(pid)
                let placeholderID = 0xF0000000
                    | (CGWindowID(truncatingIfNeeded: hasher.finalize()) & 0x0FFFFFFF)
                Self.logger.debug("  app-level placeholder for hidden app \(appName, privacy: .public) (no AX windows)")
                items.append(WindowItem(
                    id: placeholderID,
                    pid: pid,
                    appName: appName,
                    appIcon: runningApp.icon,
                    title: appName,
                    frame: .zero,
                    scWindow: nil,
                    windowState: .hidden,
                    isActiveWindow: false,
                    initialImage: nil,
                    hasRealWindowID: false
                ))
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

    /// 一次 CGWindowList 查询同时构建 layerMap（windowID→层级）与 onscreenIDs
    /// （屏幕上可见的 windowID 集合）。合并原来两次 .optionOnScreenOnly +
    /// .optionAll 调用，减少跨进程 IPC。
    /// 调用方保留 layer [0, 8]：0 = 普通文档窗口，3 = 浮动面板（设置/工具面板），
    /// 8 = 模态面板（设置/对话框）——与 Mission Control 可见范围一致；
    /// ≥19 为 utility/dock/menubar/status/popup 层，被过滤。
    private func windowLayerAndOnscreenMaps() -> (layerMap: [CGWindowID: Int], onscreenIDs: Set<CGWindowID>) {
        guard let array = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return ([:], [])
        }
        var layerMap: [CGWindowID: Int] = [:]
        var onscreenIDs: Set<CGWindowID> = []
        for info in array {
            guard let windowNumber = info[kCGWindowNumber as String] as? Int else { continue }
            let id = CGWindowID(windowNumber)
            if let layer = info[kCGWindowLayer as String] as? Int {
                layerMap[id] = layer
            }
            if (info[kCGWindowIsOnscreen as String] as? Bool) == true {
                onscreenIDs.insert(id)
            }
        }
        return (layerMap, onscreenIDs)
    }

    // MARK: - AX helpers

    /// 通过 AX 判断 app 是否被隐藏（Cmd+H）。
    /// kAXHiddenAttribute 是 application element 的属性，返回 Bool。
    /// AX 查询失败时回退到 NSRunningApplication.isHidden（系统级 API，
    /// 直接反映 Cmd+H 状态，不依赖 AX），避免误判导致隐藏窗口不可见。
    nonisolated private static func isAppHidden(_ pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var hiddenRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp,
                                                    kAXHiddenAttribute as CFString,
                                                    &hiddenRef)
        guard result == .success, let hiddenRef else {
            Self.logger.debug("isAppHidden: kAXHiddenAttribute query failed for pid=\(pid), error=\(result.rawValue), fallback to NSRunningApplication")
            return NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
        }
        return (hiddenRef as? NSNumber)?.boolValue ?? false
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
