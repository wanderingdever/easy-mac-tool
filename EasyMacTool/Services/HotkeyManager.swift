import AppKit
import Combine
import CoreGraphics
import os

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
    case layoutAction(WindowLayoutAction)  // a window-layout shortcut fired
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

/// Thread-safe mirror of the minimal routing state the background tap thread
/// reads. Written only on the main thread; read by the tap thread under lock.
/// This lets the tap decide "is this event interesting?" with pure math and no
/// main-thread round trip, so ordinary keys never block on (or freeze with) the
/// main run loop.
private final class RouteMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var _isRecording = false
    /// True while a switcher session is open *or in flight* (shortcut pressed,
    /// panel not yet shown). The tap must keep routing key/flags events to the
    /// main thread during that window so release detection (flick) still works.
    private var _sessionActive = false
    private var _clipboardEnabled = false
    private var _clipboardKeyCode: CGKeyCode = 0
    private var _clipboardMods: CGEventFlags = []
    private var _switcherEnabled = false
    private var _switcherCombos: [(keyCode: CGKeyCode, mods: CGEventFlags)] = []
    private var _layoutEnabled = false
    private var _layoutCombos: [(keyCode: CGKeyCode, mods: CGEventFlags, action: WindowLayoutAction)] = []
    private var _syntheticMarker: Int64 = 0

    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return _isRecording }
    var sessionActive: Bool { lock.lock(); defer { lock.unlock() }; return _sessionActive }
    var syntheticMarker: Int64 { lock.lock(); defer { lock.unlock() }; return _syntheticMarker }

    var clipboardEnabled: Bool { lock.lock(); defer { lock.unlock() }; return _clipboardEnabled }
    /// (keyCode, modifiers) or nil when disabled.
    var clipboardCombo: (keyCode: CGKeyCode, mods: CGEventFlags)? {
        lock.lock(); defer { lock.unlock() }
        return _clipboardEnabled ? (_clipboardKeyCode, _clipboardMods) : nil
    }
    var switcherEnabled: Bool { lock.lock(); defer { lock.unlock() }; return _switcherEnabled }
    var switcherCombos: [(keyCode: CGKeyCode, mods: CGEventFlags)] {
        lock.lock(); defer { lock.unlock() }; return _switcherCombos
    }
    var layoutEnabled: Bool { lock.lock(); defer { lock.unlock() }; return _layoutEnabled }
    var layoutCombos: [(keyCode: CGKeyCode, mods: CGEventFlags, action: WindowLayoutAction)] {
        lock.lock(); defer { lock.unlock() }; return _layoutCombos
    }

    func setRecording(_ value: Bool) { lock.lock(); defer { lock.unlock() }; _isRecording = value }
    func setSessionActive(_ value: Bool) { lock.lock(); defer { lock.unlock() }; _sessionActive = value }
    func setSyntheticMarker(_ value: Int64) { lock.lock(); defer { lock.unlock() }; _syntheticMarker = value }

    func setClipboard(enabled: Bool, keyCode: CGKeyCode, modifiers: CGEventFlags) {
        lock.lock(); defer { lock.unlock() }
        _clipboardEnabled = enabled
        _clipboardKeyCode = keyCode
        _clipboardMods = modifiers
    }
    func setSwitcher(enabled: Bool, combos: [(keyCode: CGKeyCode, mods: CGEventFlags)]) {
        lock.lock(); defer { lock.unlock() }
        _switcherEnabled = enabled
        _switcherCombos = combos
    }
    func setLayout(enabled: Bool, combos: [(keyCode: CGKeyCode, mods: CGEventFlags, action: WindowLayoutAction)]) {
        lock.lock(); defer { lock.unlock() }
        _layoutEnabled = enabled
        _layoutCombos = combos
    }
}

