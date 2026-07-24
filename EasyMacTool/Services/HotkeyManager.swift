import AppKit
import CoreGraphics

/// High-level hotkey events the rest of the app reacts to.
enum HotkeyEvent {
    case open(ShortcutConfig)  // first press of a configured shortcut key combo
    case next                  // subsequent forward cycle
    case prev                  // subsequent backward cycle
    case activate              // commit selection (Enter / modifier release)
    case cancel                // Esc
    case close                 // Cmd+Q while open
    case minimize              // Cmd+W while open
    case clipboard             // summon the clipboard history panel
}

/// Virtual key codes (from Carbon/HIToolbook Events.h) — inlined to avoid the
/// Carbon framework dependency and keep the binary lean.
private enum VK {
    static let tab: CGKeyCode = 0x30         // 48
    static let `return`: CGKeyCode = 0x24    // 36
    static let escape: CGKeyCode = 0x35      // 53
    static let leftArrow: CGKeyCode = 0x7B   // 123
    static let rightArrow: CGKeyCode = 0x7C  // 124
    static let downArrow: CGKeyCode = 0x7D   // 125
    static let upArrow: CGKeyCode = 0x7E     // 126
    static let q: CGKeyCode = 0x0C           // 12
    static let w: CGKeyCode = 0x0D           // 13
}

/// Owns the `CGEventTap` that intercepts the system Cmd+Tab and routes semantic
/// events to `onEvent`. All callbacks arrive on the main run loop.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Set by `AppCoordinator`. Invoked synchronously from the event tap (main thread).
    var onEvent: (@MainActor (HotkeyEvent) -> Void)?

    /// The live `AppSettings` — read at event time so config edits take effect
    /// without restarting the event tap.
    var settings: AppSettings?

    /// Toggled by the overlay controller so we know to interpret Tab as "next"
    /// rather than "open".
    var isSwitcherOpen = false

    /// When true, the event tap passes ALL events through without processing.
    /// Used during shortcut recording so key presses reach the recorder
    /// without being intercepted by the tap.
    var isRecording = false

    /// The shortcut whose key combo opened the switcher, so we can detect its
    /// hold-modifier release and apply the configured release behavior.
    private var activeShortcut: ShortcutConfig?

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var currentFlags: CGEventFlags = []

    private init() {}

    func start() {
        guard machPort == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Missing Accessibility permission or sandbox is still on.
            return
        }
        machPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        machPort = nil
    }

    /// Called by `OverlayPanelController` when the switcher closes.
    func resetActiveShortcut() {
        activeShortcut = nil
    }

    // MARK: - Tap callback (called on main run loop)

    fileprivate func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        let type = event.type

        // The system can temporarily disable the tap under load; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = machPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        // During shortcut recording, pass all events through unmodified so
        // the recorder can capture the exact key combo without interference.
        if isRecording {
            return Unmanaged.passRetained(event)
        }

        if type == .flagsChanged {
            return handleFlagsChanged(event)
        }

        // keyDown
        return handleKeyDown(event)
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let oldFlags = currentFlags
        currentFlags = event.flags

        // If a shortcut opened the switcher and that shortcut uses a hold-modifier,
        // detect its release and apply the configured release behavior.
        if isSwitcherOpen, let shortcut = activeShortcut {
            let requiredModifiers = shortcut.modifiers
                .intersection([.maskCommand, .maskControl, .maskAlternate])
            if !requiredModifiers.isEmpty {
                let stillHeld = currentFlags.contains(requiredModifiers)
                let wasHeld = oldFlags.contains(requiredModifiers)
                if wasHeld && !stillHeld && shortcut.releaseBehavior == .focus {
                    onEvent?(.activate)
                }
            }
        }
        return Unmanaged.passRetained(event)
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = event.flags.intersection(modifierMask)

        // Switcher open: handle navigation keys (regardless of which shortcut opened it).
        if isSwitcherOpen {
            switch keyCode {
            case VK.tab:
                // Tab cycles forward, Shift+Tab cycles backward while the switcher is open.
                onEvent?(currentFlags.contains(.maskShift) ? .prev : .next)
                return nil
            case VK.return:
                onEvent?(.activate); return nil
            case VK.escape:
                onEvent?(.cancel); return nil
            case VK.leftArrow, VK.upArrow:
                onEvent?(.prev); return nil
            case VK.rightArrow, VK.downArrow:
                onEvent?(.next); return nil
            case VK.q:
                if currentFlags.contains(.maskCommand) { onEvent?(.close); return nil }
            case VK.w:
                if currentFlags.contains(.maskCommand) { onEvent?(.minimize); return nil }
            default:
                break
            }
        }

        // Switcher closed (or no matching nav key): check if this key combo opens it.
        if !isSwitcherOpen, let shortcut = matchShortcut(keyCode: keyCode, modifiers: modifiers) {
            activeShortcut = shortcut
            onEvent?(.open(shortcut))
            return nil  // swallow the opening keypress
        }

        // Clipboard hotkey (Cmd+Shift+V by default). Independent of the
        // window switcher — works whether or not the switcher is open.
        if let cs = settings?.clipboardShortcut,
           cs.keyCode == keyCode && cs.modifiers == modifiers {
            onEvent?(.clipboard)
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    /// Returns the configured shortcut whose key combo matches the event, or nil.
    private func matchShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) -> ShortcutConfig? {
        guard let shortcuts = settings?.shortcuts else { return nil }
        // Exact match: same key, same modifiers (including Shift for backward variants).
        return shortcuts.first { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }

    /// Restrict to the modifier bits we care about (drop non-modifier flags).
    private var modifierMask: CGEventFlags {
        [.maskCommand, .maskShift, .maskControl, .maskAlternate]
    }
}

// `@convention(c)` bridge: cannot capture `self`, so we pass it via `userInfo`.
private let hotkeyCallback: CGEventTapCallBack = { _, _, event, userInfo in
    guard let userInfo = userInfo else { return nil }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    // The tap runs on the main run loop, so we can re-enter MainActor synchronously.
    return MainActor.assumeIsolated {
        manager.handle(event: event)
    }
}
