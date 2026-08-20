import CoreGraphics
import Foundation

nonisolated enum SwitcherAppsToShow: String, Codable, CaseIterable, Identifiable {
    case all
    case active
    case nonActive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "全部应用"
        case .active: return "仅活跃应用"
        case .nonActive: return "非活跃应用"
        }
    }
}

nonisolated enum SwitcherWindowOrder: String, Codable, CaseIterable, Identifiable {
    case recentlyFocused
    case alphabetical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recentlyFocused: return "最近聚焦"
        case .alphabetical: return "字母顺序"
        }
    }
}

nonisolated enum SwitcherScreensToShow: String, Codable, CaseIterable, Identifiable {
    case all
    case showingSwitcher

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "所有屏幕"
        case .showingSwitcher: return "切换器所在屏幕"
        }
    }
}

nonisolated enum SwitcherTabGrouping: String, Codable, CaseIterable, Identifiable {
    case singleWindow
    case separateWindows

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .singleWindow: return "合并同标题窗口"
        case .separateWindows: return "显示为独立窗口"
        }
    }
}

/// One configurable global shortcut. Each shortcut has its own key combo,
/// window filter set, and release behavior.
struct ShortcutConfig: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var keyCode: CGKeyCode
    /// Stored as `UInt64` (CGEventFlags.rawValue) for Codable synthesis.
    var modifiersRaw: UInt64
    var showMinimized: Bool
    var showHidden: Bool
    var showFullscreen: Bool
    var showWindowless: Bool
    /// 仅显示当前桌面（Space）的窗口。默认 true：切换器只列当前桌面可见窗口，
    /// 剔除其他桌面上的窗口。关闭后 `onScreenWindowsOnly=false`，可跨桌面切换。
    var currentSpaceOnly: Bool
    /// 每个应用只显示一个主窗口（优先当前聚焦窗口）。
    var showMainWindowOnly: Bool
    var screensToShow: SwitcherScreensToShow
    var tabGrouping: SwitcherTabGrouping
    var releaseBehavior: ReleaseBehavior
    /// Per-shortcut preview thumbnail size. Different shortcuts can use
    /// different sizes — e.g. a primary shortcut uses small previews while
    /// a secondary shortcut uses large ones.
    var previewSize: AppSettings.PreviewSize
    var appsToShow: SwitcherAppsToShow
    var windowOrder: SwitcherWindowOrder
    /// Default shortcuts cannot be renamed or deleted.
    var isDefault: Bool

    /// What to do when the hold-modifier is released while the switcher is open.
    enum ReleaseBehavior: String, Codable, CaseIterable, Identifiable {
        case focus   // 释放后聚焦
        case hold    // 按住（需按 Enter 确认）
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .focus: return "释放后聚焦"
            case .hold: return "按住（Enter 确认）"
            }
        }
    }

    init(id: UUID = UUID(),
         name: String,
         keyCode: CGKeyCode,
         modifiers: CGEventFlags,
         showMinimized: Bool = false,
         showHidden: Bool = false,
         showFullscreen: Bool = true,
         showWindowless: Bool = true,
         currentSpaceOnly: Bool = true,
         showMainWindowOnly: Bool = false,
         screensToShow: SwitcherScreensToShow = .all,
         tabGrouping: SwitcherTabGrouping = .singleWindow,
         releaseBehavior: ReleaseBehavior = .focus,
         previewSize: AppSettings.PreviewSize = .small,
         appsToShow: SwitcherAppsToShow = .all,
         windowOrder: SwitcherWindowOrder = .recentlyFocused,
         isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.keyCode = keyCode
        self.modifiersRaw = modifiers.rawValue
        self.showMinimized = showMinimized
        self.showHidden = showHidden
        self.showFullscreen = showFullscreen
        self.showWindowless = showWindowless
        self.currentSpaceOnly = currentSpaceOnly
        self.showMainWindowOnly = showMainWindowOnly
        self.screensToShow = screensToShow
        self.tabGrouping = tabGrouping
        self.releaseBehavior = releaseBehavior
        self.previewSize = previewSize
        self.appsToShow = appsToShow
        self.windowOrder = windowOrder
        self.isDefault = isDefault
    }

    var modifiers: CGEventFlags {
        get { CGEventFlags(rawValue: modifiersRaw) }
        set { modifiersRaw = newValue.rawValue }
    }

    // MARK: - Codable (backward compatibility)

    /// Custom decoder: tolerates persisted shortcuts from older versions that
    /// lack the `previewSize` field by falling back to `.small`.
    private enum CodingKeys: String, CodingKey {
        case id, name, keyCode, modifiersRaw
        case showMinimized, showHidden, showFullscreen, showWindowless, currentSpaceOnly, showMainWindowOnly, screensToShow, tabGrouping
        case releaseBehavior, previewSize, appsToShow, windowOrder, isDefault
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        keyCode = try c.decode(CGKeyCode.self, forKey: .keyCode)
        modifiersRaw = try c.decode(UInt64.self, forKey: .modifiersRaw)
        showMinimized = try c.decodeIfPresent(Bool.self, forKey: .showMinimized) ?? false
        showHidden = try c.decodeIfPresent(Bool.self, forKey: .showHidden) ?? false
        showFullscreen = try c.decodeIfPresent(Bool.self, forKey: .showFullscreen) ?? true
        showWindowless = try c.decodeIfPresent(Bool.self, forKey: .showWindowless) ?? true
        currentSpaceOnly = try c.decodeIfPresent(Bool.self, forKey: .currentSpaceOnly) ?? true
        showMainWindowOnly = try c.decodeIfPresent(Bool.self, forKey: .showMainWindowOnly) ?? false
        screensToShow = try c.decodeIfPresent(SwitcherScreensToShow.self, forKey: .screensToShow) ?? .all
        tabGrouping = try c.decodeIfPresent(SwitcherTabGrouping.self, forKey: .tabGrouping) ?? .singleWindow
        releaseBehavior = try c.decodeIfPresent(ReleaseBehavior.self, forKey: .releaseBehavior) ?? .focus
        previewSize = try c.decodeIfPresent(AppSettings.PreviewSize.self, forKey: .previewSize) ?? .small
        appsToShow = try c.decodeIfPresent(SwitcherAppsToShow.self, forKey: .appsToShow) ?? .all
        windowOrder = try c.decodeIfPresent(SwitcherWindowOrder.self, forKey: .windowOrder) ?? .recentlyFocused
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(modifiersRaw, forKey: .modifiersRaw)
        try c.encode(showMinimized, forKey: .showMinimized)
        try c.encode(showHidden, forKey: .showHidden)
        try c.encode(showFullscreen, forKey: .showFullscreen)
        try c.encode(showWindowless, forKey: .showWindowless)
        try c.encode(currentSpaceOnly, forKey: .currentSpaceOnly)
        try c.encode(showMainWindowOnly, forKey: .showMainWindowOnly)
        try c.encode(screensToShow, forKey: .screensToShow)
        try c.encode(tabGrouping, forKey: .tabGrouping)
        try c.encode(releaseBehavior, forKey: .releaseBehavior)
        try c.encode(previewSize, forKey: .previewSize)
        try c.encode(appsToShow, forKey: .appsToShow)
        try c.encode(windowOrder, forKey: .windowOrder)
        try c.encode(isDefault, forKey: .isDefault)
    }

    /// `true` for the Cmd+Shift+Tab-style backward variant (Shift is part of the
    /// configured modifiers). Forward variants return `false`.
    var isBackward: Bool { modifiers.contains(.maskShift) }

    /// A human-readable description of the key combo, e.g. "⌘⇥".
    var displayString: String { KeyComboFormatter.format(keyCode: keyCode, modifiers: modifiers) }

    /// Default presets so the switcher works out of the box. The first one is
    /// locked (cannot be renamed or deleted).
    static let defaults: [ShortcutConfig] = [
        ShortcutConfig(name: "默认",
                       keyCode: 0x30,         // Tab
                       modifiers: .maskCommand,
                       isDefault: true),
        ShortcutConfig(name: "快捷键 2",
                       keyCode: 0x30,         // Tab
                       modifiers: [.maskCommand, .maskShift])
    ]
}

