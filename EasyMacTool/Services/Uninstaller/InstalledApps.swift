import AppKit

/// Lookups for resolving installed applications — used by the uninstaller's
/// app picker.
enum InstalledApps {
    /// 缓存的非系统应用列表（含 sizeBytes 计算），避免每次进入都重新扫描。
    private static var cachedInstalledApplications: [InstalledApp]?

    /// 清空缓存，强制下次调用重新扫描。
    static func invalidateInstalledApplicationsCache() {
        cachedInstalledApplications = nil
    }

    struct InstalledApp: Identifiable, Equatable {
        let id: String
        let name: String
        let bundleID: String?
        let url: URL
        let isSystem: Bool
        let sizeBytes: Int64

        var icon: NSImage {
            NSWorkspace.shared.icon(forFile: url.path)
        }
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

    static func installedApplications(includeSystemApplications: Bool = false) -> [InstalledApp] {
        if !includeSystemApplications, let cached = cachedInstalledApplications {
            return cached
        }
        let fm = FileManager.default
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
        ]
        if includeSystemApplications {
            roots.append(URL(fileURLWithPath: "/System/Applications", isDirectory: true))
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        for root in roots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(at: root,
                                                 includingPropertiesForKeys: keys,
                                                 options: [.skipsPackageDescendants]) else {
                continue
            }
            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }
                let resolved = url.resolvingSymlinksInPath()
                let isSystemApp = isSystemApplication(at: url)
                guard includeSystemApplications || !isSystemApp else { continue }
                guard seen.insert(resolved.standardizedFileURL.path).inserted else { continue }
                apps.append(app(at: url, fileManager: fm))
            }
        }

        let result = apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if !includeSystemApplications {
            cachedInstalledApplications = result
        }
        return result
    }

    private static func app(at url: URL, fileManager fm: FileManager) -> InstalledApp {
        var name = fm.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return InstalledApp(id: url.standardizedFileURL.path,
                            name: name,
                            bundleID: Bundle(url: url)?.bundleIdentifier,
                            url: url,
                            isSystem: isSystemApplication(at: url),
                            sizeBytes: directorySize(of: url, fileManager: fm))
    }

    /// 递归计算目录（或单文件）的占用字节数。用于展示应用包占用的存储。
    private static func directorySize(of url: URL, fileManager fm: FileManager) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            return fileSize(url)
        }
        if !isDir.boolValue { return fileSize(url) }

        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: url,
                                          includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                                          options: [], errorHandler: nil) {
            for case let item as URL in enumerator {
                if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                total += fileSize(item)
            }
        }
        return total
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }
}