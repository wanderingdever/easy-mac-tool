import CoreGraphics
import Testing
@testable import EasyMacTool

@Suite("Clipboard horizontal scroll geometry")
struct HorizontalScrollGeometryTests {
    @Test func mapsDiscreteWheelDirectionToAdjacentCard() {
        #expect(HorizontalScrollGeometry.discreteStep(verticalDelta: -2) == 1)
        #expect(HorizontalScrollGeometry.discreteStep(verticalDelta: 2) == -1)
        #expect(HorizontalScrollGeometry.discreteStep(verticalDelta: 0) == nil)
    }

    @Test func smoothStepConvergesWithoutOvershooting() {
        var current: CGFloat = 0
        let target: CGFloat = 246
        for _ in 0..<120 {
            let next = HorizontalScrollGeometry.smoothedOrigin(current: current, target: target)
            #expect(next >= current)
            #expect(next <= target)
            current = next
        }
        #expect(current == target)

        let reverse = HorizontalScrollGeometry.smoothedOrigin(current: 200, target: 100)
        #expect(reverse < 200)
        #expect(reverse >= 100)
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

@Suite("Clipboard preview geometry")
struct ClipboardPreviewGeometryTests {
    @Test func preservesShadowSpaceOnSmallPanel() {
        let height = ClipboardPreviewGeometry.height(containerHeight: 180)
        #expect(height == 132)
        #expect(height + ClipboardPreviewGeometry.verticalShadowInset * 2 <= 180)
    }

    @Test func usesEightyPercentOnRegularPanel() {
        #expect(ClipboardPreviewGeometry.height(containerHeight: 260) == 208)
    }

    @Test func capsPreviewOnTallPanel() {
        #expect(ClipboardPreviewGeometry.height(containerHeight: 500) == 320)
    }
}
