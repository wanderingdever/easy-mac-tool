import AppKit
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
        // 菜单栏 label：E 图标。
        MenuBarExtra {
            MenuBarView()
                .environmentObject(settings)
        } label: {
            BlackEMenuBarIcon()
                .frame(width: 22, height: 22)
        }
        .menuBarExtraStyle(.window)

        Window("设置", id: "settings") {
            SettingsRootView()
                .environmentObject(settings)
                .frame(minWidth: 760, minHeight: 520)
        }
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
        // 替代 macOS 15+ 的 .defaultLaunchBehavior(.suppressed)：
        // 启动时关闭可能自动打开的设置窗口（菜单栏 app 不应在启动时弹窗）。
        // 按 canBecomeMain 判断而非标题字符串：OverlayPanel/剪贴板 panel/
        // MenuBarExtra 窗口的 canBecomeMain 均为 false，设置窗口是唯一
        // true 的窗口——标题匹配在本地化或改名后会静默失效。
        for window in NSApp.windows where window.canBecomeMain {
            window.close()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出时强制同步 flush 剪贴板历史到磁盘。
        // ClipboardManager.stop() 内部调用 saveToDiskSync()（同步 IO），
        // 确保防抖窗口内（0.3s）的变更和未完成的 IO 在进程终止前落盘。
        // 之前 AppCoordinator 从不调用 stop()，退出时最近 1 秒的复制会丢失。
        coordinator?.flushClipboardForTermination()
    }

    /// macOS 13+ 推荐 NSApplicationDelegate 实现此方法并返回 true，
    /// 支持安全状态恢复，消除启动时的运行时警告日志。
    func applicationSupportsSecureRestorableState(_ application: NSApplication) -> Bool {
        return true
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("EasyMacToolOpenSettings")
}

/// Wires the hotkey manager to the enumerator, capture manager, activator,
/// the overlay panel, and the clipboard manager. All routing of `HotkeyEvent`
/// flows through `handle(_:)`.
@MainActor
final class AppCoordinator {
    private let settings: AppSettings
    private let enumerator = WindowEnumerator()
    private let captureManager = ScreenCaptureManager()
    private let activator = WindowActivator()
    private let panelController = OverlayPanelController()
    private let clipboardManager = ClipboardManager.shared
    private let clipboardPanelController = ClipboardPanelController()
    /// Combine 订阅集合：设置变更同步到运行中的服务。
    private var cancellables = Set<AnyCancellable>()

    /// 存储 openSwitcher 启动的 Task，便于在 closeSwitcher 中 cancel。
    /// 防止用户快速打开-关闭切换器时，已关闭的面板在 Task 完成后重新弹出。
    private var openTask: Task<Void, Never>?

    /// 打开会话代次：每次 openSwitcher 调用 +1，closeSwitcher 显式关闭也 +1。
    /// openTask 用「捕获的 session 是否仍等于当前 openSession」判断该次打开是否
    /// 仍有效——替代旧的 `activeShortcut == nil` 判断。区别在于：修饰键释放
    /// （.hold 清空 activeShortcut / .focus 触发轻点激活）不应使打开失效，
    /// 只有显式关闭（closeSwitcher）或更新的打开请求才使旧会话失效。
    private var openSession = 0

    /// 轻点待激活标记：.focus 模式下用户释放修饰键时 openTask 仍在 snapshot 中
    /// （面板尚未 present，selectedItem 为 nil），记录当前会话。snapshot 完成后
    /// 若该会话仍是当前会话，立即激活下一个窗口并关闭（tap-to-switch，
    /// 类 Windows Alt+Tab 轻点切换）。
    private var pendingActivationSession: Int?

    /// 已弹出过设置页的权限集合（按 PermissionKind 精细跟踪）。
    /// 替代旧的全局 hasShownPermissionPrompt 布尔标志——全局标志在用户
    /// "部分授权"或"撤销后重新授权"场景下会阻止后续提示：
    /// - 用户授权 AX 后再按快捷键，SR/IM 仍缺但不提示（Bug 2）
    /// - 用户撤销权限后重新授权，因标志仍为 true 而静默失败（Bug 1）
    ///
    /// 按权限跟踪：每项权限独立记录是否已提示过。用户授权某项后该项从
    /// missing 移除，下次按快捷键时 missing 中只剩未授权项，会重新触发
    /// 提示。已授权项的记录保留，避免重复提示已授权的权限。
    private var promptedPermissions: Set<AccessibilityChecker.PermissionKind> = []

