import AppKit
import ApplicationServices
import os

/// Pure policy for reconciling Accessibility and WindowServer focus reads.
/// WindowServer may briefly report a popup; when AX can prove that the ID is
/// not one of the app's top-level windows, retain the AX result instead.
nonisolated enum WindowFocusResolver {
    static func resolved(axID: CGWindowID?,
                         windowServerID: CGWindowID?,
                         knownAXIDs: Set<CGWindowID>?) -> CGWindowID? {
        guard let axID, let windowServerID, axID != windowServerID else {
            return axID ?? windowServerID
        }
        if let knownAXIDs, !knownAXIDs.contains(windowServerID) {
            return axID
        }
        return windowServerID
    }
}

/// Tracks the most-recently-focused (MRF) order of windows by listening to
/// Accessibility focus/main-window notifications via AXObserver for each
/// running app.
/// The most recently focused windowID is always at index 0.
///
/// This mirrors the Windows Alt+Tab behavior at the per-window level: after
/// focusing window A then B, the order is [B, A]; after B→D it becomes [D, B, A].
/// `WindowEnumerator` consumes `rank(ofWindow:)` to sort the switcher list.
///
/// Also retains app-level activation tracking (`rank(of:)` by PID) as a
/// fallback for placeholder/off-screen items that have no windowID.
@MainActor
final class AppUsageTracker {
    static let shared = AppUsageTracker()
    private static let logger = Logger(subsystem: "com.easymactool", category: "AppUsageTracker")

    /// windowIDs ordered by most recent focus (index 0 = current focus).
    private var windowOrder: [CGWindowID] = []
    /// 反查表：windowID → owner PID。用于 app 退出时批量清理 windowOrder 中的
    /// stale 条目，避免污染 MRU 排序。之前不维护此映射，依赖 WindowEnumerator
    /// 软清理，但 stale 条目会占据 0-127 的位次让活窗口排序靠后。
    private var windowOwners: [CGWindowID: pid_t] = [:]
    /// PIDs ordered by most recent activation (fallback for icon-only items).
    private var order: [pid_t] = []
    /// Monotonically increasing activation token. AX reads run off the main
    /// actor and may finish out of order; completions from an older activation
    /// must not move a previously selected window back to the front.
    private var activationGeneration = 0
    /// Same-PID window changes (for example Chrome Profile A → B) do not emit
    /// an NSWorkspace app activation notification, so they need their own token.
    private var windowFocusGeneration = 0
    private let ownBundleID = Bundle.main.bundleIdentifier ?? ""

    /// AX observers keyed by PID so we can clean up when apps exit.
    private var observers: [pid_t: AXObserver] = [:]
    /// Run loop sources for AX observers (must retain to keep observer alive).
    private var runLoopSources: [pid_t: CFRunLoopSource] = [:]
    /// PID → bundleID 映射，用于检测 PID 复用：force-kill 后 macOS 可能将
    /// 该 PID 分配给新 app，此时旧 observer 仍在字典中会阻止新 app 安装。
    /// 比较 bundleID 可识别 PID 复用并清理旧 observer。
    private var observerBundleIDs: [pid_t: String] = [:]
    /// 定期清理定时器：force-kill / 崩溃的 app 不触发 didTerminateNotification，
    /// 导致 observer + runLoopSource 永久泄漏。每 30s 扫描 runningApplications
    /// 清理已不存在的 PID。
    private var reaperTimer: Timer?
    private var pendingFocusReads: [pid_t: Task<Void, Never>] = [:]

    private init() {
        // Seed with the current frontmost app + its focused window.
        if let front = NSWorkspace.shared.frontmostApplication {
            order = [front.processIdentifier]
            seedFocusedWindowAsync(pid: front.processIdentifier,
                                    generation: activationGeneration)
        }
        // Subscribe to app activations (for app-level fallback ordering).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // Subscribe to app launch/exit to install/remove AX observers.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        // Install AX observers for already-running apps.
        for app in NSWorkspace.shared.runningApplications {
            installAXObserver(for: app)
        }
        // 定期清理 force-kill 残留：30s 间隔足够及时清理且 CPU 开销极小
        // （仅一次 NSWorkspace.runningApplications IPC + 字典 diff）。
        // 用 .common 模式避免 NSMenu 模态期间停滞。
        let t = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reapStaleObservers()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        reaperTimer = t
    }

