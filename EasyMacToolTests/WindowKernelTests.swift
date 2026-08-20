import CoreGraphics
import Testing
@testable import EasyMacTool

@Suite("Window kernels")
struct WindowKernelTests {
    @Test func filterShowsVisibleCurrentSpaceAndRespectsToggle() {
        let current = WindowFilterInput(
            isVisible: true, isMinimized: false, isHidden: false, isCurrentSpace: true
        )
        let otherSpace = WindowFilterInput(
            isVisible: true, isMinimized: false, isHidden: false, isCurrentSpace: false
        )

        #expect(WindowFilterResolver.shouldShow(
            current,
            showMinimized: false,
            showHidden: false,
            currentSpaceOnly: true
        ))
        #expect(!WindowFilterResolver.shouldShow(
            otherSpace,
            showMinimized: false,
            showHidden: false,
            currentSpaceOnly: true
        ))
        #expect(WindowFilterResolver.shouldShow(
            otherSpace,
            showMinimized: false,
            showHidden: false,
            currentSpaceOnly: false
        ))
    }

    @Test func filterGivesMinimizedAndHiddenPriorityOverVisible() {
        let minimized = WindowFilterInput(
            isVisible: true, isMinimized: true, isHidden: false, isCurrentSpace: false
        )
        let hidden = WindowFilterInput(
            isVisible: false, isMinimized: false, isHidden: true, isCurrentSpace: false
        )

        #expect(WindowFilterResolver.shouldShow(
            minimized,
            showMinimized: true,
            showHidden: false,
            currentSpaceOnly: true
        ))
        #expect(!WindowFilterResolver.shouldShow(
            minimized,
            showMinimized: false,
            showHidden: false,
            currentSpaceOnly: true
        ))
        #expect(WindowFilterResolver.shouldShow(
            hidden,
            showMinimized: false,
            showHidden: true,
            currentSpaceOnly: true
        ))
    }

    @Test func orderPutsOnScreenBeforeOffScreen() {
        let onScreen = WindowSortKey(
            id: 1, pid: 1, isOffScreen: false, windowRank: 5, appRank: 5,
            title: "B", appName: "Beta"
        )
        let offScreen = WindowSortKey(
            id: 2, pid: 2, isOffScreen: true, windowRank: 1, appRank: 1,
            title: "A", appName: "Alpha"
        )

        #expect(WindowOrderResolver.sortedIndices([offScreen, onScreen]) == [1, 0])
    }

    @Test func orderUsesWindowMRUBeforeAppFallback() {
        let tracked = WindowSortKey(
            id: 1, pid: 1, isOffScreen: false, windowRank: 2, appRank: 1,
            title: "One", appName: "App"
        )
        let untrackedWindow = WindowSortKey(
            id: 2, pid: 2, isOffScreen: false, windowRank: Int.max, appRank: 3,
            title: "Two", appName: "App"
        )
        let untrackedApp = WindowSortKey(
            id: 3, pid: 3, isOffScreen: false, windowRank: Int.max, appRank: 1,
            title: "Three", appName: "Alpha"
        )

        #expect(WindowOrderResolver.sortedIndices(
            [untrackedWindow, tracked, untrackedApp]
        ) == [1, 2, 0])
    }

    @Test func orderSupportsAlphabeticalMode() {
        let beta = WindowSortKey(
            id: 1, pid: 1, isOffScreen: false, windowRank: 0, appRank: 0,
            title: "B", appName: "Beta"
        )
        let alpha = WindowSortKey(
            id: 2, pid: 2, isOffScreen: false, windowRank: 0, appRank: 0,
            title: "A", appName: "Alpha"
        )
        #expect(WindowOrderResolver.sortedIndices(
            [beta, alpha], order: .alphabetical
        ) == [1, 0])
    }

    @Test func selectionAdvancesAndWraps() {
        #expect(SelectionResolver.nextIndex(current: 0, count: 3, direction: 1) == 1)
        #expect(SelectionResolver.nextIndex(current: 2, count: 3, direction: 1) == 0)
        #expect(SelectionResolver.nextIndex(current: 0, count: 3, direction: -1) == 2)
        #expect(SelectionResolver.nextIndex(
            current: 2, count: 3, direction: 1, wraps: false
        ) == nil)
        #expect(SelectionResolver.nextIndex(current: 0, count: 0, direction: 1) == nil)
    }

    @Test func selectionAdjustsAfterRemoval() {
        #expect(SelectionResolver.indexAfterRemoval(
            current: 2, removedIndex: 0, countAfterRemoval: 3
        ) == 1)
        #expect(SelectionResolver.indexAfterRemoval(
            current: 2, removedIndex: 2, countAfterRemoval: 2
        ) == 1)
        #expect(SelectionResolver.indexAfterRemoval(
            current: 1, removedIndex: 2, countAfterRemoval: 2
        ) == 1)
        #expect(SelectionResolver.indexAfterRemoval(
            current: 0, removedIndex: 0, countAfterRemoval: 0
        ) == nil)
    }

    @Test func axMatchPrefersExactWindowID() {
        let candidates = [
            AXWindowMatchCandidate(
                id: 77,
                title: "谁在举报郭德纲？ - Google Chrome",
                frame: CGRect(x: 0, y: 30, width: 2240, height: 1151)
            ),
            AXWindowMatchCandidate(
                id: 78,
                title: "Second Window",
                frame: CGRect(x: 0, y: 0, width: 100, height: 100)
            )
        ]

        #expect(AXWindowMatchResolver.exactIndex(
            in: candidates,
            targetID: 77
        ) == 0)
        #expect(AXWindowMatchResolver.frameFallbackIndex(
            in: candidates,
            targetFrame: CGRect(x: 0, y: 30, width: 2240, height: 1151),
            targetTitle: "认仇人做父"
        ) == 0)
    }

    @Test func axMatchAcceptsUniqueFrameEvenWhenTitleDiffers() {
        let candidates = [
            AXWindowMatchCandidate(
                id: nil,
                title: "谁在举报郭德纲？ - Google Chrome - Matt",
                frame: CGRect(x: 0, y: 30, width: 2240, height: 1151)
            )
        ]

        #expect(AXWindowMatchResolver.frameFallbackIndex(
            in: candidates,
            targetFrame: CGRect(x: 0, y: 30, width: 2240, height: 1151),
            targetTitle: "认仇人做父，把亲爹送上绝路"
        ) == 0)
    }

    @Test func axMatchUsesTitleToDisambiguateSameFrameWindows() {
        let frame = CGRect(x: 0, y: 30, width: 2240, height: 1151)
        let candidates = [
            AXWindowMatchCandidate(id: nil, title: "Profile A", frame: frame),
            AXWindowMatchCandidate(id: nil, title: "认仇人做父", frame: frame)
        ]

        #expect(AXWindowMatchResolver.frameFallbackIndex(
            in: candidates,
            targetFrame: frame,
            targetTitle: "认仇人做父"
        ) == 1)
    }

    @Test func axMatchUsesContainedTitleForChromeSameFrameWindows() {
        let frame = CGRect(x: 0, y: 30, width: 2240, height: 1151)
        let candidates = [
            AXWindowMatchCandidate(
                id: nil,
                title: "Google 账号邮箱 - Google Chrome - DAVIE",
                frame: frame
            ),
            AXWindowMatchCandidate(
                id: nil,
                title: "V2EX - Google Chrome - Matt",
                frame: frame
            )
        ]

        #expect(AXWindowMatchResolver.frameFallbackIndex(
            in: candidates,
            targetFrame: frame,
            targetTitle: "V2EX"
        ) == 1)
        #expect(AXWindowMatchResolver.frameFallbackIndex(
            in: candidates,
            targetFrame: frame,
            targetTitle: "Google 账号邮箱"
        ) == 0)
    }

    @Test func axMatchDoesNotGuessWhenAllSameFrameTitlesDiffer() {
        let frame = CGRect(x: 0, y: 30, width: 2240, height: 1151)
        let candidates = [
            AXWindowMatchCandidate(id: nil, title: "Profile A", frame: frame),
            AXWindowMatchCandidate(id: nil, title: "Profile B", frame: frame)
        ]

        #expect(AXWindowMatchResolver.frameFallbackIndex(
            in: candidates,
            targetFrame: frame,
            targetTitle: "认仇人做父"
        ) == nil)
    }

}
