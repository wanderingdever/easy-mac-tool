import Foundation

/// Foundational ownership rules for the Uninstaller. Every deeper location is
/// derived from a verified bundle identifier; display names never become paths.
enum UninstallerSupport {
    enum Kind: Equatable {
        case support, caches
    }

    struct Candidate: Equatable {
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
        let appPath = appURL.standardizedFileURL.path
        let candidatePath = candidateURL.standardizedFileURL.path
        return candidatePath.hasPrefix(appPath + "/")
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
        let segments = trimmed.split(separator: ".")
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { !$0.isEmpty }
    }

    /// System/protected bundle identifiers are never eligible for removal.
    static func isProtectedBundleID(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.hasPrefix("com.apple.")
            || lower.hasPrefix("com.opensource.")
            || lower.hasPrefix("org.gnu.")
    }
}