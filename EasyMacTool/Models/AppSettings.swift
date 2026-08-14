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
    /// 默认纯文本粘贴：开启后重新选中历史条目时只写回纯文本（剥掉 RTF/格式），
    /// 适合代码/网页粘贴场景。图片/文件/颜色条目不受影响。
    @Published var clipboardPlainPaste: Bool = false { didSet { debouncePersist() } }
    /// Lets users suspend clipboard observation without quitting the app.
    @Published var clipboardCapturingEnabled: Bool = true { didSet { debouncePersist() } }
    /// 用户可配置的「忽略来源 app」bundleID 列表：这些 app 复制的剪贴板内容
    /// 不被记录（如 IM、特定工具）。在硬编码密码黑名单之上叠加。
    @Published var ignoredClipboardApps: [String] = [] { didSet { debouncePersist() } }
    /// 链接预览：开启后对复制的 http/https URL 后台抓取网页标题与站点图标
    /// （类 Paste 链接卡片）。默认关闭——复制私有/带 token 的链接时 app 主动
    /// 访问可能触发服务端副作用或泄露信息，需用户明确知情开启。
    @Published var clipboardLinkPreviewEnabled: Bool = false { didSet { debouncePersist() } }
    /// 窗口切换功能全局开关。关闭后所有窗口切换快捷键透传至系统，
    /// 恢复 macOS 原生 Cmd+Tab 行为。
    @Published var windowSwitcherEnabled: Bool = true { didSet { debouncePersist() } }

    // MARK: - 系统监控
    /// 系统监控总开关。关闭时不采样、不启动定时器、菜单栏不渲染指标块（零开销）。
    @Published var systemMonitorEnabled: Bool = false { didSet { debouncePersist() } }
    /// 采样间隔（秒）。
    @Published var monitorInterval: Int = 2 { didSet { debouncePersist() } }
    /// 温度单位（TemperatureUnit.rawValue）。
    @Published var temperatureUnit: String = TemperatureUnit.celsius.rawValue { didSet { debouncePersist() } }
    /// 各菜单栏指标是否启用（key: MenuBarMetric.settingsKey → enabled）。
    @Published var menuBarMetrics: [String: Bool] = [:] { didSet { debouncePersist() } }
    /// 菜单栏指标显示顺序（MenuBarMetric.rawValue 数组）。
    @Published var menuBarMetricOrder: [String] = [] { didSet { debouncePersist() } }
    /// 设置页预览区各 section 是否显示。
    @Published var monitorShowCPU: Bool = true { didSet { debouncePersist() } }
    @Published var monitorShowGPU: Bool = true { didSet { debouncePersist() } }
    @Published var monitorShowMemory: Bool = true { didSet { debouncePersist() } }
    @Published var monitorShowNetwork: Bool = true { didSet { debouncePersist() } }
    @Published var monitorShowDisk: Bool = true { didSet { debouncePersist() } }
    @Published var monitorShowPower: Bool = true { didSet { debouncePersist() } }

    // MARK: - 窗口布局
    /// 窗口布局总开关。关闭后不匹配任何布局快捷键、不安装径向监视器（零监听）。
    @Published var windowLayoutEnabled: Bool = false { didSet { debouncePersist() } }
    /// 径向菜单（按住鼠标中键 + 移动鼠标）是否启用。
    @Published var windowLayoutRadialEnabled: Bool = true { didSet { debouncePersist() } }
    /// 径向菜单的修饰键长按触发（区分左右）。modifiersRaw==0 表示未启用键盘触发。
    @Published var windowLayoutRadialKeyTrigger: RadialKeyTrigger = .none { didSet { debouncePersist() } }
    /// 每个布局动作的自定义快捷键。
    @Published var windowLayoutShortcuts: [LayoutShortcut] = WindowLayoutAction.defaultShortcuts { didSet { debouncePersist() } }

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

    /// Reject duplicate global shortcut combinations for window layout actions.
    /// Checks against window-switcher shortcuts, the clipboard shortcut, and
    /// other layout shortcuts.
    func layoutShortcutConflictMessage(keyCode: CGKeyCode,
                                       modifiers: CGEventFlags,
                                       excludingAction: WindowLayoutAction) -> String? {
        if Self.isReservedSystemCombo(keyCode: keyCode, modifiers: modifiers) {
            return "系统保留快捷键，不可使用"
        }
        if let existing = shortcuts.first(where: {
            $0.keyCode == keyCode && $0.modifiers == modifiers
        }) {
            return "已被窗口切换快捷键「\(existing.name)」使用"
        }
        if clipboardShortcut.keyCode == keyCode,
           clipboardShortcut.modifiers == modifiers {
            return "已被剪切板快捷键使用"
        }
        if let existing = windowLayoutShortcuts.first(where: {
            $0.action != excludingAction && $0.keyCode == keyCode && $0.modifiers == modifiers
        }) {
            return "已被窗口布局「\(existing.action.displayName)」使用"
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

    /// 退出时强制同步 flush：取消防抖 WorkItem，立即同步写入 UserDefaults。
    /// 由 AppDelegate.applicationWillTerminate 调用，确保 0.5s 防抖窗口内的
    /// 变更在进程终止前落盘。
    func flushForTermination() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        persist()
    }

    private struct Persisted: Codable {
        var displayTarget: DisplayTarget?
        var shortcuts: [ShortcutConfig]
        var clipboardShortcut: ShortcutConfig?
        var clipboardHistoryLimit: Int?
        var clipboardAutoPaste: Bool?
        var clipboardPlainPaste: Bool?
        var clipboardCapturingEnabled: Bool?
        var ignoredClipboardApps: [String]?
        var clipboardLinkPreviewEnabled: Bool?
        var windowSwitcherEnabled: Bool?

        // 系统监控
        var systemMonitorEnabled: Bool?
        var monitorInterval: Int?
        var temperatureUnit: String?
        var menuBarMetrics: [String: Bool]?
        var menuBarMetricOrder: [String]?
        var monitorShowCPU: Bool?
        var monitorShowGPU: Bool?
        var monitorShowMemory: Bool?
        var monitorShowNetwork: Bool?
        var monitorShowDisk: Bool?
        var monitorShowPower: Bool?
        // 窗口布局
        var windowLayoutEnabled: Bool?
        var windowLayoutRadialEnabled: Bool?
        var windowLayoutRadialKeyTrigger: RadialKeyTrigger?
        var windowLayoutShortcuts: [LayoutShortcut]?
    }

    private func persist() {
        let snapshot = Persisted(
            displayTarget: displayTarget,
            shortcuts: shortcuts,
            clipboardShortcut: clipboardShortcut,
            clipboardHistoryLimit: clipboardHistoryLimit,
            clipboardAutoPaste: clipboardAutoPaste,
            clipboardPlainPaste: clipboardPlainPaste,
            clipboardCapturingEnabled: clipboardCapturingEnabled,
            ignoredClipboardApps: ignoredClipboardApps,
            clipboardLinkPreviewEnabled: clipboardLinkPreviewEnabled,
            windowSwitcherEnabled: windowSwitcherEnabled,
            systemMonitorEnabled: systemMonitorEnabled,
            monitorInterval: monitorInterval,
            temperatureUnit: temperatureUnit,
            menuBarMetrics: menuBarMetrics,
            menuBarMetricOrder: menuBarMetricOrder,
            monitorShowCPU: monitorShowCPU,
            monitorShowGPU: monitorShowGPU,
            monitorShowMemory: monitorShowMemory,
            monitorShowNetwork: monitorShowNetwork,
            monitorShowDisk: monitorShowDisk,
            monitorShowPower: monitorShowPower,
            windowLayoutEnabled: windowLayoutEnabled,
            windowLayoutRadialEnabled: windowLayoutRadialEnabled,
            windowLayoutRadialKeyTrigger: windowLayoutRadialKeyTrigger,
            windowLayoutShortcuts: windowLayoutShortcuts
        )
        do {
            let data = try JSONEncoder().encode(snapshot)
            defaults.set(data, forKey: storageKey)
        } catch {
            // 编码失败此前静默 return，用户调整设置后重启即丢失，且无任何日志
            // 可诊断。记录错误日志便于排查（如 ShortcutConfig 字段类型变更
            // 未提供迁移路径导致编码器抛错）。设置本身仍保留在内存中，
            // 当前会话工作正常，仅持久化失败。
            Self.logger.error("Failed to encode settings for persistence: \(error.localizedDescription, privacy: .public). Settings remain in memory but won't survive restart.")
        }
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
            if let plainPaste = snapshot.clipboardPlainPaste { clipboardPlainPaste = plainPaste }
            if let capturingEnabled = snapshot.clipboardCapturingEnabled {
                clipboardCapturingEnabled = capturingEnabled
            }
            if let ignoredApps = snapshot.ignoredClipboardApps {
                ignoredClipboardApps = ignoredApps
            }
            if let linkPreview = snapshot.clipboardLinkPreviewEnabled {
                clipboardLinkPreviewEnabled = linkPreview
            }
            if let wsEnabled = snapshot.windowSwitcherEnabled {
                windowSwitcherEnabled = wsEnabled
            }
            if let v = snapshot.systemMonitorEnabled { systemMonitorEnabled = v }
            if let v = snapshot.monitorInterval { monitorInterval = v }
            if let v = snapshot.temperatureUnit { temperatureUnit = v }
            if let v = snapshot.menuBarMetrics { menuBarMetrics = v }
            if let v = snapshot.menuBarMetricOrder { menuBarMetricOrder = v }
            if let v = snapshot.monitorShowCPU { monitorShowCPU = v }
            if let v = snapshot.monitorShowGPU { monitorShowGPU = v }
            if let v = snapshot.monitorShowMemory { monitorShowMemory = v }
            if let v = snapshot.monitorShowNetwork { monitorShowNetwork = v }
            if let v = snapshot.monitorShowDisk { monitorShowDisk = v }
            if let v = snapshot.monitorShowPower { monitorShowPower = v }
            if let v = snapshot.windowLayoutEnabled { windowLayoutEnabled = v }
            if let v = snapshot.windowLayoutRadialEnabled { windowLayoutRadialEnabled = v }
            if let v = snapshot.windowLayoutRadialKeyTrigger { windowLayoutRadialKeyTrigger = v }
            // 空数组时保持默认（默认无快捷键），不覆盖用户清空后的状态
            if let layouts = snapshot.windowLayoutShortcuts, !layouts.isEmpty {
                windowLayoutShortcuts = layouts
            }
        } catch {
            Self.logger.error("Failed to decode persisted settings: \(error.localizedDescription, privacy: .public). Using defaults.")
        }
    }
}
