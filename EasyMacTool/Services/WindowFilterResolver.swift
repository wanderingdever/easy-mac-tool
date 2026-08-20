import Foundation

/// Pure window-visibility policy. UI and enumeration code call this instead of
/// embedding filter branches, so the behavior stays testable.
nonisolated struct WindowFilterInput: Equatable {
    let isVisible: Bool
    let isMinimized: Bool
    let isHidden: Bool
    let isCurrentSpace: Bool
}

nonisolated enum WindowFilterResolver {
    static func shouldShow(
        _ input: WindowFilterInput,
        showMinimized: Bool,
        showHidden: Bool,
        currentSpaceOnly: Bool
    ) -> Bool {
        if input.isMinimized {
            return showMinimized
        }
        if input.isHidden {
            return showHidden
        }
        guard input.isVisible else { return false }
        return !currentSpaceOnly || input.isCurrentSpace
    }
}
