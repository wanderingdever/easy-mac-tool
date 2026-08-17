import Foundation

/// Shared ceilings for image-heavy subsystems. Live ScreenCaptureKit surfaces
/// and SwiftUI backing stores sit outside these caches, so cached content stays
/// below the overall process allowance and shrinks under thermal pressure.
nonisolated enum ImageMemoryBudget {
    static let nominalTotalBytes = 160 * 1024 * 1024
    static let clipboardHistoryBytes = 96 * 1024 * 1024
    static let windowPreviewBytes = 40 * 1024 * 1024
    static let clipboardFullImageBytes = 20 * 1024 * 1024
    static let linkFaviconBytes = 4 * 1024 * 1024

    static func adjusted(_ bytes: Int) -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .serious: return bytes / 2
        case .critical: return bytes / 4
        default: return bytes
        }
    }

    static func decodedRGBABytes(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return byteOverflow ? nil : bytes
    }
}
