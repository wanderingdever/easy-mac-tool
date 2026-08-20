import CoreGraphics
import Foundation

/// Minimal, pure ordering key for the switcher's MRU sort. Kept independent of
/// AppKit so the ordering rule can be unit-tested without a live window set.
nonisolated struct WindowSortKey: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let isOffScreen: Bool
    let windowRank: Int
    let appRank: Int
    let title: String
    let appName: String
}

nonisolated enum WindowOrderResolver {
    /// Returns source indices in display order. Mirrors the current policy:
    /// on-screen windows first, then per-window MRU, then app-level MRU as a
    /// fallback for windows with no window-level history.
    static func sortedIndices(
        _ keys: [WindowSortKey],
        order: SwitcherWindowOrder = .recentlyFocused
    ) -> [Int] {
        if order == .alphabetical {
            return keys.indices.sorted { lhs, rhs in
                let a = keys[lhs]
                let b = keys[rhs]
                if a.appName != b.appName { return a.appName < b.appName }
                if a.title != b.title { return a.title < b.title }
                return a.id < b.id
            }
        }
        return keys.indices.sorted { lhs, rhs in
            let a = keys[lhs]
            let b = keys[rhs]
            if a.isOffScreen != b.isOffScreen {
                return !a.isOffScreen
            }
            if a.windowRank != b.windowRank {
                if a.windowRank == Int.max { return false }
                if b.windowRank == Int.max { return true }
                return a.windowRank < b.windowRank
            }
            if a.windowRank != Int.max {
                return a.id < b.id
            }
            if a.appRank != b.appRank {
                return a.appRank < b.appRank
            }
            return a.id < b.id
        }
    }
}
