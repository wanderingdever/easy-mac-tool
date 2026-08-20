import CoreGraphics
import Foundation

/// Minimal dynamic bridge to SkyLight for per-window Space membership.
/// Loaded at runtime so the app does not link against a private framework.
nonisolated enum SkyLightSpaces {
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )

    private typealias MainConnectionFn = @convention(c) () -> UInt32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let mainConnectionID: UInt32 = {
        guard let handle, let symbol = dlsym(handle, "CGSMainConnectionID") else { return 0 }
        let fn = unsafeBitCast(symbol, to: MainConnectionFn.self)
        return fn()
    }()

    static var isAvailable: Bool {
        handle != nil && mainConnectionID != 0
    }

    /// Space IDs currently visible on any display. Empty when the private API
    /// is unavailable or the current Space cannot be read.
    static func visibleSpaceIDs() -> Set<UInt64> {
        guard isAvailable,
              let symbol = handle.flatMap({ dlsym($0, "CGSCopyManagedDisplaySpaces") }) else {
            return []
        }
        let fn = unsafeBitCast(symbol, to: CopyManagedDisplaySpacesFn.self)
        guard let displays = fn(mainConnectionID)?.takeRetainedValue() as? [NSDictionary] else {
            return []
        }

        var result = Set<UInt64>()
        for display in displays {
            guard let current = display["Current Space"] as? NSDictionary,
                  let id = current["id64"] as? UInt64 else { continue }
            result.insert(id)
        }
        return result
    }

    /// Space IDs for each requested window, in the same order as `wids`.
    /// Windows with no readable membership return an empty set.
    static func spaceIDs(forWindowIDs wids: [CGWindowID]) -> [Set<UInt64>] {
        guard isAvailable, !wids.isEmpty,
              let symbol = handle.flatMap({ dlsym($0, "CGSCopySpacesForWindows") }) else {
            return Array(repeating: [], count: wids.count)
        }
        let fn = unsafeBitCast(symbol, to: CopySpacesForWindowsFn.self)
        let windowNumbers = wids.map { NSNumber(value: $0) } as CFArray
        guard let raw = fn(mainConnectionID, 7, windowNumbers)?.takeRetainedValue() as? [Any] else {
            return Array(repeating: [], count: wids.count)
        }

        return raw.map { element in
            guard let spaces = element as? [Any] else { return [] }
            return Set(spaces.compactMap { ($0 as? NSNumber)?.uint64Value })
        }
    }
}
