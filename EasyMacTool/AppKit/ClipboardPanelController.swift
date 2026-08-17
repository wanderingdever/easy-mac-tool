import AppKit
import Combine
import os
import SwiftUI

/// Owns the bottom-of-screen panel that hosts `ClipboardOverlayView`.
/// The panel is full screen width and 1/4 of the screen height, anchored to
/// the bottom edge. Dismisses on Esc or focus loss.
///
/// 性能优化：panel 与 hosting controller 在首次 present 时创建后常驻，
/// 后续 present/dismiss 只控制窗口可见性（orderFrontRegardless / orderOut）
/// 与 rootView 替换——避免每次重建 SwiftUI 视图树导致的掉帧卡顿。
@MainActor
final class ClipboardPanelController: ObservableObject {
    private static let logger = Logger(subsystem: "com.easymactool", category: "ClipboardPanel")
    private let panel = OverlayPanel()
    /// 常驻的 hosting controller：首次 present 时创建并 attach 到 panel，
    /// 之后保持存活，present 时只更新 rootView（autoPaste 等参数变化）。
    private var hostingController: NSHostingController<ClipboardOverlayView>?
    private var globalMonitor: Any?
    /// 等数据就绪再弹面板的订阅：present 时若历史未加载完，订阅
    /// manager.$isLoaded 等 true 后再弹；避免首开显示「形变」的加载占位。
    private var presentDisposable: AnyCancellable?
    /// 注意：isPresented 是 @Published 存储属性（ClipboardOverlayView 用
    /// .onChange 观察），但每次 present/dismiss 后与 panel.isVisible 同步，
    /// 防止 orderFrontRegardless 失败时 isPresented=true 而面板实际不可见
    /// 导致 toggleClipboard 方向错误。
    @Published private(set) var isPresented = false

    /// isPresented 与面板真实可见性的一致性判断。
    /// 若上次定位失败遗留 isPresented=true（面板实际不可见），返回 false，
    /// 供 toggleClipboard 决定重新打开而非误判为已打开而关闭。
    var isEffectivelyVisible: Bool { isPresented && panel.isVisible }

    /// 当前 panel 的 firstResponder 是否是 NSTextView。
    /// 用于预览态 RTFTextView 聚焦时，让方向键传递给文本视图（移动选择光标）
    /// 而非触发卡片导航。用 panel.firstResponder 而非 NSApp.keyWindow?.firstResponder——
    /// 后者在 nonactivatingPanel 场景下可能取错 key window。
    var firstResponderIsTextView: Bool {
        panel.firstResponder is NSTextView
    }

    /// 是否正在编辑任何文本字段（搜索框、或「新建分组/重命名/清空」等模态
    /// alert 的 TextField）。用于让局部 key monitor 放行打字键，避免在输入
    /// 分组名时按空格误触发卡片预览。
    /// 只命中「可编辑」的 NSTextView：预览态的 RTFTextView 是 selectable 但
    /// 不可编辑，空格应继续触发关闭预览而非被吞掉。
    /// 同时检查 panel 与 key window 的 firstResponder：modal alert 的文本框
    /// 属于 alert 窗口，panel.firstResponder 可能取不到，需回退到 key window。
    var isEditingAnyText: Bool {
        if let tv = panel.firstResponder as? NSTextView, tv.isEditable { return true }
        if let keyFR = NSApp.keyWindow?.firstResponder as? NSTextView,
           keyFR.isEditable { return true }
        return false
    }

    /// 是否有模态 alert/sheet 附着在面板上（新建分组/重命名/清空确认等）。
    /// 模态弹窗出现时不应再让局部 key monitor 拦截空格/回车触发卡片预览。
    var hasModalPresentation: Bool {
        if panel.attachedSheet != nil { return true }
        if panel.sheets.contains(where: { $0.isVisible }) { return true }
        // SwiftUI .alert 可能不挂到 attachedSheet：key window 变成 alert 自身的
        // 模态窗口（非 panel）时同样视为模态。
        if let keyWindow = NSApp.keyWindow, keyWindow !== panel { return true }
        return false
    }

    /// 面板所在屏幕。多屏场景下供 ClipboardOverlayView 计算预览高度等使用，
    /// 替代 NSScreen.main（返回菜单栏所在主屏，可能非面板所在屏）。
    var screen: NSScreen? { panel.screen }

    /// 呼出面板前记录的前台 app bundleID。simulatePaste 时校验 frontmostApp
    /// 仍是它，防止面板关闭后焦点未恢复（或用户快速切窗）时把内容粘贴到
    /// 错误窗口泄露剪贴板内容。dismiss 时清空。
    private(set) var pasteTargetBundleID: String?

    /// 当前关联的 ClipboardManager 弱引用。present 时保存，dismiss 时用来
    /// 切换轮询频率：面板打开 → 0.5s 高频（用户正看历史，复制后立即出现）；
    /// 面板关闭 → 1.5s 低频（后台捕获，降低 CPU 唤醒）。
    private weak var clipboardManager: ClipboardManager?

