import Combine
import SwiftUI

@main
struct EasyMacToolApp: App {
    // 用 shared 单例，使 AppDelegate 中的 AppCoordinator 与 SwiftUI 共用
    // 同一 AppSettings 实例，设置变更实时同步。
    @StateObject private var settings = AppSettings.shared
    // 用 NSApplicationDelegateAdaptor 在 app 启动时立即创建 coordinator，
    // 而非等用户点击菜单栏图标才创建——否则启动后快捷键不生效。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 菜单栏图标：黑底白字"E"（NSImage 自绘，非 template 保持黑底白字）
        MenuBarExtra {
            MenuBarView()
                .environmentObject(settings)
        } label: {
            BlackEMenuBarIcon()
        }
        .menuBarExtraStyle(.window)

        Window("EasyMacTool 设置", id: "settings") {
            SettingsRootView()
                .environmentObject(settings)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// AppDelegate：在 applicationDidFinishLaunching 中立即创建 AppCoordinator，
/// 确保 CGEventTap 在启动时就注册，快捷键即时生效。
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 持有 coordinator 防止被释放——否则 CGEventTap 会被停止。
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 直接用 AppSettings.shared 创建 coordinator，无需等用户交互。
        coordinator = AppCoordinator(settings: AppSettings.shared)
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("EasyMacToolOpenSettings")
}

/// Wires the hotkey manager to the enumerator, capture manager, activator,
/// the overlay panel, and the clipboard manager. All routing of `HotkeyEvent`
/// flows through `handle(_:)`.
@MainActor
final class AppCoordinator: ObservableObject {
    private let settings: AppSettings
    private let enumerator = WindowEnumerator()
    private let captureManager = ScreenCaptureManager()
    private let activator = WindowActivator()
    private let panelController = OverlayPanelController()
    private let clipboardManager = ClipboardManager.shared
    private let clipboardPanelController = ClipboardPanelController()

    /// The shortcut whose key combo opened the switcher (drives release behavior).
    private var activeShortcut: ShortcutConfig?

    /// 存储 openSwitcher 启动的 Task，便于在 closeSwitcher 中 cancel。
    /// 防止用户快速打开-关闭切换器时，已关闭的面板在 Task 完成后重新弹出。
    private var openTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        // Trigger the system's native permission request flow shortly after
        // launch: requests ALL missing permissions, opens EasyMacTool's
        // settings window to the 系统设置 section (shows three status icons),
        // AND opens macOS System Settings to the first missing permission's
        // pane. No custom NSAlert — the system's own dialog is the only prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            AccessibilityChecker.requestAllMissingPermissions()
        }
        // Start tracking app activations so the switcher can sort by MRU
        // (Windows Alt+Tab behavior). Accessing .shared seeds the current
        // frontmost app and subscribes to didActivateApplicationNotification.
        // Done here (not lazily in WindowEnumerator) so activations between
        // launch and the first switcher open are captured.
        _ = AppUsageTracker.shared
        HotkeyManager.shared.settings = settings
        HotkeyManager.shared.onEvent = { [weak self] event in
            self?.handle(event)
        }
        HotkeyManager.shared.start()
        panelController.onActivateItem = { [weak self] item in
            self?.activateItem(item)
        }
        panelController.onSelectChanged = { [weak self] item in
            self?.captureManager.setLiveWindow(item, previewSize: self?.settings.previewSize ?? .small)
        }
        // 点击面板外部时关闭切换器，避免常驻遮挡。
        panelController.onDismiss = { [weak self] in
            self?.closeSwitcher()
        }
        // Start clipboard history tracking.
        clipboardManager.historyLimit = settings.clipboardHistoryLimit
        clipboardManager.start()
        clipboardPanelController.onReapply = { [weak self] item in
            self?.reapplyClipboard(item)
        }
    }

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .open(let shortcut):
            openSwitcher(with: shortcut)
        case .next:
            panelController.next()
        case .prev:
            panelController.prev()
        case .activate:
            commitSelection()
        case .cancel:
            // Esc closes whichever overlay is open.
            if clipboardPanelController.isPresented {
                clipboardPanelController.dismiss()
            } else {
                closeSwitcher()
            }
        case .close:
            if let item = panelController.selectedItem {
                activator.close(item)
                panelController.next()
            }
        case .minimize:
            if let item = panelController.selectedItem {
                activator.minimize(item)
                panelController.next()
            }
        case .clipboard:
            toggleClipboard()
        }
    }

    private func openSwitcher(with shortcut: ShortcutConfig) {
        // If required permissions are missing, trigger the system's native
        // request flow (request all + open settings) instead of opening the
        // switcher (which would silently fail to capture/enumerate).
        if AccessibilityChecker.requestAllMissingPermissions() {
            activeShortcut = nil
            return
        }
        // Cancel any previous openTask to prevent a dismissed panel from
        // re-presenting after the (slow) snapshot completes.
        openTask?.cancel()
        activeShortcut = shortcut
        openTask = Task {
            let items = await enumerator.snapshot(filter: shortcut)
            // 检查 cancellation：若用户在 snapshot 期间已关闭切换器，
            // activeShortcut 已被置 nil，不应继续 present。
            if Task.isCancelled || activeShortcut == nil {
                return
            }
            guard !items.isEmpty else {
                activeShortcut = nil
                return
            }
            panelController.present(with: items, previewSize: settings.previewSize)
            captureManager.startCapture(for: items, previewSize: settings.previewSize)
            // Windows Alt+Tab mode: first key press moves selection to the
            // NEXT window (not the current one). For backward shortcuts,
            // start at the last item.
            if shortcut.isBackward {
                panelController.selectedIndex = items.count - 1
            } else if items.count > 1 {
                panelController.selectedIndex = 1
            }
            // Start a live stream for the initially selected window.
            captureManager.setLiveWindow(panelController.selectedItem, previewSize: settings.previewSize)
        }
    }

    private func commitSelection() {
        if let item = panelController.selectedItem {
            activator.activate(item)
        }
        closeSwitcher()
    }

    private func closeSwitcher() {
        // Cancel the in-flight openTask: if snapshot is still running,
        // prevent it from presenting after the user dismissed the panel.
        openTask?.cancel()
        openTask = nil
        captureManager.stopAll()
        panelController.dismiss()
        activeShortcut = nil
    }

    /// Called when the user clicks a cell while the switcher is open.
    func activateItem(_ item: WindowItem) {
        activator.activate(item)
        closeSwitcher()
    }

    // MARK: - Clipboard

    private func toggleClipboard() {
        if clipboardPanelController.isPresented {
            clipboardPanelController.dismiss()
        } else {
            // Keep the manager's limit in sync with settings.
            clipboardManager.historyLimit = settings.clipboardHistoryLimit
            clipboardPanelController.present(
                manager: clipboardManager,
                autoPaste: settings.clipboardAutoPaste
            )
        }
    }

    /// Re-applies the selected clipboard item. The panel is already dismissed
    /// by the time this runs (see ClipboardPanelController.onReapply), so the
    /// previously frontmost app regains focus before we (optionally) paste.
    private func reapplyClipboard(_ item: ClipboardItem) {
        clipboardManager.reapply(item, autoPaste: settings.clipboardAutoPaste)
    }
}