    /// 清理已退出但 observer 仍残留的 PID。force-kill (SIGKILL)、
    /// Activity Monitor 强制退出、内核 EXC_BAD_ACCESS 崩溃等场景
    /// 不触发 NSWorkspace.didTerminateApplicationNotification，
    /// 导致 observer + runLoopSource 永久泄漏。更严重的是 macOS 会
    /// 复用 PID：新 app 安装时 guard observers[pid] == nil 跳过，
    /// 新 app 永远无 MRU 跟踪。此方法扫描 runningApplications
    /// 清理字典中已不存在的 PID，让下次 installAXObserver 能成功安装。
    private func reapStaleObservers() {
        let alivePIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let stalePIDs = observers.keys.filter { !alivePIDs.contains($0) }
        guard !stalePIDs.isEmpty else { return }
        for pid in stalePIDs {
            removeAXObserver(for: pid)
        }
        // 同步清理 order 数组中的 stale PID（AppUsageTracker.removeAXObserver
        // 只清 windowOrder，不清 order）。
        order.removeAll { !alivePIDs.contains($0) }
    }

    // MARK: - Window-level MRU

    /// Returns the recency rank of a windowID — 0 for the most recently focused
    /// window, larger numbers for older windows. Windows not in the history get
    /// `Int.max` so they sort after all tracked windows (e.g. newly opened).
    func rank(ofWindow windowID: CGWindowID) -> Int {
        if windowOrder.first == windowID { return 0 }
        if let idx = windowOrder.firstIndex(of: windowID) { return idx }
        return Int.max
    }

    /// 当前焦点 windowID（windowOrder.first）。用于 WindowEnumerator 标记
    /// 实际焦点窗口，而非 app 级判断（之前用 pid == frontmostPID 导致
    /// frontmost app 的所有窗口都被标记 active，UI 上多个窗口显示 active 边框）。
    var focusedWindowID: CGWindowID? { windowOrder.first }

    /// 切换提交时显式记录一次窗口切换，把目标提到最前、把 `previous` 提到次近。
    /// 系统聚焦通知在激活之后才触发，快速来回切换（flick）时会滞后一拍；
    /// 此调用在提交瞬间就位，保证立即再按可切回上一个窗口。
    func recordSwitch(to windowID: CGWindowID, pid: pid_t, from previous: CGWindowID?) {
        windowOrder.removeAll { $0 == windowID }
        windowOrder.insert(windowID, at: 0)
        windowOwners[windowID] = pid
        if let previous, previous != windowID {
            windowOrder.removeAll { $0 == previous }
            windowOrder.insert(previous, at: min(1, windowOrder.count))
        }
        if windowOrder.count > 128 {
            let overflow = windowOrder.count - 128
            let stale = Array(windowOrder.suffix(overflow))
            windowOrder.removeLast(overflow)
            for windowID in stale {
                windowOwners.removeValue(forKey: windowID)
            }
        }
    }

