import Testing
@testable import EasyMacTool

@Suite("Clipboard history limits")
struct ClipboardHistoryPolicyTests {
    @Test func appliesCountLimitToNewestItems() {
        #expect(ClipboardHistoryPolicy.retainedPrefixCount(
            costs: [1, 1, 1, 1], itemLimit: 2, byteLimit: 100
        ) == 2)
    }

    @Test func removesOldestItemsUntilWithinByteBudget() {
        #expect(ClipboardHistoryPolicy.retainedPrefixCount(
            costs: [30, 20, 20], itemLimit: 10, byteLimit: 50
        ) == 2)
    }

    @Test func rejectsNewestItemLargerThanWholeBudget() {
        #expect(ClipboardHistoryPolicy.retainedPrefixCount(
            costs: [70, 10], itemLimit: 10, byteLimit: 50
        ) == 0)
    }

    @Test func computesDecodedImageCostWithoutOverflow() {
        #expect(ImageMemoryBudget.decodedRGBABytes(width: 4000, height: 3000) == 48_000_000)
        #expect(ImageMemoryBudget.decodedRGBABytes(width: 0, height: 100) == nil)
        #expect(ImageMemoryBudget.decodedRGBABytes(width: Int.max, height: 2) == nil)
    }
}
