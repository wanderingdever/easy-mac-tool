import Combine
import CoreGraphics
import Foundation

/// App-wide settings, persisted to `UserDefaults` as JSON. Shared with both the
/// SwiftUI settings window (via `@EnvironmentObject`) and the runtime services
/// (`HotkeyManager`, `WindowEnumerator`, `ScreenCaptureManager`).
final class AppSettings: ObservableObject {
    @Published var previewSize: PreviewSize = .small { didSet { persist() } }
    @Published var shortcuts: [ShortcutConfig] = ShortcutConfig.defaults { didSet { persist() } }
    /// Global hotkey to summon the clipboard history panel.
    @Published var clipboardShortcut: ShortcutConfig = AppSettings.defaultClipboardShortcut { didSet { persist() } }
    /// Max number of clipboard entries to keep.
    @Published var clipboardHistoryLimit: Int = 100 { didSet { persist() } }
    /// When true, re-selecting a clipboard item auto-pastes into the previously
    /// frontmost app (Paste-style). When false, only copies back to clipboard.
    @Published var clipboardAutoPaste: Bool = true { didSet { persist() } }

    private let defaults = UserDefaults.standard
    private let storageKey = "appSettings.v1"

    init() { load() }

    /// Shared 单例：供 AppDelegate 在 applicationDidFinishLaunching 中
    /// 直接创建 AppCoordinator 使用，与 SwiftUI @StateObject 持有的
    /// 是同一实例，保证设置变更实时同步到 HotkeyManager。
    static let shared = AppSettings()

    /// Default clipboard hotkey: Cmd+Shift+V.
    static let defaultClipboardShortcut = ShortcutConfig(
        name: "剪切板",
        keyCode: 0x09,                   // V
        modifiers: [.maskCommand, .maskShift],
        isDefault: true
    )

    enum PreviewSize: String, Codable, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .small: return "小"
            case .medium: return "中"
            case .large: return "大"
            }
        }
        var thumbnailWidth: CGFloat {
            switch self {
            case .small: return 180
            case .medium: return 260
            case .large: return 360
            }
        }
        var thumbnailHeight: CGFloat {
            switch self {
            case .small: return 120
            case .medium: return 170
            case .large: return 230
            }
        }
        var captureScale: Double {
            switch self {
            case .small: return 0.18
            case .medium: return 0.28
            case .large: return 0.40
            }
        }
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var previewSize: PreviewSize
        var shortcuts: [ShortcutConfig]
        var clipboardShortcut: ShortcutConfig?
        var clipboardHistoryLimit: Int?
        var clipboardAutoPaste: Bool?
    }

    private func persist() {
        let snapshot = Persisted(
            previewSize: previewSize,
            shortcuts: shortcuts,
            clipboardShortcut: clipboardShortcut,
            clipboardHistoryLimit: clipboardHistoryLimit,
            clipboardAutoPaste: clipboardAutoPaste
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        previewSize = snapshot.previewSize
        shortcuts = snapshot.shortcuts
        if let cs = snapshot.clipboardShortcut { clipboardShortcut = cs }
        if let limit = snapshot.clipboardHistoryLimit { clipboardHistoryLimit = limit }
        if let autoPaste = snapshot.clipboardAutoPaste { clipboardAutoPaste = autoPaste }
    }
}