    /// 对账清理 windowOrder 中"窗口已关闭但 app 未退出"的 stale 条目。
    /// appDidTerminate 只在 app 退出时清理；窗口单独关闭（Cmd+W）后其
    /// windowID 会一直占据 MRU 位次（直到 128 上限淘汰），让活窗口排序靠后。
    /// 由 WindowEnumerator.snapshot 在每次呼出切换器时调用（每次仅一次
    /// CGWindowList 查询，开销可忽略）。
    ///
    /// - Parameter protectedIDs: 已知的离屏窗口 ID（minimized/hidden），
    ///   即使不在 CGWindowList 中也保留其 MRU 记录。隐藏 app unmapped 的窗口
    ///   不会被 .optionAll 返回，不保护会被误清理 → MRU 排序失效。
    func pruneStaleWindows(protectedIDs: Set<CGWindowID> = []) {
        guard let array = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }
        let alive = Set(array.compactMap { info -> CGWindowID? in
            (info[kCGWindowNumber as String] as? Int).map { CGWindowID($0) }
        }).union(protectedIDs)
        let stale = windowOrder.filter { !alive.contains($0) }
        guard !stale.isEmpty else { return }
        for windowID in stale {
            windowOrder.removeAll { $0 == windowID }
            windowOwners.removeValue(forKey: windowID)
        }
    }

    // MARK: - App-level MRU (fallback)

    /// Returns the recency rank of a PID — 0 for the most recently used app.
    /// Used for placeholder/off-screen items that have no windowID in history.
    func rank(of pid: pid_t) -> Int {
        if order.first == pid { return 0 }
        if let idx = order.firstIndex(of: pid) { return idx }
        return Int.max
    }

    // MARK: - AX Observer management

    /// Installs an AXObserver for focused and main-window changes. Chrome can
    /// change its main window without delivering a reliable focus notification.
    private func installAXObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular else { return }
        if app.bundleIdentifier == ownBundleID { return }

        // PID 复用检测：force-kill 后 macOS 可能将该 PID 分配给新 app。
        // 若 observers[pid] 已存在但 bundleID 不同，说明是旧 app 残留，
        // 必须先 removeAXObserver 清理旧 observer 才能安装新的。
        // 否则 guard observers[pid] == nil 跳过安装，新 app 永远无 MRU 跟踪。
        if let existingBundleID = observerBundleIDs[pid],
           existingBundleID != app.bundleIdentifier {
            removeAXObserver(for: pid)
        }
        guard observers[pid] == nil else { return }  // already installed for this app

        var observer: AXObserver?
        let result = AXObserverCreate(pid, { _, element, notif, refcon in
            // AXObserver callback is NOT on the main thread by default.
            // Dispatch to main to safely mutate @MainActor state.
            // NOTE: C function pointers cannot capture context, so we extract
            // the PID from the `element` arg via AXUIElementGetPid instead of
            // capturing `pid` from the enclosing scope.
            var extractedPid: pid_t = 0
            AXUIElementGetPid(element, &extractedPid)
            guard extractedPid != 0 else { return }
            guard let refcon else { return }
            let tracker = Unmanaged<AppUsageTracker>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            Task { @MainActor in
                tracker.handleFocusedWindowChange(pid: extractedPid, notification: notif)
            }
        }, &observer)
        guard result == .success, let obs = observer else { return }

        // passUnretained 安全：AppUsageTracker 是 static let shared 单例，
        // 生命周期与进程相同，AXObserver 回调期间 self 一定存活。
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let axApp = AXUIElementCreateApplication(pid)
        let notifications: [CFString] = [
            kAXFocusedWindowChangedNotification as CFString,
            kAXMainWindowChangedNotification as CFString,
        ]
        var registered = false
        for notification in notifications {
            let addResult = AXObserverAddNotification(obs, axApp, notification, refcon)
            if addResult == .success || addResult == .notificationAlreadyRegistered {
                registered = true
            } else {
                Self.logger.debug("[AppUsageTracker] AX notification unavailable for pid=\(pid, privacy: .public), error=\(addResult.rawValue, privacy: .public)")
            }
        }
        // 检查返回值：两个通知都失败时，observer 没有任何用途。
        guard registered else {
            return
        }

        // AXObserverGetRunLoopSource is the official API for obtaining the
        // run loop source from an AXObserver. AXObserver is NOT toll-free-
        // bridged to CFMachPort in Swift, so a forced cast crashes at runtime.
        let src = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        observers[pid] = obs
        runLoopSources[pid] = src
        observerBundleIDs[pid] = app.bundleIdentifier
    }

    private func removeAXObserver(for pid: pid_t) {
        pendingFocusReads[pid]?.cancel()
        pendingFocusReads.removeValue(forKey: pid)
        if let src = runLoopSources[pid] {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSources.removeValue(forKey: pid)
        }
        observers.removeValue(forKey: pid)
        observerBundleIDs.removeValue(forKey: pid)
        // 通过 windowOwners 反查表批量清理该 PID 的所有 windowID。
        // 之前不清理导致 stale 条目累积至上限 128，污染 MRU 排序。
        let staleWindowIDs = windowOwners.filter { $0.value == pid }.keys
        for windowID in staleWindowIDs {
            windowOrder.removeAll { $0 == windowID }
            windowOwners.removeValue(forKey: windowID)
        }
    }

    /// Called on the main thread when an app's focused/main window changes.
    private func handleFocusedWindowChange(pid: pid_t, notification: CFString) {
        // AX notifications can arrive after the app has already lost focus.
        // Ignore those stale callbacks; the activation seed for the new app
        // will establish the correct frontmost window.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        windowFocusGeneration &+= 1
        let generation = windowFocusGeneration
        pendingFocusReads[pid]?.cancel()
        pendingFocusReads[pid] = Task { @MainActor [weak self] in
            // Chrome emits notifications in a burst while switching profiles.
            // Read after the burst so MRU records the final window.
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled, let self else { return }
            let windowID = await Task.detached(priority: .userInitiated) {
                Self.readFocusedWindowID(pid: pid)
            }.value
            guard !Task.isCancelled,
                  self.windowFocusGeneration == generation,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let windowID else { return }
            self.recordFocusedWindow(windowID, pid: pid)
            self.pendingFocusReads.removeValue(forKey: pid)
        }
    }

    /// 主线程更新 MRU：AX 回调路径与后台读取结果共用。
    private func recordFocusedWindow(_ windowID: CGWindowID, pid: pid_t) {
        // Move to front, deduplicating.
        windowOrder.removeAll { $0 == windowID }
        windowOrder.insert(windowID, at: 0)
        // 同步维护反查表，供 removeAXObserver 批量清理。
        windowOwners[windowID] = pid
        if windowOrder.count > 128 {
            // removeLast(_:) 返回单个元素而非数组，需手动截取后删除。
            let overflow = windowOrder.count - 128
            let stale = Array(windowOrder.suffix(overflow))
            windowOrder.removeLast(overflow)
            for windowID in stale {
                windowOwners.removeValue(forKey: windowID)
            }
        }
    }

    /// 非主线程安全：读取指定 PID 的当前聚焦窗口 ID（同步 AX 跨进程 IPC）。
    /// 返回 nil 表示查询失败（无聚焦窗口 / AX 不支持 AXWindowID）。
    nonisolated private static func readFocusedWindowID(pid: pid_t) -> CGWindowID? {
        var axID: CGWindowID?
        let axApp = AXUIElementCreateApplication(pid)
        var focusedWindowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef
        )
        // AXWindowID attribute returns the CGWindowID as a CFNumber.
        // 用 CFGetTypeID 运行时类型检查 + as!：as? 对 CF 类型会被编译器拒绝
        // （"conditional downcast to CF type will always succeed"），
        // 纯 as! 不做运行时类型验证，个别 app 返回非 AXUIElement 类型会崩溃。
        // CFGetTypeID 预检查后 as! 安全（类型已验证）。
        if let value = focusedWindowRef,
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            let axWindow = value as! AXUIElement
            var windowIDRef: CFTypeRef?
            AXUIElementCopyAttributeValue(
                axWindow,
                "AXWindowID" as CFString,
                &windowIDRef
            )
            if let windowIDNum = windowIDRef as? NSNumber {
                // 与 WindowActivator/WindowExtractor 保持一致：用 uint32Value 而非 intValue。
                // CGWindowID 是 UInt32，intValue 对超过 Int32.max 的值会溢出为负数，
                // 导致 MRU 排序匹配失效。
                axID = CGWindowID(windowIDNum.uint32Value)
            }
        }

        // A few applications expose a focused AX window but omit AXWindowID.
        // WindowServer still reports the frontmost on-screen window for the
        // process, which is a reliable fallback for MRU ordering (activation
        // itself remains handled by WindowActivator's AX path).
        let windowServerID = frontmostWindowID(pid: pid)
        let knownAXIDs = axWindowIDs(pid: pid)
        return WindowFocusResolver.resolved(axID: axID,
                                            windowServerID: windowServerID,
                                            knownAXIDs: knownAXIDs)
    }

    /// Returns top-level AX window IDs. This is only queried when AX and
    /// WindowServer disagree, to reject transient Chrome popups.
    nonisolated private static func axWindowIDs(pid: pid_t) -> Set<CGWindowID>? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp,
                                            kAXWindowsAttribute as CFString,
                                            &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        var ids = Set<CGWindowID>()
        for window in windows {
            var idRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window,
                                                "AXWindowID" as CFString,
                                                &idRef) == .success,
                  let number = idRef as? NSNumber else { continue }
            ids.insert(CGWindowID(number.uint32Value))
        }
        return ids
    }

    /// Returns the topmost normal/modal on-screen window owned by `pid`.
    /// CGWindowList is ordered front-to-back, so the first matching entry is
    /// the window the user most recently clicked.
    nonisolated private static func frontmostWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  pid_t(ownerPID) == pid,
                  let windowNumber = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  (0...8).contains(layer),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 0, height > 0 else { continue }
            return CGWindowID(windowNumber)
        }
        return nil
    }

    /// 后台读取指定 PID 的当前聚焦窗口并更新 MRU。
    /// AX 属性读取是同步跨进程 IPC，主线程调用会阻塞；app 激活频繁时
    /// 改为后台执行，仅把结果派回主线程更新 MRU。
    ///
    /// A short retry window handles the activation->focused-window ordering on
    /// macOS: didActivateApplication can be delivered before AX exposes the
    /// newly focused window. The generation and frontmost-PID checks prevent a
    /// delayed read from a previous app activation overwriting the latest one.
    private func seedFocusedWindowAsync(pid: pid_t, generation: Int) {
        // 用 [weak self] 捕获实例而非 AppUsageTracker.shared：本方法在 init() 中调用，
        // 此时 static let shared 尚未初始化完成，访问它会触发 EXC_BREAKPOINT。
        let focusGeneration = windowFocusGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            for attempt in 0..<3 {
                guard !Task.isCancelled else { return }
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 50_000_000)
                }
                let windowID = Self.readFocusedWindowID(pid: pid)
                let accepted = await MainActor.run { [weak self] in
                    guard let self,
                          self.activationGeneration == generation,
                          self.windowFocusGeneration == focusGeneration,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                          let windowID else { return false }
                    self.recordFocusedWindow(windowID, pid: pid)
                    return true
                }
                if accepted { return }
            }
        }
    }

    /// Refreshes the currently frontmost app's focused window before a
    /// switcher snapshot is sorted. This is a final consistency check for
    /// mouse activation paths where Workspace/AX notifications can be delayed
    /// or coalesced by the system.
    func refreshFrontmostWindow() async {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != ownBundleID else { return }
        let pid = app.processIdentifier
        installAXObserver(for: app)
        recordAppActivation(pid)
        let generation = activationGeneration
        windowFocusGeneration &+= 1
        let focusGeneration = windowFocusGeneration
        pendingFocusReads[pid]?.cancel()
        let windowID = await Task.detached(priority: .userInitiated) {
            Self.readFocusedWindowID(pid: pid)
        }.value
        guard activationGeneration == generation,
              windowFocusGeneration == focusGeneration,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let windowID else { return }
        recordFocusedWindow(windowID, pid: pid)
    }

    // MARK: - NSWorkspace notifications

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if app.bundleIdentifier == ownBundleID { return }
        activationGeneration &+= 1
        windowFocusGeneration &+= 1
        let generation = activationGeneration
        recordAppActivation(pid)
        // Install observer if not yet installed (app was running before us)
        installAXObserver(for: app)
        // Seed the focused window for this app（AX 读取在后台执行，避免阻塞主线程）
        seedFocusedWindowAsync(pid: pid, generation: generation)
    }

    /// Moves an app to the front of the PID-level MRU list. This is used both
    /// by Workspace notifications and by the snapshot-time frontmost refresh,
    /// covering activation paths where the notification is delayed or missed.
    private func recordAppActivation(_ pid: pid_t) {
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
        if order.count > 64 { order.removeLast(order.count - 64) }
    }

    @objc private func appDidLaunch(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        installAXObserver(for: app)
    }

    @objc private func appDidTerminate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        removeAXObserver(for: pid)
        order.removeAll { $0 == pid }
    }
}
