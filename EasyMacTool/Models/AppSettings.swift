import Combine
import CoreGraphics
import Foundation
import os

/// App-wide settings, persisted to `UserDefaults` as JSON. Shared with both the
/// SwiftUI settings window (via `@EnvironmentObject`) and the runtime services
/// (`HotkeyManager`, `WindowEnumerator`, `ScreenCaptureManager`).
@MainActor
final class AppSettings: ObservableObject {
    private static let logger = Logger(subsystem: "com.easymactool", category: "AppSettings")
    /// Which screen the switcher panel appears on (global — applies to all
    /// shortcuts). Per-shortcut preview size lives on `ShortcutConfig`.
    @Published var displayTarget: DisplayTarget = .active { didSet { debouncePersist() } }
    @Published var shortcuts: [ShortcutConfig] = ShortcutConfig.defaults { didSet { debouncePersist() } }
    /// Global hotkey to summon the clipboard history panel.
    @Published var clipboardShortcut: ShortcutConfig = AppSettings.defaultClipboardShortcut { didSet { debouncePersist() } }
    /// Max number of clipboard entries to keep.
    @Published var clipboardHistoryLimit: Int = 100 { didSet { debouncePersist() } }
    /// When true, re-selecting a clipboard item auto-pastes into the previously
    /// frontmost app (Paste-style). When false, only copies back to clipboard.
    @Published var clipboardAutoPaste: Bool = true { didSet { debouncePersist() } }
    /// Lets users suspend clipboard observation without quitting the app.
    @Published var clipboardCapturingEnabled: Bool = true { didSet { debouncePersist() } }
    /// 链接预览：开启后对复制的 http/https URL 后台抓取网页标题与站点图标
    /// （类 Paste 链接卡片）。默认关闭——复制私有/带 token 的链接时 app 主动
    /// 访问可能触发服务端副作用或泄露信息，需用户明确知情开启。
    @Published var clipboardLinkPreviewEnabled: Bool = false { didSet { debouncePersist() } }

    private let defaults = UserDefaults.standard
    private let storageKey = "appSettings.v1"
    /// 防抖 persist：0.5 秒内多次变更只执行最后一次，避免在视图更新周期中
    /// 同步 IO 以及频繁 persist 的性能开销。
    private var persistWorkItem: DispatchWorkItem?

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

    /// Reject duplicate global shortcut combinations before they reach the
    /// event tap, where one action would otherwise silently shadow another.
    func shortcutConflictMessage(keyCode: CGKeyCode,
                                modifiers: CGEventFlags,
                                excludingWindowShortcutID: UUID? = nil,
                                includeClipboardShortcut: Bool = true) -> String? {
        // 系统保留组合校验优先于内部冲突：event tap 是 .defaultTap，匹配成功
        // 会 return nil 吞掉事件。若允许录制 Cmd+Q 等系统关键组合，所有 app
        // 的对应功能被全局劫持且极难排查到本 app。
        if Self.isReservedSystemCombo(keyCode: keyCode, modifiers: modifiers) {
            return "系统保留快捷键，不可使用"
        }
        if let existing = shortcuts.first(where: {
            $0.id != excludingWindowShortcutID &&
            $0.keyCode == keyCode &&
            $0.modifiers == modifiers
        }) {
            return "已被窗口切换快捷键「\(existing.name)」使用"
        }
        if includeClipboardShortcut,
           clipboardShortcut.keyCode == keyCode,
           clipboardShortcut.modifiers == modifiers {
            return "已被剪切板快捷键使用"
        }
        return nil
    }

    /// 系统关键组合：不允许录制为全局快捷键。
    /// CGEventTap 匹配成功后会吞掉事件（return nil），录制这些组合会导致
    /// 所有 app 的退出/关窗/隐藏/Spotlight/强制退出/截图快捷键全局失效。
    private static let reservedSystemCombos: [(keyCode: CGKeyCode, modifiers: CGEventFlags)] = [
        (0x0C, .maskCommand),                          // Cmd+Q 退出
        (0x0D, .maskCommand),                          // Cmd+W 关窗
        (0x04, .maskCommand),                          // Cmd+H 隐藏
        (0x2E, .maskCommand),                          // Cmd+M 最小化
        (0x31, .maskCommand),                          // Cmd+Space Spotlight
        (0x35, [.maskCommand, .maskAlternate]),        // Cmd+Option+Esc 强制退出
        (0x14, [.maskCommand, .maskShift]),            // Cmd+Shift+3 全屏截图
        (0x15, [.maskCommand, .maskShift]),            // Cmd+Shift+4 区域截图
        (0x17, [.maskCommand, .maskShift]),            // Cmd+Shift+5 截图工具
    ]

    /// 判断给定组合是否为系统保留快捷键。HotkeyManager.matchShortcut 也用
    /// 此做防御性排除：即使旧版本设置中已存留了保留组合，也不匹配不吞键。
    static func isReservedSystemCombo(keyCode: CGKeyCode, modifiers: CGEventFlags) -> Bool {
        reservedSystemCombos.contains { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }

    /// Which screen the switcher panel appears on.
    enum DisplayTarget: String, Codable, CaseIterable, Identifiable {
        case active   // 活跃屏幕（键盘焦点所在）
        case mouse    // 包含鼠标的屏幕
        case menuBar  // 包含菜单栏的屏幕（主屏幕）
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .active:  return "活跃屏幕"
            case .mouse:   return "包含鼠标的屏幕"
            case .menuBar:  return "包含菜单栏的屏幕"
            }
        }
    }

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

    private func debouncePersist() {
        persistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.persist()
        }
        persistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private struct Persisted: Codable {
        var displayTarget: DisplayTarget?
        var shortcuts: [ShortcutConfig]
        var clipboardShortcut: ShortcutConfig?
        var clipboardHistoryLimit: Int?
        var clipboardAutoPaste: Bool?
        var clipboardCapturingEnabled: Bool?
        var clipboardLinkPreviewEnabled: Bool?
    }

    private func persist() {
        let snapshot = Persisted(
            displayTarget: displayTarget,
            shortcuts: shortcuts,
            clipboardShortcut: clipboardShortcut,
            clipboardHistoryLimit: clipboardHistoryLimit,
            clipboardAutoPaste: clipboardAutoPaste,
            clipboardCapturingEnabled: clipboardCapturingEnabled,
            clipboardLinkPreviewEnabled: clipboardLinkPreviewEnabled
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            let snapshot = try JSONDecoder().decode(Persisted.self, from: data)
            if let dt = snapshot.displayTarget { displayTarget = dt }
            // 空数组时回退到默认快捷键，避免切换器再也呼不出来
            shortcuts = snapshot.shortcuts.isEmpty ? ShortcutConfig.defaults : snapshot.shortcuts
            if let cs = snapshot.clipboardShortcut { clipboardShortcut = cs }
            if let limit = snapshot.clipboardHistoryLimit { clipboardHistoryLimit = limit }
            if let autoPaste = snapshot.clipboardAutoPaste { clipboardAutoPaste = autoPaste }
            if let capturingEnabled = snapshot.clipboardCapturingEnabled {
                clipboardCapturingEnabled = capturingEnabled
            }
            if let linkPreview = snapshot.clipboardLinkPreviewEnabled {
                clipboardLinkPreviewEnabled = linkPreview
            }
        } catch {
            Self.logger.error("Failed to decode persisted settings: \(error.localizedDescription, privacy: .public). Using defaults.")
        }
    }
}
