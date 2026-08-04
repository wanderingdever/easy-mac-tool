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

    /// True iff the switcher overlay is currently on screen.
    /// 计算属性：直接反映 OverlayPanel.isVisible，避免手动同步导致的
    /// 状态不一致（panel 被系统隐藏但 isSwitcherOpen 仍为 true → Tab 被劫持）。
    var isSwitcherOpen: Bool {
        switcherPanel?.isVisible ?? false
    }

    /// 由 OverlayPanelController.init 注册，供 isSwitcherOpen 查询。
    private weak var switcherPanel: OverlayPanel?

    /// When true, the event tap passes ALL events through without processing.
    /// Used during shortcut recording so key presses reach the recorder
    /// without being intercepted by the tap.
    /// 计算属性：基于 recordingSessions 引用计数。之前是布尔，两个
    /// KeyRecorderView 同时进入录制态时，先结束的一方把它置 false，
    /// 仍在录制的另一方按键会被 event tap 正常拦截（录制失灵）。
    private(set) var isRecording: Bool = false
    /// 录制会话引用计数：每次 beginRecording +1，endRecording -1。
    private var recordingSessions = 0

    /// 进入快捷键录制（引用计数 +1）。与 endRecording 成对调用。
    func beginRecording() {
        recordingSessions += 1
        isRecording = true
    }

    /// 退出快捷键录制（引用计数 -1，归零才真正恢复 event tap 拦截）。
    func endRecording() {
        assert(recordingSessions > 0, "beginRecording/endRecording not paired")
        recordingSessions = max(0, recordingSessions - 1)
        isRecording = recordingSessions > 0
    }

    /// The shortcut whose key combo opened the switcher, so we can detect its
    /// hold-modifier release and apply the configured release behavior.
    /// 作为单一数据源：AppCoordinator 通过 setActiveShortcut/resetActiveShortcut 读写，
    /// 避免两个独立 activeShortcut 变量不同步导致快速操作时状态混乱。
    internal private(set) var activeShortcut: ShortcutConfig?

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var currentFlags: CGEventFlags = []

    private init() {}

    /// 注册切换器面板，供 isSwitcherOpen 计算属性查询。
    func setSwitcherPanel(_ panel: OverlayPanel) {
        switcherPanel = panel
    }

    /// 设置当前打开切换器的快捷键。由 AppCoordinator.openSwitcher 调用。
    func setActiveShortcut(_ shortcut: ShortcutConfig?) {
        activeShortcut = shortcut
    }

    func start() {
        // 若 machPort 已存在但 tap 已被系统禁用（睡眠唤醒、锁屏、长时间运行等），
        // 先 stop 清理旧资源再重建，避免 guard machPort == nil 阻止恢复。
        if let port = machPort, !CGEvent.tapIsEnabled(tap: port) {
            stop()
        }
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
            // 静默返回会让快捷键失效且无任何反馈，难以排查。
            print("[HotkeyManager] CGEvent.tapCreate failed — needs Accessibility permission")
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
        if let port = machPort {
            // 必须先禁用再 invalidate，彻底释放 system-level CGEventTap 资源。
            // 只把 machPort 引用设为 nil 会让 tap 在系统层面继续存在，
            // 每次 restart() 都会积累僵尸 tap，最终触及系统 tap 数量上限
            // 导致 CGEvent.tapCreate 返回 nil，快捷键永久失效。
            // 与 AccessibilityChecker 和 PermissionsSettingsView 中的做法一致。
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            machPort = nil
        }
    }

    /// 先 stop 再 start，用于 tap 失效后重建。
    func restart() {
        stop()
        start()
    }

    /// 检测 CGEventTap 是否仍然有效。machPort 存在且 tap 仍启用时为 true。
    /// AppCoordinator.hotkeyRetryTimer 定期检查，失效时调用 restart() 恢复。
    var isTapHealthy: Bool {
        guard let port = machPort else { return false }
        return CGEvent.tapIsEnabled(tap: port)
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
                if wasHeld && !stillHeld {
                    switch shortcut.releaseBehavior {
                    case .focus:
                        // 释放即激活选中窗口（AltTab 默认行为）
                        onEvent?(.activate)
                    case .hold:
                        // 释放后保持打开（AltTab "释放后按住"行为）：
                        // 切换器不消失，用户可以鼠标 hover 看预览、
                        // 单击卡片立即切换、Esc / 点击外部关闭。
                        // 关键：清空 activeShortcut 但保持 isSwitcherOpen=true。
                        // 这样用户再按 Cmd+Shift+Tab 时，handleKeyDown 中
                        // `if isSwitcherOpen` 分支的 Tab 处理会先检查
                        // activeShortcut 是否为 nil——若 nil 说明已释放过，
                        // 应当作新的 .open 而非 .prev，避免卡死。
                        activeShortcut = nil
                    }
                }
            }
        }
        return Unmanaged.passRetained(event)
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = event.flags.intersection(modifierMask)

        // 剪贴板快捷键优先检测（独立于窗口切换器，无论切换器是否打开都生效）。
        // 必须在 matchShortcut 之前，否则当剪贴板快捷键与某个 window switcher
        // 快捷键的 keyCode+modifiers 完全相同时，matchShortcut 会先匹配触发 .open，
        // 剪贴板快捷键被永久屏蔽，用户按 Cmd+Shift+V 会打开切换器而非剪切板。
        if let cs = settings?.clipboardShortcut,
           cs.keyCode == keyCode && cs.modifiers == modifiers {
            onEvent?(.clipboard)
            return nil
        }

        // Switcher open: handle navigation keys (regardless of which shortcut opened it).
        if isSwitcherOpen {
            // 关键修复：在 .hold 模式下，用户释放 modifier 后 activeShortcut
            // 被清空（但 isSwitcherOpen 仍为 true）。此时用户再按 Cmd+Shift+Tab
            // 应当作新的 .open（重新打开切换器），而非 .prev（在已打开的切换器
            // 里导航）。否则用户重复按快捷键会被解释为 .prev，切换器永不关闭，
            // 键盘被劫持，用户感觉"卡死"。
            // 逻辑：如果当前 modifiers 完整匹配某个配置的 shortcut，且
            // activeShortcut 为 nil（说明 .hold 模式已释放过），当作新的 open。
            if activeShortcut == nil,
               let shortcut = matchShortcut(keyCode: keyCode, modifiers: modifiers) {
                activeShortcut = shortcut
                onEvent?(.open(shortcut))
                return nil
            }

            switch keyCode {
            case VK.tab:
                // Tab cycles forward, Shift+Tab cycles backward while the switcher is open.
                // .hold 释放后 activeShortcut 为 nil 但切换器仍打开（AltTab 风格），
                // 此时 Tab 仍应作为导航键，避免用户感觉切换器卡死。
                // 注意：上面 activeShortcut==nil && matchShortcut 分支已拦截"完整快捷键重按"
                // 的情况，走到这里的 nil 一定是 .hold 释放后的纯 Tab 键。
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
                if modifiers.contains(.maskCommand) { onEvent?(.close); return nil }
            case VK.w:
                if modifiers.contains(.maskCommand) { onEvent?(.minimize); return nil }
            default:
                break
            }

            // 切换器打开期间吞掉未匹配的无修饰可打印按键：panel 是
            // nonactivatingPanel，passRetained 会把按键派发给前台 app，
            // 用户在切换器上随手按到字母键会直接输入到当前文档中。
            // 带 Command/Control/Option 的组合键仍放行（可能是有意义的系统操作）。
            let hardModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
            if modifiers.intersection(hardModifiers).isEmpty { return nil }
        }

        // Switcher closed (or no matching nav key): check if this key combo opens it.
        if !isSwitcherOpen, let shortcut = matchShortcut(keyCode: keyCode, modifiers: modifiers) {
            // 权限预检：若权限缺失，不吞事件，让 Cmd+Tab 传递到系统作为兜底。
            // 否则权限被撤销时事件被吞但切换器打不开，用户感觉快捷键卡死。
            // openSwitcher 中会再次检查权限并弹设置页，这里只负责事件路由决策。
            if !AccessibilityChecker.missingPermissions.isEmpty {
                return Unmanaged.passRetained(event)
            }
            activeShortcut = shortcut
            onEvent?(.open(shortcut))
            return nil  // swallow the opening keypress
        }

        return Unmanaged.passRetained(event)
    }

    /// Returns the configured shortcut whose key combo matches the event, or nil.
    private func matchShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) -> ShortcutConfig? {
        guard let shortcuts = settings?.shortcuts else { return nil }
        // 防御性排除系统保留组合：即使旧版本设置中已存留了保留组合
        // （黑名单校验是后加的），也不匹配不吞键，让系统正常响应。
        if AppSettings.isReservedSystemCombo(keyCode: keyCode, modifiers: modifiers) {
            return nil
        }
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
