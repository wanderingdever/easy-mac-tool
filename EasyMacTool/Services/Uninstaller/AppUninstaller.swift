import AppKit
import Combine
import Darwin

/// Finds the files an app leaves around — caches, preferences, logs, support
/// folders, containers — and moves the ones the user picks to the Trash, then
/// reports the space recovered. Everything goes to the Trash (reversible), never
/// an unrecoverable delete.
final class AppUninstaller: ObservableObject {
    static let shared = AppUninstaller()
    nonisolated private static let finderQueue = DispatchQueue(
        label: "com.easymactool.uninstaller.finder-apple-event",
        qos: .userInitiated
    )

    enum Phase: Equatable {
        case empty
        case scanning
        case results
        case removing
        case done(freed: Int64, failed: Int)
    }

    struct Target: Equatable {
        let name: String
        let bundleID: String?
        let url: URL
        let icon: NSImage

        static func == (lhs: Target, rhs: Target) -> Bool { lhs.url == rhs.url }
    }

    nonisolated enum Category: Int, CaseIterable, Sendable {
        case app, support, caches, preferences, containers, logs, state, other

        var sortRank: Int { rawValue }
    }

    nonisolated struct Leftover: Identifiable, Equatable, Sendable {
        let id = UUID()
        let url: URL
        let category: Category
        let size: Int64
        let identity: UninstallerSupport.FileIdentity
        var include: Bool = true

        var name: String { url.lastPathComponent }

        static func == (lhs: Leftover, rhs: Leftover) -> Bool {
            lhs.id == rhs.id && lhs.include == rhs.include
        }
    }

    nonisolated struct RemovalFailure: Identifiable, Sendable {
        let id = UUID()
        let url: URL
        let reason: String
    }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var target: Target?
    @Published var items: [Leftover] = []
    @Published private(set) var removalFailures: [RemovalFailure] = []
    private var allowedRemovalPaths = Set<String>()

    private init() {}

    var selectedSize: Int64 { items.filter(\.include).reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    // MARK: - Selection & scan

    func select(appURL: URL) {
        guard let bundle = Bundle(url: appURL) else { return }
        guard !InstalledApps.isSystemApplication(at: appURL) else { return }
        guard let bundleID = UninstallerSupport.verifiedBundleID(bundle.bundleIdentifier) else { return }
        let selectedURL = appURL.standardizedFileURL
        guard selectedURL == selectedURL.resolvingSymlinksInPath() else { return }
        guard selectedURL != Bundle.main.bundleURL.standardizedFileURL else { return }
        guard !Self.isSymbolicLink(appURL) else { return }
        var name = FileManager.default.displayName(atPath: appURL.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)

        target = Target(name: name, bundleID: bundleID, url: selectedURL, icon: icon)
        items = []
        removalFailures = []
        allowedRemovalPaths = []
        phase = .scanning

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Self.collect(bundleID: bundleID, appURL: selectedURL)
            DispatchQueue.main.async {
                guard let self, self.phase == .scanning, self.target?.url == selectedURL else { return }
                self.items = found
                self.allowedRemovalPaths = Set(found.map { $0.url.standardizedFileURL.path })
                self.phase = .results
            }
        }
    }

