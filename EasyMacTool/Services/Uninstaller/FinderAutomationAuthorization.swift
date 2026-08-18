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
            let determined = determinePermission(askUserIfNeeded: true)
            switch determined {
            case .granted, .notDetermined:
                // The permission query alone does not create a TCC Automation
                // row on every macOS release. Send one harmless read-only
                // Finder event so the request is registered consistently.
                return probeFinder()
            case .denied, .unavailable:
                return determined
            }
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

    /// Sends a read-only event solely to trigger the system's Automation
    /// consent flow. No Finder files, windows, or settings are changed.
    private static func probeFinder() -> Status {
        let source = "tell application \"Finder\" to get name of startup disk"
        guard let script = NSAppleScript(source: source) else { return .unavailable }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .granted }
        guard let number = errorInfo[NSAppleScript.errorNumber] as? Int else {
            return .unavailable
        }
        return status(for: OSStatus(number))
    }
}
