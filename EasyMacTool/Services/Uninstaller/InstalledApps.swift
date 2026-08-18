import AppKit
import Combine

/// Installed-application discovery and cache primitives used by the uninstaller.
/// Discovery intentionally does not recurse into app bundles; allocated sizes are
/// measured separately and streamed back as each bundle finishes.
nonisolated enum InstalledApps {
    static let cacheVersion = 1
    static let defaultMaximumSizeConcurrency = 2

    @MainActor private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    struct Fingerprint: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let bundleModifiedAt: Date?
        let infoPlistModifiedAt: Date?
    }

    struct InstalledApp: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let bundleID: String?
        let url: URL
        let isSystem: Bool
        let fingerprint: Fingerprint
        var sizeBytes: Int64?

        @MainActor var icon: NSImage {
            let key = id as NSString
            if let cached = InstalledApps.iconCache.object(forKey: key) { return cached }
            let image = NSWorkspace.shared.icon(forFile: url.path)
            InstalledApps.iconCache.setObject(image, forKey: key)
            return image
        }
    }

    struct CachedApp: Codable, Equatable, Sendable {
        let path: String
        let name: String
        let bundleID: String?
        let isSystem: Bool
        let fingerprint: Fingerprint
        let sizeBytes: Int64?

        init(app: InstalledApp) {
            path = app.url.standardizedFileURL.path
            name = app.name
            bundleID = app.bundleID
            isSystem = app.isSystem
            fingerprint = app.fingerprint
            sizeBytes = app.sizeBytes
        }
    }

    struct CacheSnapshot: Codable, Equatable, Sendable {
        let version: Int
        let generatedAt: Date
        let apps: [CachedApp]

        init(version: Int = InstalledApps.cacheVersion,
             generatedAt: Date = Date(),
             apps: [CachedApp]) {
            self.version = version
            self.generatedAt = generatedAt
            self.apps = apps
        }
    }

    struct SizeUpdate: Equatable, Sendable {
        let id: String
        let fingerprint: Fingerprint
        let sizeBytes: Int64
    }

    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Apps that belong to the system wherever their bundle really sits. They
    /// are never offered for uninstalling.
    private static let systemPathPrefixes = ["/System/", "/Library/Apple/"]

    static func isSystemApplication(at url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return systemPathPrefixes.contains { path.hasPrefix($0) }
    }

    static func fingerprint(at url: URL,
                            fileManager fm: FileManager = .default) -> Fingerprint? {
        guard let identity = UninstallerSupport.fileIdentity(at: url) else { return nil }
        let bundleModifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        let infoURL = url.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let infoModifiedAt = try? infoURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return Fingerprint(device: identity.device,
                           inode: identity.inode,
                           bundleModifiedAt: bundleModifiedAt,
                           infoPlistModifiedAt: infoModifiedAt)
    }

    /// Fast metadata-only discovery. No app bundle contents are traversed here.
    static func discoverApplications(
        includeSystemApplications: Bool = false,
        roots customRoots: [URL]? = nil,
        excluding excludedURL: URL? = Bundle.main.bundleURL,
        fileManager fm: FileManager = .default
    ) -> [InstalledApp] {
        var roots = customRoots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Applications", isDirectory: true),
        ]
        if customRoots == nil, includeSystemApplications {
            roots.append(URL(fileURLWithPath: "/System/Applications", isDirectory: true))
        }

        let excludedPath = excludedURL?.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        for root in roots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

                let standardized = url.standardizedFileURL
                let path = standardized.path
                guard path != excludedPath else { continue }
                let system = isSystemApplication(at: standardized)
                guard includeSystemApplications || !system else { continue }
                guard seen.insert(path).inserted,
                      let fingerprint = fingerprint(at: standardized, fileManager: fm) else {
                    continue
                }

                var name = fm.displayName(atPath: path)
                if name.hasSuffix(".app") { name.removeLast(4) }
                apps.append(InstalledApp(
                    id: path,
                    name: name,
                    bundleID: Bundle(url: standardized)?.bundleIdentifier,
                    url: standardized,
                    isSystem: system,
                    fingerprint: fingerprint,
                    sizeBytes: nil
                ))
            }
        }

        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Converts a disk snapshot into immediately displayable rows. Missing,
    /// protected, replaced, or symlinked paths are pruned before publication.
    static func validatedCachedApplications(
        from snapshot: CacheSnapshot,
        excluding excludedURL: URL? = Bundle.main.bundleURL,
        fileManager fm: FileManager = .default
    ) -> [InstalledApp] {
        guard snapshot.version == cacheVersion else { return [] }
        let excludedPath = excludedURL?.standardizedFileURL.path
        return snapshot.apps.compactMap { cached in
            let url = URL(fileURLWithPath: cached.path, isDirectory: true).standardizedFileURL
            guard url.path != excludedPath,
                  fm.fileExists(atPath: url.path),
                  !isSystemApplication(at: url),
                  let currentFingerprint = fingerprint(at: url, fileManager: fm) else {
                return nil
            }
            return InstalledApp(
                id: url.path,
                name: cached.name,
                bundleID: cached.bundleID,
                url: url,
                isSystem: false,
                fingerprint: currentFingerprint,
                sizeBytes: currentFingerprint == cached.fingerprint ? cached.sizeBytes : nil
            )
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Reuses a cached size only when the app bundle fingerprint still matches.
    static func mergingSizes(into discovered: [InstalledApp],
                             cached: [CachedApp],
                             reuseSizes: Bool) -> [InstalledApp] {
        guard reuseSizes else { return discovered }
        let cachedByPath = Dictionary(cached.map { ($0.path, $0) },
                                      uniquingKeysWith: { first, _ in first })
        return discovered.map { app in
            var app = app
            if let cached = cachedByPath[app.id],
               cached.fingerprint == app.fingerprint {
                app.sizeBytes = cached.sizeBytes
            }
            return app
        }
    }

    /// Produces size results incrementally while keeping disk traversal bounded.
    static func sizeUpdates(
        for apps: [InstalledApp],
        maximumConcurrency: Int = defaultMaximumSizeConcurrency,
        measure: @escaping @Sendable (URL) async -> Int64 = {
            measureAllocatedSize(at: $0)
        }
    ) -> AsyncStream<SizeUpdate> {
        AsyncStream { continuation in
            let worker = Task.detached(priority: .utility) {
                let limit = max(1, maximumConcurrency)
                await withTaskGroup(of: SizeUpdate?.self) { group in
                    var iterator = apps.makeIterator()
                    for _ in 0..<min(limit, apps.count) {
                        guard let app = iterator.next() else { break }
                        group.addTask {
                            guard !Task.isCancelled else { return nil }
                            let size = await measure(app.url)
                            guard !Task.isCancelled else { return nil }
                            return SizeUpdate(id: app.id,
                                              fingerprint: app.fingerprint,
                                              sizeBytes: size)
                        }
                    }

                    while let update = await group.next() {
                        guard !Task.isCancelled else {
                            group.cancelAll()
                            break
                        }
                        if let update { continuation.yield(update) }
                        if let app = iterator.next() {
                            group.addTask {
                                guard !Task.isCancelled else { return nil }
                                let size = await measure(app.url)
                                guard !Task.isCancelled else { return nil }
                                return SizeUpdate(id: app.id,
                                                  fingerprint: app.fingerprint,
                                                  sizeBytes: size)
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    static func measureAllocatedSize(at url: URL,
                                     fileManager fm: FileManager = .default) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if fingerprint(at: url, fileManager: fm) == nil || !isDirectory.boolValue {
            return fileSize(url)
        }

        let keys: Set<URLResourceKey> = [
            .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        var total: Int64 = 0
        if let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) {
            for case let item as URL in enumerator {
                if Task.isCancelled { break }
                let values = try? item.resourceValues(forKeys: keys)
                if values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                total += Int64(values?.totalFileAllocatedSize
                               ?? values?.fileAllocatedSize
                               ?? 0)
            }
        }
        return total
    }

    static func snapshot(for apps: [InstalledApp], date: Date = Date()) -> CacheSnapshot {
        CacheSnapshot(generatedAt: date, apps: apps.map(CachedApp.init))
    }

    static func decodeSnapshot(_ data: Data) -> CacheSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(CacheSnapshot.self, from: data),
              snapshot.version == cacheVersion else {
            return nil
        }
        return snapshot
    }

    static func encodeSnapshot(_ snapshot: CacheSnapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    static func loadSnapshot(fileManager fm: FileManager = .default) -> CacheSnapshot? {
        guard let url = cacheFileURL(fileManager: fm),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return decodeSnapshot(data)
    }

    static func saveSnapshot(_ snapshot: CacheSnapshot,
                             fileManager fm: FileManager = .default) {
        guard let url = cacheFileURL(fileManager: fm),
              let data = encodeSnapshot(snapshot) else {
            return
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // This cache is fully rebuildable. Failure only affects next-load speed.
        }
    }

    static func accepts(updateGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        updateGeneration == currentGeneration
    }

    @MainActor
    static func clearIconCache() {
        iconCache.removeAllObjects()
    }

    private static func cacheFileURL(fileManager fm: FileManager) -> URL? {
        fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EasyMacTool", isDirectory: true)
            .appendingPathComponent("InstalledApps.json", isDirectory: false)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(
            forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        )
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }
}

/// Shared stale-while-revalidate catalog. It survives settings-page navigation
/// and only performs lightweight discovery after the five-minute freshness TTL.
@MainActor
final class InstalledAppsCatalog: ObservableObject {
    static let shared = InstalledAppsCatalog()
    static let discoveryFreshness: TimeInterval = 5 * 60

    @Published private(set) var apps: [InstalledApps.InstalledApp] = []
    @Published private(set) var isDiscovering = false
    @Published private(set) var isMeasuringSizes = false

    private var lastDiscoveryAt: Date?
    private var generation: UInt64 = 0
    private var workflowTask: Task<Void, Never>?

    private init() {}

    func loadIfNeeded(now: Date = Date()) {
        if isDiscovering || isMeasuringSizes { return }
        if let lastDiscoveryAt,
           now.timeIntervalSince(lastDiscoveryAt) < Self.discoveryFreshness {
            return
        }
        startWorkflow(forceSizeRefresh: false, publishDiskCache: apps.isEmpty)
    }

    func refresh() {
        startWorkflow(forceSizeRefresh: true, publishDiskCache: false)
    }

    func removeApplication(at url: URL) {
        workflowTask?.cancel()
        generation &+= 1
        let path = url.standardizedFileURL.path
        apps.removeAll { $0.id == path }
        isDiscovering = false
        isMeasuringSizes = false
        lastDiscoveryAt = nil
        InstalledApps.clearIconCache()

        let removalSnapshot = InstalledApps.snapshot(for: apps)
        Task.detached(priority: .utility) {
            InstalledApps.saveSnapshot(removalSnapshot)
        }

        // Reconcile with disk immediately. The current list remains visible and
        // the final workflow snapshot removes the deleted path from disk cache.
        startWorkflow(forceSizeRefresh: false, publishDiskCache: false)
    }

    private func startWorkflow(forceSizeRefresh: Bool, publishDiskCache: Bool) {
        workflowTask?.cancel()
        generation &+= 1
        let workflowGeneration = generation
        let currentCache = apps.map(InstalledApps.CachedApp.init)
        isDiscovering = true
        isMeasuringSizes = false

        workflowTask = Task { @MainActor [weak self] in
            let diskSnapshot = await Task.detached(priority: .utility) {
                InstalledApps.loadSnapshot()
            }.value
            guard let self,
                  InstalledApps.accepts(updateGeneration: workflowGeneration,
                                        currentGeneration: self.generation),
                  !Task.isCancelled else {
                return
            }

            if publishDiskCache, self.apps.isEmpty, let diskSnapshot {
                let cachedApps = await Task.detached(priority: .utility) {
                    InstalledApps.validatedCachedApplications(from: diskSnapshot)
                }.value
                guard InstalledApps.accepts(updateGeneration: workflowGeneration,
                                            currentGeneration: self.generation),
                      !Task.isCancelled else {
                    return
                }
                self.apps = cachedApps
            }

            let discovered = await Task.detached(priority: .userInitiated) {
                InstalledApps.discoverApplications()
            }.value
            guard InstalledApps.accepts(updateGeneration: workflowGeneration,
                                        currentGeneration: self.generation),
                  !Task.isCancelled else {
                return
            }

            var cacheByPath = Dictionary(
                (diskSnapshot?.apps ?? []).map { ($0.path, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for cached in currentCache {
                cacheByPath[cached.path] = cached
            }
            let merged = InstalledApps.mergingSizes(
                into: discovered,
                cached: Array(cacheByPath.values),
                reuseSizes: !forceSizeRefresh
            )
            self.apps = merged
            self.lastDiscoveryAt = Date()
            self.isDiscovering = false

            let pending = forceSizeRefresh ? merged : merged.filter { $0.sizeBytes == nil }
            guard !pending.isEmpty else {
                await self.persistCurrentApps(workflowGeneration: workflowGeneration)
                self.finishWorkflow(workflowGeneration)
                return
            }

            self.isMeasuringSizes = true
            let updates = InstalledApps.sizeUpdates(for: pending)
            for await update in updates {
                guard InstalledApps.accepts(updateGeneration: workflowGeneration,
                                            currentGeneration: self.generation),
                      !Task.isCancelled else {
                    return
                }
                guard let index = self.apps.firstIndex(where: { $0.id == update.id }),
                      self.apps[index].fingerprint == update.fingerprint else {
                    continue
                }
                self.apps[index].sizeBytes = update.sizeBytes
            }

            guard InstalledApps.accepts(updateGeneration: workflowGeneration,
                                        currentGeneration: self.generation),
                  !Task.isCancelled else {
                return
            }
            await self.persistCurrentApps(workflowGeneration: workflowGeneration)
            self.finishWorkflow(workflowGeneration)
        }
    }

    private func persistCurrentApps(workflowGeneration: UInt64) async {
        guard InstalledApps.accepts(updateGeneration: workflowGeneration,
                                    currentGeneration: generation) else {
            return
        }
        let snapshot = InstalledApps.snapshot(for: apps)
        await Task.detached(priority: .utility) {
            InstalledApps.saveSnapshot(snapshot)
        }.value
    }

    private func finishWorkflow(_ workflowGeneration: UInt64) {
        guard InstalledApps.accepts(updateGeneration: workflowGeneration,
                                    currentGeneration: generation) else {
            return
        }
        isDiscovering = false
        isMeasuringSizes = false
        workflowTask = nil
    }
}