    func setInclude(_ include: Bool, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].include = include
    }

    func reset() {
        target = nil
        items = []
        removalFailures = []
        allowedRemovalPaths = []
        phase = .empty
    }

    // MARK: - Removal

    func removeSelected() {
        let chosen = items.filter(\.include)
        guard !chosen.isEmpty else { return }
        phase = .removing
        let allowedPaths = allowedRemovalPaths
        let targetURL = target?.url

        let initiallySafe = chosen.filter {
            Self.removalIsStillSafe($0, allowedPaths: allowedPaths, targetURL: targetURL)
        }
        let initiallySafeIDs = Set(initiallySafe.map(\.id))
        let initialFailures = chosen.filter { candidate in
            !initiallySafeIDs.contains(candidate.id)
        }.map {
            RemovalFailure(url: $0.url, reason: "文件身份或路径在确认后发生变化")
        }

        guard !initiallySafe.isEmpty else {
            removalFailures = initialFailures
            phase = .done(freed: 0, failed: initialFailures.count)
            return
        }

        var terminatingPIDs = Set<pid_t>()
        if let bundleID = target?.bundleID, let targetURL {
            for app in NSWorkspace.shared.runningApplications where
                app.bundleIdentifier == bundleID
                || UninstallerSupport.isNestedBundle(app.bundleURL, in: targetURL) {
                terminatingPIDs.insert(app.processIdentifier)
                app.terminate()
            }
        }

        Task { @MainActor [weak self] in
            await Self.waitForApplicationsToExit(terminatingPIDs, timeout: 3)
            guard let self, self.phase == .removing else { return }
            self.performRemoval(initiallySafe,
                                initialFailures: initialFailures,
                                allowedPaths: allowedPaths,
                                targetURL: targetURL)
        }
    }

    private static func waitForApplicationsToExit(_ pids: Set<pid_t>, timeout: TimeInterval) async {
        guard !pids.isEmpty else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let runningPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            if pids.isDisjoint(with: runningPIDs) { return }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }
    }

    private func performRemoval(_ initiallySafe: [Leftover],
                                initialFailures: [RemovalFailure],
                                allowedPaths: Set<String>,
                                targetURL: URL?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var freed: Int64 = 0
            var stubborn: [Leftover] = []
            var failures = initialFailures
            for item in initiallySafe {
                guard Self.removalIsStillSafe(item,
                                              allowedPaths: allowedPaths,
                                              targetURL: targetURL) else {
                    failures.append(RemovalFailure(url: item.url,
                                                   reason: "删除前文件身份或路径发生变化"))
                    continue
                }
                do {
                    try fm.trashItem(at: item.url, resultingItemURL: nil)
                    freed += item.size
                } catch {
                    stubborn.append(item)
                }
            }

            // Items we lack rights for go through Finder, which shows the
            // administrator prompt and moves them to the Trash like a drag.
            let finderCandidates = stubborn.filter {
                Self.removalIsStillSafe($0, allowedPaths: allowedPaths, targetURL: targetURL)
            }
            let finderCandidateIDs = Set(finderCandidates.map(\.id))
            for item in stubborn where !finderCandidateIDs.contains(item.id) {
                failures.append(RemovalFailure(url: item.url,
                                               reason: "请求 Finder 前文件身份或路径发生变化"))
            }
            if !finderCandidates.isEmpty {
                let finderError = Self.finderQueue.sync {
                    Self.trashViaFinder(finderCandidates.map(\.url))
                }
                for item in finderCandidates {
                    if fm.fileExists(atPath: item.url.path) {
                        failures.append(RemovalFailure(
                            url: item.url,
                            reason: finderError ?? "Finder 未移动该项目，可能已取消授权"
                        ))
                    } else {
                        freed += item.size
                    }
                }
            }

            DispatchQueue.main.async {
                guard let self, self.phase == .removing else { return }
                self.items = []
                self.removalFailures = failures
                self.phase = .done(freed: freed, failed: failures.count)
            }
        }
    }

    /// Asks Finder to trash `urls` in one batch via in-process Apple Events.
    /// Finder owns the privilege elevation (the administrator prompt); a cancel
    /// simply leaves the items in place.
    nonisolated private static func trashViaFinder(_ urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        let targets = urls
            .map { "set end of targets to POSIX file \(literal($0.path))" }
            .joined(separator: "\n")
        let source = """
        set targets to {}
        \(targets)
        tell application "Finder" to delete targets
        """
        guard let script = NSAppleScript(source: source) else { return "无法创建 Finder 删除请求" }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }
        let message = errorInfo[NSAppleScript.errorMessage] as? String
        let number = errorInfo[NSAppleScript.errorNumber] as? Int
        if let message, let number { return "Finder 错误 \(number)：\(message)" }
        return message ?? "Finder 拒绝了删除请求"
    }

    nonisolated private static func literal(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Scanning

    nonisolated private static func collect(bundleID: String, appURL: URL) -> [Leftover] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let lib = home + "/Library"
        var paths: [(URL, Category)] = [(appURL, .app)]
        // One traversal collects nested bundle IDs and allocated size. Large
        // application bundles (Xcode, games) previously walked every file twice.
        let appScan = scanAppBundle(appURL, primaryBundleID: bundleID, fm: fm)
        let bundleIDs = appScan.bundleIDs

        func add(_ path: String, _ category: Category) {
            let url = URL(fileURLWithPath: path)
            if fm.fileExists(atPath: url.path) { paths.append((url, category)) }
        }
        func addMatches(in dir: String, _ category: Category, where matches: (String) -> Bool) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for entry in entries where matches(entry) {
                paths.append((URL(fileURLWithPath: dir).appendingPathComponent(entry), category))
            }
        }

        for id in bundleIDs {
            add("\(lib)/Application Support/\(id)", .support)
            add("\(lib)/Containers/\(id)", .containers)
            add("\(lib)/Caches/\(id)", .caches)
            add("\(lib)/Preferences/\(id).plist", .preferences)
            add("\(lib)/Saved Application State/\(id).savedState", .state)
            add("\(lib)/HTTPStorages/\(id)", .caches)
            add("\(lib)/HTTPStorages/\(id).binarycookies", .caches)
            add("\(lib)/WebKit/\(id)", .caches)
            add("\(lib)/Application Scripts/\(id)", .containers)
            add("\(lib)/Cookies/\(id).binarycookies", .caches)
            add("\(lib)/Logs/\(id)", .logs)
            add("/Library/Application Support/\(id)", .support)
            add("/Library/Caches/\(id)", .caches)
            add("/Library/Preferences/\(id).plist", .preferences)
            add("/Library/PrivilegedHelperTools/\(id)", .other)
        }

        addMatches(in: "\(lib)/Preferences/ByHost", .preferences) {
            UninstallerSupport.matchesByHostPreference($0, bundleIDs: bundleIDs)
        }
        addMatches(in: "\(lib)/Group Containers", .containers) {
            UninstallerSupport.matchesGroupContainer($0, bundleIDs: bundleIDs)
        }
        for directory in ["\(lib)/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            addMatches(in: directory, .other) {
                UninstallerSupport.matchesLaunchItem($0, bundleIDs: bundleIDs)
            }
        }

        let deepCandidates = UninstallerSupport.exactDeepCandidates(
            home: URL(fileURLWithPath: home, isDirectory: true),
            bundleIDs: bundleIDs,
            darwinCache: darwinUserDirectory(_CS_DARWIN_USER_CACHE_DIR),
            darwinTemp: darwinUserDirectory(_CS_DARWIN_USER_TEMP_DIR)
        )
        for candidate in deepCandidates {
            add(candidate.url.path, candidate.kind == .support ? .support : .caches)
        }

        let appPath = appURL.standardizedFileURL.path
        let allowedRoots = scanRoots(home: home)
        let safe = dedupe(paths).filter { url, _ in
            let path = url.standardizedFileURL.path
            if path == appPath { return true }
            guard let root = allowedRoots.first(where: { path.hasPrefix($0.path + "/") }) else { return false }
            return !hasSymbolicLinkInParents(of: url, through: root)
        }
        return safe
            .compactMap { url, category in
                guard let identity = UninstallerSupport.fileIdentity(at: url) else { return nil }
                let size = url.standardizedFileURL.path == appPath
                    ? appScan.allocatedSize
                    : directorySize(of: url, fm: fm)
                return Leftover(url: url,
                                category: category,
                                size: size,
                                identity: identity)
            }
            .sorted {
                if $0.category.sortRank != $1.category.sortRank {
                    return $0.category.sortRank < $1.category.sortRank
                }
                return $0.size > $1.size
            }
    }

    nonisolated private static func removalIsStillSafe(_ item: Leftover,
                                           allowedPaths: Set<String>,
                                           targetURL: URL?) -> Bool {
        let url = item.url
        let path = url.standardizedFileURL.path
        guard allowedPaths.contains(path),
              let targetURL,
              UninstallerSupport.fileIdentity(at: url) == item.identity else { return false }
        if path == targetURL.standardizedFileURL.path { return !isSymbolicLink(url) }
        guard let root = scanRoots(home: NSHomeDirectory()).first(where: {
            path.hasPrefix($0.path + "/")
        }) else { return false }
        return !hasSymbolicLinkInParents(of: url, through: root)
    }

    private struct AppBundleScan {
        var bundleIDs: Set<String>
        var allocatedSize: Int64
    }

    nonisolated private static func scanAppBundle(_ appURL: URL,
                                                  primaryBundleID: String,
                                                  fm: FileManager) -> AppBundleScan {
        var result = AppBundleScan(bundleIDs: [primaryBundleID], allocatedSize: 0)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        guard let enumerator = fm.enumerator(at: appURL,
                                             includingPropertiesForKeys: Array(keys),
                                             options: [],
                                             errorHandler: nil) else { return result }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            result.allocatedSize += Int64(
                values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            )
            guard values?.isDirectory == true,
                  ["app", "appex", "xpc", "plugin", "bundle"].contains(url.pathExtension.lowercased()),
                  let id = UninstallerSupport.verifiedBundleID(Bundle(url: url)?.bundleIdentifier),
                  id.hasPrefix(primaryBundleID + ".") else { continue }
            result.bundleIDs.insert(id)
        }
        return result
    }

    nonisolated private static func scanRoots(home: String) -> [URL] {
        var roots = [
            URL(fileURLWithPath: home + "/Library", isDirectory: true),
            URL(fileURLWithPath: "/Library", isDirectory: true),
            URL(fileURLWithPath: home + "/.config", isDirectory: true),
            URL(fileURLWithPath: home + "/.cache", isDirectory: true),
            URL(fileURLWithPath: home + "/.local/share", isDirectory: true),
        ]
        if let cache = darwinUserDirectory(_CS_DARWIN_USER_CACHE_DIR) { roots.append(cache) }
        if let temp = darwinUserDirectory(_CS_DARWIN_USER_TEMP_DIR) { roots.append(temp) }
        return roots.map(\.standardizedFileURL)
    }

    nonisolated private static func darwinUserDirectory(_ name: Int32) -> URL? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    nonisolated private static func hasSymbolicLinkInParents(of url: URL, through root: URL) -> Bool {
        var current = url.deletingLastPathComponent().standardizedFileURL
        let root = root.standardizedFileURL
        while current.path.count >= root.path.count {
            if isSymbolicLink(current) { return true }
            if current.path == root.path { return false }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return true }
            current = parent
        }
        return true
    }

    nonisolated private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    nonisolated private static func dedupe(_ paths: [(URL, Category)]) -> [(URL, Category)] {
        var seen = Set<String>()
        var roots: [String] = []
        var out: [(URL, Category)] = []
        for (url, category) in paths.sorted(by: { $0.0.path.count < $1.0.path.count }) {
            let path = url.standardizedFileURL.path
            if seen.contains(path) { continue }
            if roots.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            seen.insert(path)
            roots.append(path)
            out.append((url, category))
        }
        return out
    }

    nonisolated private static func directorySize(of url: URL, fm: FileManager) -> Int64 {
        if isSymbolicLink(url) { return fileSize(url) }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return fileSize(url) }

        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: url,
                                          includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                                          options: [], errorHandler: nil) {
            for case let item as URL in enumerator {
                if isSymbolicLink(item) { continue }
                total += fileSize(item)
            }
        }
        return total
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }
}
