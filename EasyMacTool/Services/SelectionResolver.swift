import Foundation

/// Pure selection-index policy for the switcher grid.
nonisolated enum SelectionResolver {
    /// Returns the next/previous index. `direction` positive moves forward,
    /// negative moves backward; `wraps` controls whether the edge wraps.
    static func nextIndex(
        current: Int,
        count: Int,
        direction: Int,
        wraps: Bool = true
    ) -> Int? {
        guard count > 0 else { return nil }
        let clamped = max(0, min(current, count - 1))
        let candidate = clamped + (direction >= 0 ? 1 : -1)
        if candidate >= 0 && candidate < count {
            return candidate
        }
        guard wraps else { return nil }
        return direction >= 0 ? 0 : count - 1
    }

    /// Returns the index to keep after one item is removed from the list.
    static func indexAfterRemoval(
        current: Int,
        removedIndex: Int,
        countAfterRemoval: Int
    ) -> Int? {
        guard countAfterRemoval > 0, removedIndex >= 0 else { return nil }
        let adjusted = removedIndex < current ? current - 1 : current
        return max(0, min(adjusted, countAfterRemoval - 1))
    }
}
