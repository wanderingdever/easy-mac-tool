import AppKit
import ScreenCaptureKit

/// Snapshots the current set of windows via ScreenCaptureKit, applying a
/// shortcut's filter settings (showMinimized / showHidden / showEmptyApps).
/// All on-screen windows are surfaced (not just the main window per app),
/// so an app with multiple windows appears multiple times — one entry per
/// window. Windows are sorted by most-recently-focused (per-window MRU).
@MainActor
final class WindowEnumerator {
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowServer",
        "com.apple.controlcenter",
        "com.apple.systemuiserver"
    ]

    private let ownBundleID = Bundle.main.bundleIdentifier ?? ""

    func snapshot(filter: ShortcutConfig) async -> [WindowItem] {
        let includeOffScreen = filter.showHidden || filter.showMinimized || filter.showEmptyApps
        let content: SCShareableContent
        do {
            // 始终排除桌面窗口（Finder 桌面层）。之前用 !includeOffScreen
            // 会在用户开启「显示最小化/隐藏/空应用」任一开关后把桌面窗口
            // 纳入候选，导致 Finder 文件夹窗口最小化后桌面窗口
            // （isOnScreen=true）被 pickMainWindow 选为 mainWindow 并捕获，
            // 显示桌面壁纸而非 Finder 图标。桌面窗口永远不应该作为可
            // 切换的"窗口"出现。
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: !includeOffScreen
            )
        } catch {
            return []
        }

        // Group windows by app PID.
        var windowsByApp: [pid_t: [SCWindow]] = [:]
        for window in content.windows {
            guard let app = window.owningApplication else { continue }
            windowsByApp[app.processID, default: []].append(window)
        }

        // The frontmost app is the most-recently-used. Determine its PID so we
        // can sort items by recency.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var items: [WindowItem] = []
        let runningApps = NSWorkspace.shared.runningApplications
        for runningApp in runningApps {
            let pid = runningApp.processIdentifier
            let bundleID = runningApp.bundleIdentifier ?? ""

            guard runningApp.activationPolicy == .regular else { continue }
            guard !bundleID.isEmpty else { continue }
            if Self.excludedBundleIDs.contains(bundleID) { continue }
            if bundleID == ownBundleID { continue }

            let appWindows = windowsByApp[pid] ?? []
            let appName = runningApp.localizedName ?? "Unknown"
            let isActive = (pid == frontmostPID)

            // 分离 on-screen 和 off-screen 窗口。
            // on-screen 窗口每个创建一个 WindowItem（多窗口显示）。
            // off-screen 窗口（最小化/隐藏）不显示——只显示一个 icon-only
            // item 代表整个 app，避免切换器被大量相同 app 图标填满。
            let onScreenWindows = appWindows.filter {
                $0.isOnScreen && $0.frame.width >= 80 && $0.frame.height >= 80
            }

            if onScreenWindows.isEmpty {
                // 无 on-screen 窗口：显示 icon-only item（如果 filter 允许）
                if appWindows.isEmpty && filter.showEmptyApps {
                    items.append(makePlaceholderItem(for: runningApp))
                } else if !appWindows.isEmpty && (filter.showMinimized || filter.showHidden) {
                    items.append(makeIconItem(runningApp: runningApp,
                                              pid: pid,
                                              appName: appName,
                                              isActive: isActive))
                }
                continue
            }

            // 每个 on-screen 窗口创建一个 WindowItem（多窗口支持）
            for window in onScreenWindows {
                let title = (window.title?.isEmpty == false ? window.title! : appName)
                let windowAppName = window.owningApplication?.applicationName ?? appName
                let cachedImage = WindowPreviewCache.shared.image(for: window.windowID)
                items.append(WindowItem(
                    id: window.windowID,
                    pid: pid,
                    appName: windowAppName,
                    appIcon: runningApp.icon,
                    title: title,
                    frame: window.frame,
                    scWindow: window,
                    isPlaceholder: false,
                    isOffScreen: false,
                    isActiveWindow: isActive,  // 焦点判定在排序阶段细化
                    initialImage: cachedImage
                ))
            }
        }

        // Sort by most-recently-focused (per-window MRU) — mirrors Windows Alt+Tab.
        // `AppUsageTracker.windowOrder` records the real window focus order
        // (most recently focused windowID at index 0). Off-screen/placeholder
        // apps still sort to the END so they don't pollute the recency order.
        //
        // Fallback：若两个 windowID 都不在 windowOrder 中（rank 返回 Int.max），
        // 退化到 PID 的 MRU 排序——避免所有未追踪窗口按 windowID 排序导致
        // 看似"错乱"。例如刚启动后 windowOrder 几乎为空，需要靠 PID rank
        // 让最近激活的应用排前面。
        items.sort { lhs, rhs in
            // Off-screen/placeholder windows always go last.
            let lhsOff = lhs.isOffScreen || lhs.isPlaceholder
            let rhsOff = rhs.isOffScreen || rhs.isPlaceholder
            if lhsOff && !rhsOff { return false }
            if !lhsOff && rhsOff { return true }
            // 优先用 per-window MRU rank。
            let lhsRank = AppUsageTracker.shared.rank(ofWindow: lhs.id)
            let rhsRank = AppUsageTracker.shared.rank(ofWindow: rhs.id)
            if lhsRank != rhsRank {
                // 若两个 rank 都不是 Int.max，按 rank 排序。
                // 若都是 Int.max，下面会 fallback 到 PID rank。
                if lhsRank != Int.max && rhsRank != Int.max {
                    return lhsRank < rhsRank
                }
            } else {
                // rank 相等且都不是 Int.max，稳定排序保留 windowID 比较。
                if lhsRank != Int.max { return lhs.id < rhs.id }
            }
            // Fallback：用 PID 的 MRU rank（最近激活的应用排前）。
            let lhsPidRank = AppUsageTracker.shared.rank(of: lhs.pid)
            let rhsPidRank = AppUsageTracker.shared.rank(of: rhs.pid)
            if lhsPidRank != rhsPidRank { return lhsPidRank < rhsPidRank }
            // PID rank 也相等：稳定排序避免反复 reshuffle。
            return lhs.id < rhs.id
        }
        return items
    }

    // MARK: - Helpers

    private func makePlaceholderItem(for runningApp: NSRunningApplication) -> WindowItem {
        let appName = runningApp.localizedName ?? "Unknown"
        return WindowItem(
            id: CGWindowID(runningApp.processIdentifier),
            pid: runningApp.processIdentifier,
            appName: appName,
            appIcon: runningApp.icon,
            title: appName,
            frame: .zero,
            scWindow: nil,
            isPlaceholder: true,
            isOffScreen: true,
            isActiveWindow: false
        )
    }

    /// Builds an icon-only item for a minimized/hidden app. Uses the app's
    /// PID as a synthetic window ID and does NOT attach an SCWindow — the
    /// capture manager can't capture it, so the cell shows the app icon.
    private func makeIconItem(runningApp: NSRunningApplication, pid: pid_t,
                              appName: String, isActive: Bool) -> WindowItem {
        return WindowItem(
            id: CGWindowID(pid),
            pid: pid,
            appName: appName,
            appIcon: runningApp.icon,
            title: appName,
            frame: .zero,
            scWindow: nil,
            isPlaceholder: true,
            isOffScreen: true,
            isActiveWindow: false
        )
    }
}
