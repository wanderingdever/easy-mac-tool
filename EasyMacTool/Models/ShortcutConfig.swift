import CoreGraphics
import Foundation

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
    var showEmptyApps: Bool
    var releaseBehavior: ReleaseBehavior
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
         showEmptyApps: Bool = false,
         releaseBehavior: ReleaseBehavior = .focus,
         isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.keyCode = keyCode
        self.modifiersRaw = modifiers.rawValue
        self.showMinimized = showMinimized
        self.showHidden = showHidden
        self.showEmptyApps = showEmptyApps
        self.releaseBehavior = releaseBehavior
        self.isDefault = isDefault
    }

    var modifiers: CGEventFlags {
        get { CGEventFlags(rawValue: modifiersRaw) }
        set { modifiersRaw = newValue.rawValue }
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
enum KeyComboFormatter {
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
            if let scalar = Unicode.Scalar(UCKeyTranslateMapper.char(for: code)) {
                return String(scalar)
            }
            return "Key\(code)"
        }
    }
}

/// Bridges virtual key codes to a printable character without importing Carbon.
/// Covers the common letters / digits; everything else falls back to the raw code.
private enum UCKeyTranslateMapper {
    static func char(for code: CGKeyCode) -> UInt32 {
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
        case 0x1D...0x26: return 0x30 + UInt32(code - 0x1D)   // 0-9
        default: return 0xFFFD
        }
    }
}
