import CoreServices
import Darwin
import Foundation
import Testing
@testable import EasyMacTool

@Suite("Uninstaller path safety")
struct UninstallerSupportTests {
    @Test func validatesBundleIdentifiers() {
        #expect(UninstallerSupport.verifiedBundleID("com.example.Tool") == "com.example.Tool")
        #expect(UninstallerSupport.verifiedBundleID("Tool") == nil)
        #expect(UninstallerSupport.verifiedBundleID("../Library") == nil)
        #expect(UninstallerSupport.verifiedBundleID("com..example") == nil)
        #expect(UninstallerSupport.verifiedBundleID("com.apple.Safari") == nil)
    }

    @Test func descendantCheckHonorsPathComponents() {
        let root = URL(fileURLWithPath: "/Applications/Foo.app")
        #expect(UninstallerSupport.isDescendant(
            URL(fileURLWithPath: "/Applications/Foo.app/Contents/PlugIns/Bar.appex"), of: root
        ))
        #expect(!UninstallerSupport.isDescendant(
            URL(fileURLWithPath: "/Applications/Foo.app.backup/Contents"), of: root
        ))
    }

    @Test func identityRejectsSymlinksAndChangesAfterReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyMacToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("candidate")
        try Data("first".utf8).write(to: file)
        let original = try #require(UninstallerSupport.fileIdentity(at: file))

        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(UninstallerSupport.fileIdentity(at: link) == nil)

        try FileManager.default.removeItem(at: file)
        try Data("replacement".utf8).write(to: file)
        #expect(UninstallerSupport.fileIdentity(at: file) != original)
    }

    @Test func finderAutomationStatusMapsConsentAndDenial() {
        #expect(FinderAutomationAuthorization.status(for: noErr) == .granted)
        #expect(FinderAutomationAuthorization.status(
            for: OSStatus(errAEEventWouldRequireUserConsent)
        ) == .notDetermined)
        #expect(FinderAutomationAuthorization.status(
            for: OSStatus(errAEEventNotPermitted)
        ) == .denied)
        #expect(FinderAutomationAuthorization.status(for: -9999) == .unavailable)
    }

    @Test func finderEscalationOnlyAppliesToPermissionErrors() {
        #expect(AppUninstaller.requiresFinderAuthorization(
            for: NSError(domain: NSCocoaErrorDomain,
                         code: CocoaError.Code.fileWriteNoPermission.rawValue)
        ))
        #expect(AppUninstaller.requiresFinderAuthorization(
            for: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        ))
        #expect(!AppUninstaller.requiresFinderAuthorization(
            for: NSError(domain: NSCocoaErrorDomain,
                         code: CocoaError.Code.fileNoSuchFile.rawValue)
        ))
        #expect(!AppUninstaller.requiresFinderAuthorization(
            for: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        ))
    }

    @Test func launchItemsAreClassifiedAndUseArgumentArrays() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyMacTool-LaunchItem-\(UUID().uuidString)",
                                    isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plistURL = agents.appendingPathComponent("com.example.agent.plist")
        let plist: [String: Any] = [
            "Label": "com.example.agent",
            "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/Example"],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL)

        let item = try #require(UninstallerRuntimeSupport.launchItem(at: plistURL, home: home))
        #expect(item.kind == .userAgent)
        #expect(item.label == "com.example.agent")
        #expect(UninstallerRuntimeSupport.bootoutArguments(for: item, uid: 501)
                == ["bootout", "gui/501", plistURL.path])
        #expect(UninstallerRuntimeSupport.bootstrapArguments(for: item, uid: 501)
                == ["bootstrap", "gui/501", plistURL.path])

        #expect(UninstallerRuntimeSupport.launchItemKind(
            for: URL(fileURLWithPath: "/Library/LaunchAgents/com.example.agent.plist"),
            home: home
        ) == .sharedAgent)
        #expect(UninstallerRuntimeSupport.launchItemKind(
            for: URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.daemon.plist"),
            home: home
        ) == .systemDaemon)
    }

    @Test func launchctlMissingServiceIsNotAnUninstallFailure() {
        #expect(UninstallerRuntimeSupport.bootoutDisposition(.init(
            exitCode: 5,
            errorText: "Boot-out failed: 3: No such process"
        )) == .notLoaded)
        #expect(UninstallerRuntimeSupport.bootoutDisposition(.init(
            exitCode: 1,
            errorText: "Operation not permitted"
        )) == .failed)
        #expect(UninstallerRuntimeSupport.bootoutDisposition(.init(
            exitCode: 0,
            errorText: ""
        )) == .stopped)
    }

    @Test func processEligibilityRejectsOtherUsersAndIdentityChanges() {
        let appURL = URL(fileURLWithPath: "/Applications/Example.app", isDirectory: true)
        let expected = UninstallerRuntimeSupport.ProcessIdentity(
            pid: 42,
            uid: 501,
            executablePath: "/Applications/Example.app/Contents/MacOS/Example"
        )
        #expect(UninstallerRuntimeSupport.isEligibleProcess(
            expected,
            appURL: appURL,
            currentUID: 501,
            ownPID: 99
        ))
        #expect(!UninstallerRuntimeSupport.isEligibleProcess(
            .init(pid: 42, uid: 0, executablePath: expected.executablePath),
            appURL: appURL,
            currentUID: 501,
            ownPID: 99
        ))
        #expect(UninstallerRuntimeSupport.isSameProcess(
            expected,
            current: .init(pid: 42,
                           uid: 501,
                           executablePath: "/Applications/Other.app/Contents/MacOS/Other"),
            appURL: appURL,
            currentUID: 501,
            ownPID: 99
        ) == false)

        let externalHelper = UninstallerRuntimeSupport.ProcessIdentity(
            pid: 43,
            uid: 501,
            executablePath: "/Library/Application Support/Example/helper"
        )
        #expect(UninstallerRuntimeSupport.isSameProcess(
            externalHelper,
            current: externalHelper,
            appURL: appURL,
            allowsExternalPath: true,
            currentUID: 501,
            ownPID: 99
        ))
    }
}