/// Owns the `CGEventTap` that intercepts the system Cmd+Tab and routes semantic
/// events to `onEvent`.
///
/// The tap runs on its own dedicated thread (not the main run loop). A live
/// `.defaultTap` makes the WindowServer hold every keystroke in the login
/// session until the callback returns, so a main-thread stall would freeze
/// typing system-wide. The callback therefore does only pure-math routing off a
/// lock-protected mirror and hands matched events to the main thread via a
/// synchronous hop; ordinary keys are passed straight through without waiting.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()
    nonisolated private static let logger = Logger(subsystem: "com.easymactool", category: "HotkeyManager")

    /// Marks synthetic events this app posts (clipboard paste), so the tap can
    /// skip them and never re-enter on its own output. "EAST".
    static let syntheticMarker: Int64 = 0x4541_5354

    /// Restrict to the modifier bits we care about (drop non-modifier flags).
    nonisolated private static let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    /// Set by `AppCoordinator`. Invoked from the main thread (via handle).
    var onEvent: (@MainActor (HotkeyEvent) -> Void)?

    /// The live `AppSettings` — read at event time so config edits take effect
    /// without restarting the event tap.
    var settings: AppSettings? {
        didSet {
            guard let settings else { return }
            syncRouteMirror()
            bindSettings(settings)
        }
    }

    /// True iff the switcher overlay is currently on screen.
    var isSwitcherOpen: Bool {
        switcherPanel?.isVisible ?? false
    }

    /// 由 OverlayPanelController.init 注册，供 isSwitcherOpen 查询。
    private weak var switcherPanel: OverlayPanel?

    /// When true, the event tap passes ALL events through without processing.
    /// 计算属性：基于 recordingSessions 引用计数。
    private(set) var isRecording: Bool = false
    /// 录制会话引用计数：每次 beginRecording +1，endRecording -1。
    private var recordingSessions = 0

    /// The shortcut whose key combo opened the switcher, so we can detect its
    /// hold-modifier release and apply the configured release behavior.
    internal private(set) var activeShortcut: ShortcutConfig?

    /// Thread lifecycle state. Only touched under `lifecycleLock`; the tap
    /// thread reads/writes its own run loop fields there too.
    private nonisolated(unsafe) let lifecycleLock = NSLock()
    private nonisolated(unsafe) var tap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var tapRunLoop: CFRunLoop?
    private nonisolated(unsafe) var tapThread: Thread?
    private nonisolated(unsafe) var shouldStopTapThread = false
    private nonisolated(unsafe) var pendingStartAfterStop = false

    /// Routing mirror read by the tap thread.
    private nonisolated(unsafe) let routeMirror = RouteMirror()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        routeMirror.setSyntheticMarker(Self.syntheticMarker)
    }

    /// 注册切换器面板，供 isSwitcherOpen 计算属性查询。
    func setSwitcherPanel(_ panel: OverlayPanel) {
        switcherPanel = panel
        updateSessionMirror()
    }

    /// 设置当前打开切换器的快捷键。由 AppCoordinator.openSwitcher 调用。
    func setActiveShortcut(_ shortcut: ShortcutConfig?) {
        activeShortcut = shortcut
        updateSessionMirror()
    }

    /// 切换器面板实际显示/隐藏时同步镜像（由 OverlayPanelController 调用）。
    func setSwitcherOpen(_ open: Bool) {
        updateSessionMirror()
    }

    /// Called by `OverlayPanelController` when the switcher closes.
    func resetActiveShortcut() {
        setActiveShortcut(nil)
    }

    /// 同步镜像.sessionActive：会话「进行中或已打开」即需要主线程路由。
    private func updateSessionMirror() {
        routeMirror.setSessionActive(activeShortcut != nil || isSwitcherOpen)
    }

    func beginRecording() {
        recordingSessions += 1
        isRecording = true
        routeMirror.setRecording(true)
    }

    func endRecording() {
        assert(recordingSessions > 0, "beginRecording/endRecording not paired")
        recordingSessions = max(0, recordingSessions - 1)
        isRecording = recordingSessions > 0
        routeMirror.setRecording(isRecording)
    }

    /// 把当前 settings 的快捷键路由信息同步进镜像（tap 线程只读）。
    func syncRouteMirror() {
        guard let settings else { return }
        routeMirror.setSyntheticMarker(Self.syntheticMarker)
        routeMirror.setClipboard(enabled: settings.clipboardCapturingEnabled,
                                 keyCode: settings.clipboardShortcut.keyCode,
                                 modifiers: settings.clipboardShortcut.modifiers)
        routeMirror.setSwitcher(enabled: settings.windowSwitcherEnabled,
                                combos: settings.shortcuts.map { ($0.keyCode, $0.modifiers) })
        routeMirror.setLayout(enabled: settings.windowLayoutEnabled,
                              combos: settings.windowLayoutShortcuts.map { ($0.keyCode, $0.modifiers, $0.action) })
    }

    private func bindSettings(_ settings: AppSettings) {
        cancellables = []
        settings.$clipboardCapturingEnabled
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncRouteMirror() }
            .store(in: &cancellables)
        settings.$clipboardShortcut
            .sink { [weak self] _ in self?.syncRouteMirror() }
            .store(in: &cancellables)
        settings.$windowSwitcherEnabled
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncRouteMirror() }
            .store(in: &cancellables)
        settings.$shortcuts
            .sink { [weak self] _ in self?.syncRouteMirror() }
            .store(in: &cancellables)
        settings.$windowLayoutEnabled
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncRouteMirror() }
            .store(in: &cancellables)
        settings.$windowLayoutShortcuts
            .sink { [weak self] _ in self?.syncRouteMirror() }
            .store(in: &cancellables)
    }

    func start() {
        // 若 machPort 已存在但 tap 已被系统禁用（睡眠唤醒、锁屏、长时间运行等），
        // 先 stop 清理旧资源再重建。
        if let port = tap, !CGEvent.tapIsEnabled(tap: port) {
            stop()
        }
        let thread = lifecycleLock.withLock { () -> Thread? in
            if tapThread != nil {
                if shouldStopTapThread { pendingStartAfterStop = true }
                return nil
            }
            shouldStopTapThread = false
            pendingStartAfterStop = false
            let t = Thread { [weak self] in self?.runEventTap() }
            t.name = "EasyMacTool Hotkey"
            t.qualityOfService = .userInteractive
            tapThread = t
            return t
        }
        thread?.start()
    }

    func stop() {
        let snapshot = lifecycleLock.withLock { () -> (runLoop: CFRunLoop?, tap: CFMachPort?, threadExists: Bool) in
            shouldStopTapThread = true
            pendingStartAfterStop = false
            return (tapRunLoop, tap, tapThread != nil)
        }
        if let port = snapshot.tap {
            // 必须先禁用再 invalidate，彻底释放 system-level CGEventTap 资源。
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let runLoop = snapshot.runLoop {
            // 从外部停止 run loop，绝不 join——停止与 tap 线程正在主线程上的工作
            // 之间不会互相死锁。
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        } else if !snapshot.threadExists {
            lifecycleLock.withLock {
                shouldStopTapThread = false
                tapThread = nil
            }
        }
    }

    /// 先 stop 再 start，用于 tap 失效后重建。
    func restart() {
        stop()
        start()
    }

    /// 检测 CGEventTap 是否仍然有效。AppCoordinator.hotkeyRetryTimer 定期检查。
    var isTapHealthy: Bool {
        guard let port = tap else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    // MARK: - Tap thread

    nonisolated private func runEventTap() {
        autoreleasepool {
            let runLoop = CFRunLoopGetCurrent()
            lifecycleLock.withLock { tapRunLoop = runLoop }

            guard !lifecycleLock.withLock({ shouldStopTapThread }) else {
                if clearEventTapThread() { restartOnMain() }
                return
            }

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
                Self.logger.error("CGEvent.tapCreate failed — needs Accessibility permission")
                _ = clearEventTapThread()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            lifecycleLock.withLock { tap = port; runLoopSource = source }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)

            if lifecycleLock.withLock({ shouldStopTapThread }) {
                CGEvent.tapEnable(tap: port, enable: false)
            } else {
                CFRunLoopRun()
            }

            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            if clearEventTapThread() { restartOnMain() }
        }
    }

    nonisolated private func clearEventTapThread() -> Bool {
        lifecycleLock.withLock {
            let shouldRestart = pendingStartAfterStop
            tap = nil
            runLoopSource = nil
            tapRunLoop = nil
            tapThread = nil
            shouldStopTapThread = false
            pendingStartAfterStop = false
            return shouldRestart
        }
    }

    nonisolated private func restartOnMain() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    /// Runs on the tap thread. Pure-math routing: only events the main thread
    /// may actually consume hop over; everything else passes straight through.
    nonisolated fileprivate func route(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let currentTap = lifecycleLock.withLock { shouldStopTapThread ? nil : tap }
            if let currentTap { CGEvent.tapEnable(tap: currentTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // 自家合成事件（如剪贴板粘贴）：绝不重新进入处理流程。
        if event.getIntegerValueField(.eventSourceUserData) == routeMirror.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        // 录制快捷键时放行所有键。
        if routeMirror.isRecording {
            return Unmanaged.passUnretained(event)
        }

        let sessionActive = routeMirror.sessionActive
        switch type {
        case .keyDown:
            if sessionActive {
                return dispatchToMain(event)
            }
            // 会话未开：只有命中配置快捷键才值得派发主线程（纯数学匹配）。
            let keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let mods = event.flags.intersection(Self.modifierMask)
            let clipMatch = routeMirror.clipboardCombo.map { $0.keyCode == keyCode && $0.mods == mods } == true
            let switcherMatch = routeMirror.switcherEnabled
                && routeMirror.switcherCombos.contains { $0.keyCode == keyCode && $0.mods == mods }
            let layoutMatch = routeMirror.layoutEnabled
                && routeMirror.layoutCombos.contains { $0.keyCode == keyCode && $0.mods == mods }
            if clipMatch || switcherMatch || layoutMatch {
                return dispatchToMain(event)
            }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            // 会话未开时修饰键翻转与快捷键无关，直接放行；会话中才需主线程
            // 做释放检测（含轻点 flick 的 in-flight 窗口）。
            if sessionActive {
                return dispatchToMain(event)
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Synchronous hop to the main thread. The tap holds the login session's
    /// keystrokes until this returns, so it must stay fast; it is only reached
    /// for events the switcher may actually consume.
    nonisolated private func dispatchToMain(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { handle(event: event) }
        }
    }

    // MARK: - Main-thread handling

    fileprivate func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        let type = event.type

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 安全输入（SecureInput，密码框等）期间系统会禁用所有 event tap。
            if let port = tap {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        if isRecording {
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            return handleFlagsChanged(event)
        }
        return handleKeyDown(event)
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 修饰键释放检测。activeShortcut 只在按住修饰键打开时被设置，所以
        // “需要的修饰键不再被按住”即等于“释放”——无需跨事件跟踪 oldFlags。
        if let shortcut = activeShortcut {
            let required = shortcut.modifiers
                .intersection([.maskCommand, .maskControl, .maskAlternate])
            if !required.isEmpty {
                let stillHeld = event.flags.intersection(required) == required
                if !stillHeld {
                    switch shortcut.releaseBehavior {
                    case .focus:
                        // 释放即激活选中窗口（AltTab 默认行为）
                        onEvent?(.activate)
                    case .hold:
                        // 释放后保持打开（AltTab "释放后按住"行为）
                        activeShortcut = nil
                        updateSessionMirror()
                    }
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = event.flags.intersection(Self.modifierMask)

        // 剪贴板快捷键优先检测（独立于窗口切换器）。
        if settings?.clipboardCapturingEnabled == true,
           let cs = settings?.clipboardShortcut,
           cs.keyCode == keyCode && cs.modifiers == modifiers {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }
            onEvent?(.clipboard)
            return nil
        }

        // 窗口布局快捷键：独立于窗口切换器/剪贴板，命中即触发布局动作。
        if !isSwitcherOpen,
           settings?.windowLayoutEnabled == true,
           let action = matchLayoutAction(keyCode: keyCode, modifiers: modifiers) {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }
            // 权限预检：缺辅助功能权限时不吞事件，避免全局劫持却无效果。
            if !AccessibilityChecker.missingPermissions.isEmpty {
                return Unmanaged.passUnretained(event)
            }
            onEvent?(.layoutAction(action))
            return nil
        }

        if isSwitcherOpen {
            if activeShortcut == nil,
               settings?.windowSwitcherEnabled == true,
               let shortcut = matchShortcut(keyCode: keyCode, modifiers: modifiers) {
                activeShortcut = shortcut
                updateSessionMirror()
                onEvent?(.open(shortcut))
                return nil
            }

            switch keyCode {
            case VK.tab:
                onEvent?(event.flags.contains(.maskShift) ? .prev : .next)
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

            // 切换器打开期间吞掉未匹配的无修饰可打印按键，避免漏进前台 app。
            let hardModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
            if modifiers.intersection(hardModifiers).isEmpty { return nil }
        }

        if !isSwitcherOpen,
           settings?.windowSwitcherEnabled == true,
           let shortcut = matchShortcut(keyCode: keyCode, modifiers: modifiers) {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }
            // 权限预检：若权限缺失，不吞事件，让 Cmd+Tab 传递到系统作为兜底。
            if !AccessibilityChecker.missingPermissions.isEmpty {
                return Unmanaged.passUnretained(event)
            }
            activeShortcut = shortcut
            updateSessionMirror()
            onEvent?(.open(shortcut))
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    /// Returns the configured shortcut whose key combo matches the event, or nil.
    private func matchShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) -> ShortcutConfig? {
        guard let shortcuts = settings?.shortcuts else { return nil }
        if AppSettings.isReservedSystemCombo(keyCode: keyCode, modifiers: modifiers) {
            return nil
        }
        return shortcuts.first { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }

    /// Returns the window-layout action whose shortcut matches the event, or nil.
    private func matchLayoutAction(keyCode: CGKeyCode, modifiers: CGEventFlags) -> WindowLayoutAction? {
        guard let shortcuts = settings?.windowLayoutShortcuts else { return nil }
        if AppSettings.isReservedSystemCombo(keyCode: keyCode, modifiers: modifiers) {
            return nil
        }
        return shortcuts.first { $0.keyCode == keyCode && $0.modifiers == modifiers }?.action
    }
}

// `@convention(c)` bridge: cannot capture `self`, so we pass it via `userInfo`.
// Runs on the dedicated tap thread.
private let hotkeyCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo = userInfo else { return nil }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.route(type: type, event: event)
}