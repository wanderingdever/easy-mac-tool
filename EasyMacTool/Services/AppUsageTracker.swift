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

    // MARK: - App-level MRU (fallback)

    /// Returns the recency rank of a PID — 0 for the most recently used app.
    /// Used for placeholder/off-screen items that have no windowID in history.
    func rank(of pid: pid_t) -> Int {
        if order.first == pid { return 0 }
        if let idx = order.firstIndex(of: pid) { return idx }
        return Int.max
    }

    var mruOrder: [pid_t] { order }

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
            let tracker = Unmanaged<AppUsageTracker>
                .fromOpaque(refcon!)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                tracker.handleFocusedWindowChange(pid: extractedPid, notification: notif)
            }
        }, &observer)
        guard result == .success, let obs = observer else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(
            obs,
            AXUIElementCreateApplication(pid),
            kAXFocusedWindowChangedNotification as CFString,
            refcon
        )

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
        // Remove all windowIDs belonging to this PID from windowOrder.
        // We can't map windowID→PID directly, so rely on the SCWindow lookup
        // in WindowEnumerator to skip stale entries. Pruning here would
        // require tracking the PID for each windowID, which adds complexity
        // for minimal benefit (stale entries are cleaned on next snapshot).
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
        guard let focusedWindow = focusedWindowRef else { return }

        // AXWindowID attribute returns the CGWindowID as a CFNumber.
        var windowIDRef: CFTypeRef?
        AXUIElementCopyAttributeValue(
            focusedWindow as! AXUIElement,
            "AXWindowID" as CFString,
            &windowIDRef
        )
        guard let windowIDNum = windowIDRef as? NSNumber else { return }
        let windowID = CGWindowID(windowIDNum.intValue)

        // Move to front, deduplicating.
        windowOrder.removeAll { $0 == windowID }
        windowOrder.insert(windowID, at: 0)
        if windowOrder.count > 128 {
            windowOrder.removeLast(windowOrder.count - 128)
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