    /// Set by AppCoordinator; called when the user picks an item. AppCoordinator
    /// is responsible for re-applying the payload and (optionally) pasting.
    var onReapply: ((ClipboardItem, String?) -> Void)?
    /// Set by AppCoordinator; called when the user picks a batch of items
    /// (multi-select → 复制全部).
    var onReapplyBatch: (([ClipboardItem], String?) -> Void)?

    func present(manager: ClipboardManager) {
        // 等数据就绪再弹面板：历史尚未从磁盘加载完时，先订阅 manager.$isLoaded，
        // 等 true 后再真正弹出，避免首开显示「形变」的加载占位（用户需再按一次）。
        // 已就绪则立即弹出。用 presentDisposable 持有订阅，重复 present 前先取消旧的。
        presentDisposable?.cancel()
        presentDisposable = nil
        if manager.isLoaded {
            presentPanel(manager: manager)
            return
        }
        presentDisposable = manager.$isLoaded
            .filter { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.presentDisposable = nil
                self.presentPanel(manager: manager)
            }
    }

    /// 实际弹出面板的主体逻辑。由 `present(manager:)` 在数据就绪后调用。
    private func presentPanel(manager: ClipboardManager) {
        // autoPaste 由 AppCoordinator 在 onReapply 回调中读取 settings.clipboardAutoPaste
        // 决定是否模拟粘贴，本身不影响视图渲染——视图只需 manager 与 controller 引用。
        // 因此这里不再接收 autoPaste 参数（之前是 dead parameter 被显式丢弃）。

        // 先定位面板：定位失败说明当前无可用的目标屏幕（多屏盲区/显示器热插拔/重排），
        // 不置 isPresented、不产生任何副作用，让下一次快捷键能重新尝试打开，
        // 避免「面板带旧 frame（首次为 .zero）不可见 + isPresented=true」导致再按反而关闭。
        guard positionPanel() else {
            Self.logger.error("[ClipboardPanel] present aborted: no valid target screen")
            return
        }

        // 记录呼出面板前的前台 app：nonactivatingPanel 不改变 frontmostApp，
        // 此刻读取的就是 paste 的目标 app。dismiss 后 simulatePaste 用它校验。
        pasteTargetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // 保存 manager 引用供 dismiss 时切换轮询频率。面板打开切高频轮询：
        // 用户正在查看历史，此时从其他 app 复制内容应立即出现在卡片中。
        clipboardManager = manager
        manager.setActivePolling(true)

        if let hosting = hostingController {
            // 复用已有 hosting controller：更新 rootView 确保依赖一致，
            // 避免 future 扩展（多 manager、测试场景）时 rootView 持有旧引用。
            hosting.rootView = ClipboardOverlayView(manager: manager, controller: self)
        } else {
            // 首次 present：创建 hosting controller 并 attach 到 panel。
            let view = ClipboardOverlayView(
                manager: manager,
                controller: self
            )
            let hosting = NSHostingController(rootView: view)
            hosting.view.wantsLayer = true
            hosting.view.layer?.cornerRadius = 18
            // masksToBounds=false：让过滤菜单（.offset(y: 42)）可以溢出面板边界
            // 显示完整内容。SwiftUI 根视图自身的 RoundedRectangle(cornerRadius: 20)
            // 已提供圆角视觉裁剪，无需 layer 级裁剪。阴影也可自然溢出。
            hosting.view.layer?.masksToBounds = false
            self.hostingController = hosting
            panel.contentViewController = hosting
        }

        panel.orderFrontRegardless()
        // 直接设为 true：present 调用即表示意图显示面板。之前读 panel.isVisible
        // 在 app 未完全激活或系统动画进行时可能返回 false，导致视图状态不重置
        // （onChange 不触发）和 localMonitor 未安装。dismiss 中 orderOut 是幂等的，
        // 即使面板实际未显示，isPresented=true 也不会造成问题。
        isPresented = true
        panel.makeKey()
        // 关键修复：阻止 NSPanel 在 makeKey 后默认把第一个 TextField（搜索框）
        // 设为 firstResponder。这是 AppKit 的已知行为——NSPanel 成为 key window
        // 时会自动找第一个 canBecomeFirstResponder 的视图（通常是 NSTextField）。
        // SwiftUI 的 @FocusState 在 onAppear 中设置 .cards 是异步派发的，时序
        // 上可能晚于 NSPanel 的默认 makeFirstResponder 调用，导致焦点先被
        // 推到搜索框、之后又跳回卡片，用户感知为「焦点在搜索框」。
        // 这里主动把 firstResponder 设为 hosting 容器根 view，让 SwiftUI 的
        // .focused($focusTarget, equals: .cards) 在 onAppear 中接管 firstResponder 推动。
        if let hosting = hostingController {
            panel.makeFirstResponder(hosting.view)
        }

        installDismissMonitors()
    }

