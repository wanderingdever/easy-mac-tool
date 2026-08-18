import CoreServices
import Foundation

nonisolated enum FinderAutomationAuthorization {
    enum Status: Equatable, Sendable {
        case granted
        case notDetermined
        case denied
        case unavailable
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity?Privacy_Automation"
    )!

    static func currentStatus() -> Status {
        determinePermission(askUserIfNeeded: false)
    }

    static func requestPermission() async -> Status {
        await Task.detached(priority: .userInitiated) {
            determinePermission(askUserIfNeeded: true)
        }.value
    }

    static func status(for result: OSStatus) -> Status {
        switch result {
        case noErr:
            return .granted
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        case OSStatus(errAEEventNotPermitted), OSStatus(errAETargetAddressNotPermitted):
            return .denied
        default:
            return .unavailable
        }
    }

    private static func determinePermission(askUserIfNeeded: Bool) -> Status {
        let bundleID = Data("com.apple.finder".utf8)
        var target = AEAddressDesc()
        let creationResult = bundleID.withUnsafeBytes { bytes in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                bytes.baseAddress,
                bundleID.count,
                &target
            )
        }
        guard creationResult == noErr else { return .unavailable }
        defer { AEDisposeDesc(&target) }

        let result = AEDeterminePermissionToAutomateTarget(
            &target,
            typeWildCard,
            typeWildCard,
            askUserIfNeeded
        )
        return status(for: result)
    }
}
