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
}