    func dismiss() {
        // 取消等数据就绪的挂起订阅：dismiss 后不应再弹出面板。
        presentDisposable?.cancel()
        presentDisposable = nil
        if let global = globalMonitor {
            NSEvent.removeMonitor(global)
            globalMonitor = nil
        }
        // 只 orderOut 隐藏窗口，不释放 contentViewController——保留视图树
        // 便于下次 present 时快速复用，避免重建掉帧。
        panel.orderOut(nil)
        isPresented = false
        pasteTargetBundleID = nil
        // 面板关闭切回低频轮询：后台捕获延迟 1.5s 检测不影响 UX，
        // 降低菜单栏 app 常驻期间的 CPU 唤醒（笔记本续航场景）。
        clipboardManager?.setActivePolling(false)
    }

    // MARK: - Private

    /// 定位面板到目标屏幕底部。返回是否成功设定了有效 frame。
    /// 失败说明当前没有任何可用屏幕（多屏盲区/显示器热插拔/重排），
    /// 由调用方决定不置 isPresented，避免「面板不可见 + isPresented=true」卡死。
    @discardableResult
    private func positionPanel() -> Bool {
        guard let screen = targetScreen() else { return false }
        let screenRect = screen.visibleFrame
        // Full screen width, 1/4 of screen height (was 1/5 — increased for
        // taller cards), anchored to the bottom edge with no gap.
        let height = (screenRect.height / 4).rounded()
        let origin = CGPoint(x: screenRect.minX, y: screenRect.minY)
        let frame = NSRect(origin: origin, size: NSSize(width: screenRect.width, height: height))
        panel.setFrame(frame, display: true)
        return true
    }

    /// 三级屏幕定位：前台 app 主窗口所在屏 → 鼠标所在屏 → 最近屏 → 主屏/首屏。
    /// nonactivatingPanel 场景下 NSScreen.main 可能取到其他 app 的 key window
    /// 所在屏，导致面板出现在错误屏幕；因此优先用前台 app 主窗口所在屏定位
    /// （用户当前正在工作的屏最可靠），鼠标所在屏作次选。鼠标在屏幕缝隙
    /// （dead zone）时按距离选最近的屏，最后才退到主屏兜底。
    private func targetScreen() -> NSScreen? {
        // 1. 前台 app 主窗口所在屏（用户当前正在工作的屏，最可靠）
        if let bounds = frontmostMainWindowBounds() {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
        }
        // 2. 鼠标所在屏
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }
        // 3. 鼠标在屏幕缝隙时，按距离选最近的屏（避免跳到错误主屏）
        if let screen = nearestScreen(to: mouseLocation) {
            return screen
        }
        // 4. 兜底：主屏或首屏
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// 鼠标在屏幕缝隙（dead zone）时，按距离选最近的屏。
    /// 计算鼠标点到每个屏 frame 最近边的距离，取最小值。
    private func nearestScreen(to point: CGPoint) -> NSScreen? {
        guard !NSScreen.screens.isEmpty else { return nil }
        var best: (screen: NSScreen, distance: CGFloat)?
        for screen in NSScreen.screens {
            let rect = screen.frame
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = sqrt(dx * dx + dy * dy)
            if best == nil || distance < best!.distance {
                best = (screen, distance)
            }
        }
        return best?.screen
    }

    /// 用 CGWindowList 找到前台 app 的普通主窗口（kCGWindowLayer == 0）bounds。
    /// 与 WindowEnumerator 的过滤口径一致：layer == 0 是普通文档窗口，
    /// layer > 0 是浮动面板/菜单/下拉框，不参与定位。
    private func frontmostMainWindowBounds() -> CGRect? {
        guard let ownerPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid == ownerPID else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let dict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = dict["Width"], width > 0,
                  let height = dict["Height"], height > 0 else { continue }
            return CGRect(x: dict["X"] ?? 0,
                          y: dict["Y"] ?? 0,
                          width: width,
                          height: height)
        }
        return nil
    }

    private func installDismissMonitors() {
        // 防止重复安装：先卸载旧的 monitor 再装新的。
        if let global = globalMonitor {
            NSEvent.removeMonitor(global)
            globalMonitor = nil
        }
        // Click outside the panel dismisses it. Use a small delay after
        // presentation so the initial click that summoned the panel (if any)
        // doesn't immediately dismiss it.
        //
        // 设计说明：与 OverlayPanelController（切换器）不同，此处直接调
        // self.dismiss() 而非通过 onDismiss 回调 AppCoordinator。原因是
        // 剪贴板面板不涉及 capture 资源/openTask/activeShortcut 等协调清理，
        // dismiss 仅 orderOut + 移除 monitor 即可。切换器需要 AppCoordinator
        // 完整清理 capture/activeShortcut/openTask，故走 onDismiss 回调。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let mouseLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                if self.panel.frame.contains(mouseLocation) { return }
                self.dismiss()
            }
        }
    }
}
