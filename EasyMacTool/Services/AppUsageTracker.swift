import AppKit
import ApplicationServices

/// Tracks the most-recently-focused (MRF) order of windows by listening to
/// `kAXFocusedWindowChangedNotification` via AXObserver for each running app.
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

    /// windowIDs ordered by most recent focus (index 0 = current focus).
    private var windowOrder: [CGWindowID] = []
    /// 反查表：windowID → owner PID。用于 app 退出时批量清理 windowOrder 中的
    /// stale 条目，避免污染 MRU 排序。之前不维护此映射，依赖 WindowEnumerator
    /// 软清理，但 stale 条目会占据 0-127 的位次让活窗口排序靠后。
    private var windowOwners: [CGWindowID: pid_t] = [:]
    /// PIDs ordered by most recent activation (fallback for icon-only items).
    private var order: [pid_t] = []
    private let ownBundleID = Bundle.main.bundleIdentifier ?? ""

    /// AX observers keyed by PID so we can clean up when apps exit.
    private var observers: [pid_t: AXObserver] = [:]
    /// Run loop sources for AX observers (must retain to keep observer alive).
    private var runLoopSources: [pid_t: CFRunLoopSource] = [:]

    private init() {
        // Seed with the current frontmost app + its focused window.
        if let front = NSWorkspace.shared.frontmostApplication {
            order = [front.processIdentifier]
            seedFocusedWindow(for: front.processIdentifier)
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

    /// 对账清理 windowOrder 中"窗口已关闭但 app 未退出"的 stale 条目。
    /// appDidTerminate 只在 app 退出时清理；窗口单独关闭（Cmd+W）后其
    /// windowID 会一直占据 MRU 位次（直到 128 上限淘汰），让活窗口排序靠后。
    /// 由 WindowEnumerator.snapshot 在每次呼出切换器时调用（每次仅一次
    /// CGWindowList 查询，开销可忽略）。
    /// 注意：kCGWindowListOptionAll 包含离屏（最小化/隐藏）窗口，
    /// 不会误清理它们的 MRU 记录。
    func pruneStaleWindows() {
        guard let array = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }
        let alive = Set(array.compactMap { info -> CGWindowID? in
            (info[kCGWindowNumber as String] as? Int).map { CGWindowID($0) }
        })
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

    /// Installs an AXObserver for `kAXFocusedWindowChangedNotification` on the
    /// given app. When the app's focused window changes, we record the new
    /// window's CGWindowID in `windowOrder`.
    private func installAXObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular else { return }
        if app.bundleIdentifier == ownBundleID { return }
        guard observers[pid] == nil else { return }  // already installed

        var observer: AXObserver?
        let result = AXObserverCreate(pid, { _, element, notif, refcon in
            // AXObserver callback is NOT on the main thread by default.
            // Dispatch to main to safely mutate @MainActor state.
            // NOTE: C function pointers cannot capture context, so we extract
            // the PID from the `element` arg via AXUIElementGetPid instead of
            // capturing `pid` from the enclosing scope.
            var extractedPid: pid_t = 0
            AXUIElementGetPid(element, &extractedPid)
            guard let refcon else { return }
            let tracker = Unmanaged<AppUsageTracker>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                tracker.handleFocusedWindowChange(pid: extractedPid, notification: notif)
            }
        }, &observer)
        guard result == .success, let obs = observer else { return }

        // passUnretained 安全：AppUsageTracker 是 static let shared 单例，
        // 生命周期与进程相同，AXObserver 回调期间 self 一定存活。
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addResult = AXObserverAddNotification(
            obs,
            AXUIElementCreateApplication(pid),
            kAXFocusedWindowChangedNotification as CFString,
            refcon
        )
        // 检查返回值：add 失败时 observer 永远收不到通知，若仍登记字典，
        // 该 app 的窗口 MRU 静默失效且 removeAXObserver 清理了无效资源。
        guard addResult == .success else {
            NSLog("[AppUsageTracker] AXObserverAddNotification failed for pid=\(pid), error=\(addResult.rawValue)")
            return
        }

        // AXObserverGetRunLoopSource is the official API for obtaining the
        // run loop source from an AXObserver. AXObserver is NOT toll-free-
        // bridged to CFMachPort in Swift, so a forced cast crashes at runtime.
        let src = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        observers[pid] = obs
        runLoopSources[pid] = src
    }

    private func removeAXObserver(for pid: pid_t) {
        if let src = runLoopSources[pid] {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSources.removeValue(forKey: pid)
        }
        observers.removeValue(forKey: pid)
        // 通过 windowOwners 反查表批量清理该 PID 的所有 windowID。
        // 之前不清理导致 stale 条目累积至上限 128，污染 MRU 排序。
        let staleWindowIDs = windowOwners.filter { $0.value == pid }.keys
        for windowID in staleWindowIDs {
            windowOrder.removeAll { $0 == windowID }
            windowOwners.removeValue(forKey: windowID)
        }
    }

    /// Called on the main thread when an app's focused window changes.
    /// Extracts the CGWindowID from the AX notification and updates windowOrder.
    private func handleFocusedWindowChange(pid: pid_t, notification: CFString) {
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
        guard let value = focusedWindowRef,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let axWindow = value as! AXUIElement
        var windowIDRef: CFTypeRef?
        AXUIElementCopyAttributeValue(
            axWindow,
            "AXWindowID" as CFString,
            &windowIDRef
        )
        guard let windowIDNum = windowIDRef as? NSNumber else { return }
        // 与 WindowActivator/WindowExtractor 保持一致：用 uint32Value 而非 intValue。
        // CGWindowID 是 UInt32，intValue 对超过 Int32.max 的值会溢出为负数，
        // 导致 MRU 排序匹配失效。
        let windowID = CGWindowID(windowIDNum.uint32Value)

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

    /// Seeds the current focused window for a PID at startup.
    private func seedFocusedWindow(for pid: pid_t) {
        handleFocusedWindowChange(pid: pid,
                                  notification: kAXFocusedWindowChangedNotification as CFString)
    }

    // MARK: - NSWorkspace notifications

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if app.bundleIdentifier == ownBundleID { return }
        // App-level order
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
        if order.count > 64 { order.removeLast(order.count - 64) }
        // Install observer if not yet installed (app was running before us)
        installAXObserver(for: app)
        // Seed the focused window for this app
        seedFocusedWindow(for: pid)
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
