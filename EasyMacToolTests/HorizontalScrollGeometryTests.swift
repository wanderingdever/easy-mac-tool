import CoreGraphics
import Testing
@testable import EasyMacTool

@Suite("Clipboard horizontal scroll geometry")
struct HorizontalScrollGeometryTests {
    @Test func preservesPreciseDeltasAndScalesWheelLines() {
        #expect(HorizontalScrollGeometry.redirectedDelta(verticalDelta: 2.5, isPrecise: true) == -2.5)
        #expect(HorizontalScrollGeometry.redirectedDelta(verticalDelta: 2, isPrecise: false) == -80)
    }

    private let width: CGFloat = 230
    private let spacing: CGFloat = 12
    private let padding: CGFloat = 16

    @Test func keepsVisibleCardStable() {
        let result = HorizontalScrollGeometry.targetOrigin(
            index: 0, currentOrigin: 0, viewportWidth: 500, documentWidth: 1000,
            cardWidth: width, spacing: spacing, horizontalPadding: padding
        )
        #expect(result == 0)
    }

    @Test func minimallyRevealsCardOnRight() {
        let result = HorizontalScrollGeometry.targetOrigin(
            index: 2, currentOrigin: 0, viewportWidth: 500, documentWidth: 1000,
            cardWidth: width, spacing: spacing, horizontalPadding: padding
        )
        #expect(result == 246)
    }

    @Test func clampsAtDocumentBoundaryAndRejectsUnlaidOutTarget() {
        let clamped = HorizontalScrollGeometry.targetOrigin(
            index: 3, currentOrigin: 0, viewportWidth: 500, documentWidth: 988,
            cardWidth: width, spacing: spacing, horizontalPadding: padding
        )
        #expect(clamped == 488)

        let invalid = HorizontalScrollGeometry.targetOrigin(
            index: 4, currentOrigin: 0, viewportWidth: 500, documentWidth: 988,
            cardWidth: width, spacing: spacing, horizontalPadding: padding
        )
        #expect(invalid == nil)
    }
}
