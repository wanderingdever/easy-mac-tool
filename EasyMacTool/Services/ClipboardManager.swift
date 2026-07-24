import AppKit
import Combine
import CoreGraphics
import Foundation

/// Monitors the system pasteboard and maintains a clipboard history list.
///
/// Strategy: poll `NSPasteboard.general.changeCount` on a 0.5s timer. When it
/// changes, snapshot the current contents into a `ClipboardItem` and prepend
/// to history. Dedupes consecutive identical entries. Skips items that this
/// manager itself just wrote (to avoid feedback loops when re-pasting).
@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var isCapturing = true

    /// Configured maximum history length. Older entries are dropped.
    var historyLimit: Int = 100

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    /// Suppress the next capture cycle after we re-paste an item so we don't
    /// immediately re-add the same payload as a "new" entry.
    private var suppressNextCapture = false
    /// Guards against concurrent snapshots — if a poll is already in progress,
    /// skip the next one instead of piling up Tasks.
    private var isSnapshotting = false

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let instance = self
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in instance.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-pastes the given item: writes it to the pasteboard and (optionally)
    /// simulates Cmd+V into the previously frontmost app.
    func reapply(_ item: ClipboardItem, autoPaste: Bool) {
        suppressNextCapture = true
        item.write(to: .general)
        // Move the item to the top so it's most-recently-used.
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            let moved = items.remove(at: idx)
            items.insert(moved, at: 0)
        }
        if autoPaste {
            // Re-activate the previous frontmost app and send Cmd+V. We
            // dispatch async so the pasteboard write completes first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.simulatePaste()
            }
        }
    }

    func clearHistory() {
        items.removeAll()
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
    }

    /// Removes entries whose `createdAt` is older than the given number of
    /// days. Used by the settings page's "删除7天前记录" action.
    func removeOlderThan(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        items.removeAll { $0.createdAt < cutoff }
    }

    // MARK: - Polling

    private func poll() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if suppressNextCapture {
            suppressNextCapture = false
            return
        }

        // Skip if a previous snapshot is still running (e.g. large image).
        guard !isSnapshotting else { return }
        isSnapshotting = true
        defer { isSnapshotting = false }

        // Quick type check before expensive readObjects call.
        guard let types = pb.types, !types.isEmpty else { return }
        let hasURL = types.contains(.URL)
        let hasString = types.contains(.string)
        let hasTIFF = types.contains(.tiff)
        let hasFileURL = types.contains(.fileURL)
        guard hasURL || hasString || hasTIFF || hasFileURL else { return }

        guard let item = snapshot() else { return }
        // Dedupe consecutive identical entries (common with apps that write
        // multiple pasteboard types at once but with the same logical content).
        if let first = items.first, isSamePayload(first, item) {
            return
        }
        items.insert(item, at: 0)
        if items.count > historyLimit {
            items.removeLast(items.count - historyLimit)
        }
    }

    /// Snapshots whatever is currently on the pasteboard into a ClipboardItem.
    /// Also captures the frontmost app's icon/name/tint so the card header can
    /// show its origin.
    private func snapshot() -> ClipboardItem? {
        let pb = NSPasteboard.general
        let (appName, appIcon, appTint) = captureSourceApp()

        // File URLs take priority — copy/paste of Finder selections.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            return ClipboardItem(kind: .file(URLs: urls),
                                 sourceAppIcon: appIcon,
                                 sourceAppName: appName,
                                 sourceAppTint: appTint)
        }

        // Images.
        if let tiff = pb.data(forType: .tiff),
           let image = NSImage(data: tiff) {
            return ClipboardItem(kind: .image(image),
                                 sourceAppIcon: appIcon,
                                 sourceAppName: appName,
                                 sourceAppTint: appTint)
        }

        // URLs with a string companion.
        if let urlStr = pb.string(forType: .URL),
           let url = URL(string: urlStr) {
            return ClipboardItem(kind: .url(url, title: url.host),
                                 sourceAppIcon: appIcon,
                                 sourceAppName: appName,
                                 sourceAppTint: appTint)
        }

        // Plain text (also catches URLs copied as plain text).
        if let text = pb.string(forType: .string) {
            // 捕获 RTF 富文本数据（若来源应用支持）。VSCode/Xcode 等代码
            // 编辑器复制时会写入 RTF 类型，保留语法高亮颜色。
            let rtfData = pb.data(forType: .rtf)
            // Heuristic: looks like a color string (#RRGGBB / rgb() / hsl()) —
            // render as a color card.
            if let (color, hex) = ColorStringParser.parse(text) {
                return ClipboardItem(kind: .color(color, hex: hex),
                                     sourceAppIcon: appIcon,
                                     sourceAppName: appName,
                                     sourceAppTint: appTint)
            }
            // Heuristic: looks like a URL — render as a URL card.
            if let url = URL(string: text),
               let scheme = url.scheme,
               scheme == "http" || scheme == "https" {
                return ClipboardItem(kind: .url(url, title: url.host),
                                     sourceAppIcon: appIcon,
                                     sourceAppName: appName,
                                     sourceAppTint: appTint)
            }
            return ClipboardItem(kind: .text(text),
                                 sourceAppIcon: appIcon,
                                 sourceAppName: appName,
                                 sourceAppTint: appTint,
                                 rtfData: rtfData)
        }

        return nil
    }

    /// Captures the currently frontmost app's icon, name, and accent tint
    /// so the card header can show the source. Returns nil icon/empty name
    /// if no app is available (e.g. menu-bar-only state).
    private func captureSourceApp() -> (String?, NSImage?, NSColor) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let name = frontmost?.localizedName
        // Safe sRGB fallback — avoids catalog-color component crashes.
        var icon: NSImage?
        var tint: NSColor = NSColor(red: 0x0A/255.0, green: 0x84/255.0, blue: 0xFF/255.0, alpha: 1.0)
        if let app = frontmost, let appIcon = app.icon {
            icon = appIcon
            tint = AppTintExtractor.tint(from: appIcon, bundleIdentifier: app.bundleIdentifier)
        }
        return (name, icon, tint)
    }

    private func isSamePayload(_ a: ClipboardItem, _ b: ClipboardItem) -> Bool {
        switch (a.kind, b.kind) {
        case (.text(let x), .text(let y)): return x == y
        case (.url(let x, _), .url(let y, _)): return x == y
        case (.image(let x), .image(let y)):
            return x.size == y.size && x.tiffRepresentation == y.tiffRepresentation
        case (.file(let x), .file(let y)):
            return x == y
        case (.color(_, let h1), .color(_, let h2)):
            return h1 == h2
        default: return false
        }
    }

    /// Simulates Cmd+V into the previously frontmost app. The clipboard panel
    /// must be dismissed BEFORE calling this so the target app receives focus.
    fileprivate func simulatePaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)  // V
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        cmdUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
