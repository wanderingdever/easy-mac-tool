import Foundation

nonisolated enum ClipboardHistoryPolicy {
    /// Items are newest-first. Return the prefix that remains after removing
    /// oldest entries until both the count and byte limits are satisfied.
    static func retainedPrefixCount(costs: [Int], itemLimit: Int, byteLimit: Int) -> Int {
        guard itemLimit > 0, byteLimit > 0 else { return 0 }
        var count = min(costs.count, itemLimit)
        var total = costs.prefix(count).reduce(0, +)
        while count > 0, total > byteLimit {
            count -= 1
            total -= costs[count]
        }
        return count
    }
}
