import Foundation
import Testing
@testable import EasyMacTool

@Suite("Installed applications catalog")
struct InstalledAppsCatalogTests {
    @Test func lightweightDiscoverySkipsSizeWorkExcludedAppsAndSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let visible = try makeApplication(named: "Visible", bundleID: "com.example.visible", in: root)
        let excluded = try makeApplication(named: "Excluded", bundleID: "com.example.excluded", in: root)
        let link = root.appendingPathComponent("Linked.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: visible)

        let apps = InstalledApps.discoverApplications(
            roots: [root],
            excluding: excluded
        )

        #expect(apps.count == 1)
        #expect(apps.first?.url == visible.standardizedFileURL)
        #expect(apps.first?.bundleID == "com.example.visible")
        #expect(apps.first?.sizeBytes == nil)
        #expect(InstalledApps.isSystemApplication(
            at: URL(fileURLWithPath: "/System/Applications/Safari.app")
        ))
    }

    @Test func cacheRoundTripsAndRejectsCorruptionOrUnknownVersion() throws {
        let fingerprint = testFingerprint(inode: 1)
        let app = testApp(path: "/Applications/Test.app",
                          fingerprint: fingerprint,
                          size: 42)
        let snapshot = InstalledApps.snapshot(for: [app], date: Date(timeIntervalSince1970: 10))
        let data = try #require(InstalledApps.encodeSnapshot(snapshot))

        #expect(InstalledApps.decodeSnapshot(data) == snapshot)
        #expect(InstalledApps.decodeSnapshot(Data("not json".utf8)) == nil)

        let future = InstalledApps.CacheSnapshot(
            version: InstalledApps.cacheVersion + 1,
            apps: [InstalledApps.CachedApp(app: app)]
        )
        let futureData = try #require(InstalledApps.encodeSnapshot(future))
        #expect(InstalledApps.decodeSnapshot(futureData) == nil)
    }

    @Test func matchingFingerprintReusesSizeAndChangedFingerprintInvalidatesIt() {
        let original = testApp(path: "/Applications/Test.app",
                               fingerprint: testFingerprint(inode: 1),
                               size: nil)
        let cached = InstalledApps.CachedApp(app: testApp(
            path: original.id,
            fingerprint: original.fingerprint,
            size: 123
        ))

        let reused = InstalledApps.mergingSizes(
            into: [original],
            cached: [cached],
            reuseSizes: true
        )
        #expect(reused.first?.sizeBytes == 123)

        let replaced = testApp(path: original.id,
                               fingerprint: testFingerprint(inode: 2),
                               size: nil)
        let invalidated = InstalledApps.mergingSizes(
            into: [replaced],
            cached: [cached],
            reuseSizes: true
        )
        #expect(invalidated.first?.sizeBytes == nil)

        let forced = InstalledApps.mergingSizes(
            into: [original],
            cached: [cached],
            reuseSizes: false
        )
        #expect(forced.first?.sizeBytes == nil)
    }

    @Test func discoveryResultDropsDeletedCacheRowsAndKeepsNewRows() {
        let existing = testApp(path: "/Applications/Existing.app",
                               fingerprint: testFingerprint(inode: 1),
                               size: nil)
        let added = testApp(path: "/Applications/Added.app",
                            fingerprint: testFingerprint(inode: 2),
                            size: nil)
        let deleted = testApp(path: "/Applications/Deleted.app",
                              fingerprint: testFingerprint(inode: 3),
                              size: 99)

        let result = InstalledApps.mergingSizes(
            into: [existing, added],
            cached: [InstalledApps.CachedApp(app: deleted)],
            reuseSizes: true
        )

        #expect(Set(result.map(\.id)) == Set([existing.id, added.id]))
        #expect(result.allSatisfy { $0.sizeBytes == nil })
    }

    @Test func staleGenerationIsRejected() {
        #expect(InstalledApps.accepts(updateGeneration: 7, currentGeneration: 7))
        #expect(!InstalledApps.accepts(updateGeneration: 6, currentGeneration: 7))
    }

    @Test func sizeMeasurementPublishesProgressivelyWithBoundedConcurrency() async {
        let probe = ConcurrencyProbe()
        let apps = (0..<6).map {
            testApp(path: "/Applications/App\($0).app",
                    fingerprint: testFingerprint(inode: UInt64($0 + 1)),
                    size: nil)
        }
        var updates: [InstalledApps.SizeUpdate] = []

        for await update in InstalledApps.sizeUpdates(
            for: apps,
            maximumConcurrency: 2,
            measure: { url in await probe.measure(url) }
        ) {
            updates.append(update)
        }

        #expect(updates.count == apps.count)
        #expect(Set(updates.map(\.id)) == Set(apps.map(\.id)))
        #expect(await probe.maximumActive() == 2)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyMacTool-InstalledApps-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApplication(named name: String,
                                 bundleID: String,
                                 in root: URL) throws -> URL {
        let appURL = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 1, count: 4_096)
            .write(to: contents.appendingPathComponent("payload.bin"))
        return appURL
    }

    private func testFingerprint(inode: UInt64) -> InstalledApps.Fingerprint {
        InstalledApps.Fingerprint(device: 1,
                                  inode: inode,
                                  bundleModifiedAt: Date(timeIntervalSince1970: 1),
                                  infoPlistModifiedAt: Date(timeIntervalSince1970: 2))
    }

    private func testApp(path: String,
                         fingerprint: InstalledApps.Fingerprint,
                         size: Int64?) -> InstalledApps.InstalledApp {
        InstalledApps.InstalledApp(
            id: path,
            name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            bundleID: "com.example.test",
            url: URL(fileURLWithPath: path, isDirectory: true),
            isSystem: false,
            fingerprint: fingerprint,
            sizeBytes: size
        )
    }
}

private actor ConcurrencyProbe {
    private var active = 0
    private var peak = 0

    func measure(_ url: URL) async -> Int64 {
        active += 1
        peak = max(peak, active)
        try? await Task.sleep(nanoseconds: 20_000_000)
        active -= 1
        return Int64(url.path.count)
    }

    func maximumActive() -> Int {
        peak
    }
}
