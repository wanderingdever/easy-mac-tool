import CoreGraphics
import Foundation

/// A modifier-hold trigger for summoning the radial layout menu. It stores the
/// set of modifiers (including left/right device bits) that the user holds —
/// no key required — matching Loop's "hold Right Control" interaction.
struct RadialKeyTrigger: Codable, Hashable {
    /// Full modifier bit mask, including device-independent left/right bits
    /// (e.g. left command 0x8, right command 0x10).
    var modifiersRaw: UInt64

    var modifiers: CGEventFlags {
        get { CGEventFlags(rawValue: modifiersRaw) }
        set { modifiersRaw = newValue.rawValue }
    }

    /// True when no trigger is configured.
    var isNone: Bool { modifiersRaw == 0 }

    /// A human-readable label such as "右⌘" or "⌃⌥".
    var displayString: String {
        ModifierBits.describe(raw: modifiersRaw)
    }

    static let none = RadialKeyTrigger(modifiersRaw: 0)
}

/// Bit-level helpers for modifier flags, including the left/right device bits.
/// `NSEvent.ModifierFlags` and `CGEventFlags` share the same bit values for the
/// generic and left/right modifiers, so a single mask works for both.
enum ModifierBits {
    // Generic modifier bits.
    static let shift: UInt64 = 0x20000
    static let control: UInt64 = 0x40000
    static let alternate: UInt64 = 0x80000
    static let command: UInt64 = 0x100000
    // Left/right device bits.
    static let leftControl: UInt64 = 0x1
    static let leftShift: UInt64 = 0x2
    static let leftCommand: UInt64 = 0x8
    static let rightControl: UInt64 = 0x2000
    static let leftAlternate: UInt64 = 0x20
    static let rightAlternate: UInt64 = 0x40
    static let rightCommand: UInt64 = 0x10
    static let rightShift: UInt64 = 0x4

    /// Union of all generic + left/right modifier bits. Used to extract only the
    /// modifier state from a raw flags value.
    static let deviceMask: UInt64 =
        shift | control | alternate | command
        | leftControl | leftShift | leftCommand
        | rightControl | rightCommand | rightShift
        | leftAlternate | rightAlternate

    /// Renders a raw modifier mask as a compact label, distinguishing left/right.
    static func describe(raw: UInt64) -> String {
        var s = ""
        if raw & rightControl != 0 { s += "右⌃" }
        if raw & leftControl != 0 { s += "⌃" }
        if raw & rightAlternate != 0 { s += "右⌥" }
        if raw & leftAlternate != 0 { s += "⌥" }
        if raw & rightShift != 0 { s += "右⇧" }
        if raw & leftShift != 0 { s += "⇧" }
        if raw & rightCommand != 0 { s += "右⌘" }
        if raw & leftCommand != 0 { s += "⌘" }
        return s.isEmpty ? "未设置" : s
    }
}