/// Renders a (keyCode, modifiers) combo as a macOS-style label, e.g. "⌘⇥".
nonisolated enum KeyComboFormatter {
    static func format(keyCode: CGKeyCode, modifiers: CGEventFlags) -> String {
        var s = ""
        if modifiers.contains(.maskControl) { s += "⌃" }
        if modifiers.contains(.maskAlternate) { s += "⌥" }
        if modifiers.contains(.maskShift) { s += "⇧" }
        if modifiers.contains(.maskCommand) { s += "⌘" }
        s += label(for: keyCode)
        return s
    }

    private static func label(for code: CGKeyCode) -> String {
        switch code {
        case 0x30: return "⇥"
        case 0x24: return "↩"
        case 0x35: return "⎋"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x31: return "␣"
        default:
            if let value = UCKeyTranslateMapper.char(for: code),
               let scalar = Unicode.Scalar(value) {
                return String(scalar)
            }
            return "Key\(code)"
        }
    }
}

/// Bridges virtual key codes to a printable character without importing Carbon.
/// Covers the common letters / digits; everything else falls back to the raw code.
nonisolated private enum UCKeyTranslateMapper {
    static func char(for code: CGKeyCode) -> UInt32? {
        switch code {
        case 0x00: return 0x61   // a
        case 0x0B: return 0x62   // b
        case 0x08: return 0x63   // c
        case 0x02: return 0x64   // d
        case 0x0E: return 0x65   // e
        case 0x03: return 0x66   // f
        case 0x05: return 0x67   // g
        case 0x04: return 0x68   // h
        case 0x22: return 0x69   // i
        case 0x26: return 0x6A   // j
        case 0x28: return 0x6B   // k
        case 0x25: return 0x6C   // l
        case 0x2E: return 0x6D   // m
        case 0x2D: return 0x6E   // n
        case 0x1F: return 0x6F   // o
        case 0x23: return 0x70   // p
        case 0x0C: return 0x71   // q
        case 0x0F: return 0x72   // r
        case 0x01: return 0x73   // s
        case 0x11: return 0x74   // t
        case 0x20: return 0x75   // u
        case 0x09: return 0x76   // v
        case 0x0D: return 0x77   // w
        case 0x07: return 0x78   // x
        case 0x10: return 0x79   // y
        case 0x06: return 0x7A   // z
        case 0x1D: return 0x30   // 0
        case 0x12: return 0x31   // 1
        case 0x13: return 0x32   // 2
        case 0x14: return 0x33   // 3
        case 0x15: return 0x34   // 4
        case 0x17: return 0x35   // 5
        case 0x16: return 0x36   // 6
        case 0x1A: return 0x37   // 7
        case 0x1C: return 0x38   // 8
        case 0x19: return 0x39   // 9
        default: return nil
        }
    }
}
