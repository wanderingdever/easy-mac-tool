import Darwin
import Foundation

/// Foundational ownership rules for the Uninstaller. Every deeper location is
/// derived from a verified bundle identifier; display names never become paths.
nonisolated enum UninstallerSupport {
    struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let fileType: UInt16
    }

    static func fileIdentity(at url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        guard type != S_IFLNK else { return nil }
        return FileIdentity(device: UInt64(info.st_dev),
                            inode: UInt64(info.st_ino),
                            fileType: UInt16(type))
    }

    /// Returns true when deleting the item is likely to require an elevated
    /// operation. System-owned roots are treated as protected even when an
    /// individual file happens to be user-owned, because their parent cannot
    /// be modified by the current user.
    static func requiresPrivilege(at url: URL,
                                  currentUID: uid_t = getuid()) -> Bool {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/Applications/") || path.hasPrefix("/Library/") {
            return true
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { return true }
        return info.st_uid != currentUID
    }

    static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/")
    }
    nonisolated enum Kind: Equatable, Sendable {
        case support, caches
    }

    nonisolated struct Candidate: Equatable, Sendable {
        let url: URL
        let kind: Kind
    }

    /// Returns a bundle identifier only when it looks like a real, non-protected
    /// bundle ID. Anything else (nil, a bare display name, a system identifier)
    /// is rejected so it can never become a path component.
    static func verifiedBundleID(_ rawValue: String?) -> String? {
        guard let rawValue,
              looksLikeBundleID(rawValue),
              !isProtectedBundleID(rawValue) else { return nil }
        return rawValue
    }

    static func isNestedBundle(_ candidateURL: URL?, in appURL: URL) -> Bool {
        guard let candidateURL else { return false }
        return isDescendant(candidateURL, of: appURL)
    }

    static func exactDeepCandidates(home: URL,
                                    bundleIDs: Set<String>,
                                    darwinCache: URL?,
                                    darwinTemp: URL?) -> [Candidate] {
        var result: [Candidate] = []
        for id in bundleIDs.sorted() {
            result.append(Candidate(url: home.appendingPathComponent(".config/").appendingPathComponent(id),
                                    kind: .support))
            result.append(Candidate(url: home.appendingPathComponent(".cache/").appendingPathComponent(id),
                                    kind: .caches))
            result.append(Candidate(url: home.appendingPathComponent(".local/share/").appendingPathComponent(id),
                                    kind: .support))
            if let darwinCache {
                result.append(Candidate(url: darwinCache.appendingPathComponent(id), kind: .caches))
            }
            if let darwinTemp {
                result.append(Candidate(url: darwinTemp.appendingPathComponent(id), kind: .caches))
            }
        }
        return result
    }

    static func matchesByHostPreference(_ name: String, bundleIDs: Set<String>) -> Bool {
        guard name.hasSuffix(".plist"), name.contains("-") else { return false }
        return bundleIDs.contains { name.hasPrefix("\($0).") }
    }

    static func matchesGroupContainer(_ name: String, bundleIDs: Set<String>) -> Bool {
        bundleIDs.contains(name) || bundleIDs.contains { name == "group.\($0)" }
    }

    static func matchesLaunchItem(_ name: String, bundleIDs: Set<String>) -> Bool {
        bundleIDs.contains { name == "\($0).plist" }
    }

    /// A bundle ID uses reverse-DNS style: at least two dot-separated segments
    /// made of alphanumerics, hyphens and dots; no leading/trailing dot.
    static func looksLikeBundleID(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        guard !trimmed.hasPrefix("."), !trimmed.hasSuffix(".") else { return false }
        let segments = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { !$0.isEmpty }
    }

    /// System/protected bundle identifiers are never eligible for removal.
    static func isProtectedBundleID(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower == "com.apple"
            || lower.hasPrefix("com.apple.")
            || lower == "com.opensource"
            || lower.hasPrefix("com.opensource.")
            || lower == "org.gnu"
            || lower.hasPrefix("org.gnu.")
    }
}