    /// 启动时权限检查的渐进式重试计数。
    /// macOS 15+ 从 Xcode 重新运行时，tccd 需要重新评估新进程权限，
    /// 评估通常 1-3s 完成。0.5s 检查太早会误判为 missing，导致误弹设置页。
    /// 策略：2s 后第一次检查，失败则每 1.5s 重试，最多 3 次（总 6.5s）。
    /// 全部失败才真正提示用户。
    private var permissionCheckAttempts = 0
    private static let maxPermissionCheckAttempts = 3
    private static let initialPermissionCheckDelay: TimeInterval = 2.0
    private static let permissionRetryInterval: TimeInterval = 1.5

    /// 首次启动时用户通常尚未授予辅助功能权限，导致第一次 CGEventTap
    /// 创建失败。定时重试使用户在系统设置中完成授权后无需重启应用。
    private var hotkeyRetryTimer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
        // 启动后渐进式权限检查（替代旧的 0.5s 单次检查）。
        // 详见 schedulePermissionCheck() 的注释。
        schedulePermissionCheck()
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
        // CGEventTap 健康监控定时器：
        // 1. 首次启动时用户可能尚未授权辅助功能，定时器检测到 isTrusted=true
        //    后调用 start() 重建 tap。
        // 2. tap 可能因系统睡眠唤醒、锁屏、长时间运行、或 simulatePaste 的合成
        //    事件经过自己的 event tap 而被临时禁用。定时器检测 isTapHealthy=false
        //    后调用 restart() 恢复。
        // 0.5s 间隔：simulatePaste 后 tap 可能被禁用，缩短恢复窗口让用户几乎无感。
        // （之前 2s 间隔导致粘贴后 2s 内按快捷键无响应，用户感觉"无法呼出"。）
        hotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
                guard self != nil else { return }
                guard AccessibilityChecker.isTrusted else { return }
                if !HotkeyManager.shared.isTapHealthy {
                    HotkeyManager.shared.restart()
                }
        }
        panelController.onActivateItem = { [weak self] item in
            self?.activateItem(item)
        }
        panelController.onSelectChanged = { [weak self] item in
            // Use the previewSize captured during present() — each shortcut
            // has its own preview size, set on the panelController at open.
            self?.captureManager.setLiveWindow(item,
                                               previewSize: self?.panelController.previewSize ?? .small)
        }
        // 点击面板外部时关闭切换器，避免常驻遮挡。
        panelController.onDismiss = { [weak self] in
            self?.closeSwitcher()
        }
        // Start clipboard history tracking.
        clipboardManager.historyLimit = settings.clipboardHistoryLimit
        clipboardManager.setCapturing(settings.clipboardCapturingEnabled)
        clipboardManager.start()
        // 订阅设置变更实时同步到运行中的 manager：之前在设置页拖动
        // "最大保留"滑块只写 AppSettings，manager 的上限重启后才生效，
        // historyLimit didSet 注释声称的"立即裁剪"不会发生。
        settings.$clipboardHistoryLimit
            .dropFirst()  // 初始值已在上面同步，避免重复触发 trim+persist
            .sink { [weak self] limit in
                self?.clipboardManager.historyLimit = limit
            }
            .store(in: &cancellables)
        clipboardPanelController.onReapply = { [weak self] item in
            self?.reapplyClipboard(item)
        }
    }

    deinit {
        // deinit 是 nonisolated，可能在任意线程执行。Timer 必须在创建它的
        // 线程（主线程）invalidate，否则可能崩溃。AppCoordinator 由
        // AppDelegate 持有整个生命周期，deinit 通常在 app 退出时触发，
        // 但仍需防御性处理：派回主线程 invalidate。
        // 不捕获 self（self 已在析构中），只捕获 timer 引用。
        let timer = hotkeyRetryTimer
        DispatchQueue.main.async {
            timer?.invalidate()
        }
    }

    /// 退出时同步 flush 剪贴板历史到磁盘。
    /// 由 AppDelegate.applicationWillTerminate 调用，确保防抖窗口内的
    /// 变更和未完成的 IO 在进程终止前落盘。
    /// 同时显式停止 SCStream，避免依赖进程死亡清理（更合规的资源管理）。
    func flushClipboardForTermination() {
        captureManager.stopAll()
        clipboardManager.stop()
    }

    /// 启动后渐进式权限检查。
    ///
    /// 背景：macOS 15+ 从 Xcode 重新运行（⌘R）时，虽然系统设置中 app 已授权，
    /// 但 tccd daemon 需要重新评估新进程的权限身份，评估通常 1-3 秒完成。
    /// 在评估完成前，AXIsProcessTrusted() / CGPreflightScreenCaptureAccess()
    /// 会返回 false，导致误判为"权限缺失"。
    ///
    /// ad-hoc 签名（Sign to Run Locally）下问题更严重：TCC 按 cdhash 匹配，
    /// 构建变更导致 cdhash 变化，TCC 认为是新实体，旧的授权记录失效。
    /// 系统设置 UI 仍显示"已授权"（按 bundle ID 展示），但 API 返回未授权。
    ///
    /// 策略：
    /// 1. 启动后 2s 第一次检查（给 tccd 评估时间）
    /// 2. 若 missing 非空，每 1.5s 重试，最多 3 次（总 6.5s）
    /// 3. 重试期间权限生效（TCC 评估完成）→ 直接返回，不弹设置页
    /// 4. 重试次数用尽仍 missing → 调用 requestAllMissingPermissions 提示用户
    ///
    /// 重试期间主动重新触发 TCC 注册副作用（triggerScreenCaptureRegistration），
    /// 让 TCC 把当前进程 cdhash 重新加入数据库。这对 ad-hoc 签名下的 cdhash
    /// 失配尤其重要——重新注册可能让 TCC 识别到当前进程身份，避免用户手动重置 TCC。
    private func schedulePermissionCheck() {
        let delay = permissionCheckAttempts == 0
            ? Self.initialPermissionCheckDelay
            : Self.permissionRetryInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // 若 openSwitcher 已先触发过请求，跳过避免重复。
            // 用 promptedPermissions 判断：若当前所有 missing 项都已提示过，跳过。
            let currentMissing = AccessibilityChecker.missingPermissions
            // 权限齐全：清空提示记录，未来权限被撤销可重新提示。
            // 这覆盖了"启动时被提示、之后授权、但从未按过快捷键"的场景——
            // 否则 promptedPermissions 残留会导致撤销权限后按快捷键静默返回。
            if currentMissing.isEmpty {
                self.promptedPermissions.removeAll()
                return
            }
            let newMissing = currentMissing.filter { !self.promptedPermissions.contains($0) }
            guard !newMissing.isEmpty else { return }

            self.permissionCheckAttempts += 1
            if self.permissionCheckAttempts >= Self.maxPermissionCheckAttempts {
                // 重试次数用尽：真正的权限缺失（非 TCC 评估延迟）。
                AccessibilityChecker.requestAllMissingPermissions()
                self.promptedPermissions.formUnion(currentMissing)
                return
            }
            // TCC 可能尚未评估完成，继续重试。
            // 主动重新触发 TCC 注册副作用：让 TCC 把当前进程 cdhash 重新加入
            // 数据库，对 ad-hoc 签名下的 cdhash 失配有修复作用。
            print("[TCC] permission check attempt \(self.permissionCheckAttempts)/\(Self.maxPermissionCheckAttempts) still missing: \(currentMissing.map(\.rawValue)) — retrying in \(Self.permissionRetryInterval)s")
            AccessibilityChecker.triggerRegistrationOnly()
            self.schedulePermissionCheck()
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
            // 使用 else if 防御双面板同时打开的极端情况。
            if clipboardPanelController.isPresented {
                clipboardPanelController.dismiss()
            } else if panelController.isPresented {
                closeSwitcher()
            }
        case .close:
            if let item = panelController.selectedItem {
                activator.close(item)
                // 从 items 列表移除已关闭的窗口，避免用户继续 Tab 切到
                // 已关闭窗口（激活失败）。Windows Alt+Tab 也是立即移除。
                panelController.removeItem(item)
            }
        case .minimize:
            if let item = panelController.selectedItem {
                activator.minimize(item)
                // 最小化的窗口从列表移除：用户不应再切换到已最小化的窗口。
                panelController.removeItem(item)
            }
        case .clipboard:
            toggleClipboard()
        }
    }

    private func openSwitcher(with shortcut: ShortcutConfig) {
        // 新打开请求：使旧会话失效（含权限缺失提前返回的路径——旧会话的 openTask
        // 不应在权限已失效时继续 present），并清除上一次的轻点标记。
        openSession += 1
        pendingActivationSession = nil
        // 权限检查：用只读的 missingPermissions（不触发 TCC 副作用）。
        // 按权限类型精细跟踪是否已提示过：
        // - 已提示过的权限项不重复弹设置页（避免 .hold 模式连按时频繁弹窗）
        // - 新缺失的权限项（用户撤销、或部分授权后剩余项）会重新提示
        // - 权限齐全时清空记录，未来权限被撤销可重新提示
        let missing = AccessibilityChecker.missingPermissions
        if !missing.isEmpty {
            // 找出尚未提示过的缺失项
            let newMissing = missing.filter { !promptedPermissions.contains($0) }
            if !newMissing.isEmpty {
                promptedPermissions.formUnion(missing)
                AccessibilityChecker.requestAllMissingPermissions()
            } else {
                // 已提示过但仍缺失（用户部分授权后剩余项）：打开设置页让用户看到当前权限状态，
                // 避免静默返回让用户以为快捷键坏了。
                // 防重复提醒：设置窗已可见时不再 post .openSettings（其 handler 会
                // NSApp.activate(ignoringOtherApps:) 抢焦点），否则用户每按一次快捷键
                // 设置窗就抢一次焦点。focusPermissionSection 幂等，始终发送无妨。
                let settingsVisible = NSApp.windows.contains { $0.canBecomeMain && $0.isVisible }
                if !settingsVisible {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: .focusPermissionSection, object: nil)
                    }
                }
            }
            // 关键：即使不弹设置页，也必须 return 不打开切换器。
            // 但不能 setActiveShortcut(nil) 后就不管——否则权限被撤销时
            // CGEventTap 已失效，事件被吞但无反馈，用户感觉卡死。
            // hotkeyRetryTimer 会持续检测 isTrusted 并重建 tap，
            // 权限恢复后快捷键自动可用。
            HotkeyManager.shared.setActiveShortcut(nil)
            return
        }
        // 权限齐全：清空提示记录，未来权限被撤销可重新提示。
        promptedPermissions.removeAll()
        // 关键修复：.hold 模式下用户释放 modifier 后再按快捷键会触发 .open，
        // 但此时旧切换器可能仍打开（isSwitcherOpen=true）。先关闭旧切换器，
        // 避免重复 present、captureManager 状态混乱。
        if panelController.isPresented {
            closeSwitcher()
        }
        // 对称处理：剪贴板面板仍打开时先关闭，避免双面板并存。
        if clipboardPanelController.isPresented {
            clipboardPanelController.dismiss()
        }
        // Cancel any previous openTask to prevent a dismissed panel from
        // re-presenting after the (slow) snapshot completes.
        openTask?.cancel()
        HotkeyManager.shared.setActiveShortcut(shortcut)
        openTask = Task {
            // 捕获当前会话：释放修饰键（.hold 清空 activeShortcut / .focus 轻点）
            // 不再使打开失效，只有显式关闭（closeSwitcher）或更新的打开请求
            // （openSwitcher 递增 openSession）才使本会话失效。
            let session = openSession
            let items = await enumerator.snapshot(filter: shortcut)
            // 检查取消/会话失效：用户在 snapshot 期间关闭了切换器或发起了新的
            // 打开请求，不应继续 present。
            if Task.isCancelled || openSession != session {
                return
            }
            guard !items.isEmpty else {
                HotkeyManager.shared.setActiveShortcut(nil)
                return
            }
            // present 前再做一次检查：snapshot await 期间会话可能已失效。
            // 提前 return 避免面板闪现一帧。
            if Task.isCancelled || openSession != session {
                return
            }
            panelController.present(with: items,
                                    previewSize: shortcut.previewSize,
                                    displayTarget: settings.displayTarget)
            // 竞态防护：present 后再次检查，防止 present 与后续操作之间
            // 切换器被关闭，导致 capture 为已关闭面板运行。
            if Task.isCancelled || openSession != session {
                panelController.dismiss()
                return
            }
            // 轻点（tap-to-switch）：.focus 模式下用户释放修饰键时本会话仍处于
            // snapshot 阶段（commitSelection 已记录 pendingActivationSession）。
            // 面板已备好，立即激活下一个窗口并关闭——类 Windows Alt+Tab 轻点。
            // 跳过 startCapture，避免为瞬间关闭的面板启动无谓的 SCStream。
            if pendingActivationSession == session {
                let targetIndex: Int
                if shortcut.isBackward {
                    targetIndex = items.count - 1
                } else {
                    targetIndex = min(1, items.count - 1)
                }
                let target = items[targetIndex]
                activator.activate(target)
                closeSwitcher()
                return
            }
            captureManager.startCapture(for: items, previewSize: shortcut.previewSize)
            // Windows Alt+Tab mode: first key press moves selection to the
            // NEXT window (not the current one). For backward shortcuts,
            // start at the last item.
            if shortcut.isBackward {
                panelController.selectedIndex = items.count - 1
            } else if items.count > 1 {
                panelController.selectedIndex = 1
            }
            // 触发初始选中项的 live stream 防抖（500ms 后才真正启动）。
            // startCapture 的静态快照已够初始展示，防抖避免打开切换器瞬间
            // 就捕获当前窗口实时画面（用户可能 0.5s 就 Tab 走，stream 刚启动
            // 就被切走，浪费资源）。若用户在 500ms 内 Tab 切换，防抖 Task 被
            // cancel，stream 不会启动，新选中项重新开始 500ms 防抖。
            captureManager.setLiveWindow(panelController.selectedItem, previewSize: shortcut.previewSize)
        }
    }

    private func commitSelection() {
        if let item = panelController.selectedItem {
            activator.activate(item)
            closeSwitcher()
        } else if openTask != nil, !panelController.isPresented {
            // 轻点（tap-to-switch）：.focus 模式释放修饰键时 openTask 仍在异步
            // snapshot 中（面板尚未 present，selectedItem 为 nil）。
            // 不取消 openTask——记录待激活会话，snapshot 完成后立即激活下一个
            // 窗口并关闭。之前直接 cancel 导致面板永不呼出（高频连按"快捷键失效"）。
            pendingActivationSession = openSession
            HotkeyManager.shared.setActiveShortcut(nil)
        } else {
            // 防御清理：openTask 已结束或面板已存在但无选中项。
            openTask?.cancel()
            openTask = nil
            HotkeyManager.shared.setActiveShortcut(nil)
        }
    }

    private func closeSwitcher() {
        // Cancel the in-flight openTask: if snapshot is still running,
        // prevent it from presenting after the user dismissed the panel.
        openTask?.cancel()
        openTask = nil
        // 会话代次失效（双保险于 openTask.cancel）：即使 snapshot 已完成、
        // 任务未被取消，捕获了 session 的 openTask 也会因 openSession 变化
        // 而放弃 present。
        openSession += 1
        pendingActivationSession = nil
        captureManager.stopAll()
        panelController.dismiss()
        // activeShortcut 由 panelController.dismiss() → resetActiveShortcut() 清理，
        // 无需重复设置。
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
            // 避免双面板并存：切换器仍打开时先关闭，否则两个 panel 同屏、
            // Esc 一次只关其一，且 isSwitcherOpen 仍为 true 导致 Tab/方向键
            // 继续被切换器吞掉，用户感觉键盘行为错乱。
            if panelController.isPresented {
                closeSwitcher()
            }
            // Keep the manager's limit in sync with settings.
            clipboardManager.historyLimit = settings.clipboardHistoryLimit
            clipboardPanelController.present(manager: clipboardManager)
        }
    }

    /// Re-applies the selected clipboard item. The panel is already dismissed
    /// by the time this runs (see ClipboardPanelController.onReapply), so the
    /// previously frontmost app regains focus before we (optionally) paste.
    private func reapplyClipboard(_ item: ClipboardItem) {
        clipboardManager.reapply(item, autoPaste: settings.clipboardAutoPaste)
        // tap 健康检查已移到 ClipboardManager.simulatePaste() 内部：
        // 无论 warmUpAsync 耗时多久（文本立即、冷图片数秒），simulatePaste
        // 执行后都会在 50ms 后检查并恢复 tap。原 0.2s 检查在 reapplyClipboard
        // 调用时刻计时，对冷图片场景失效（0.2s 时 simulatePaste 还没执行）。
    }
}
