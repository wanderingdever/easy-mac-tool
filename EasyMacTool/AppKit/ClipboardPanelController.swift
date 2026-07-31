import AppKit
import Combine
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
    private let panel = OverlayPanel()
    /// 常驻的 hosting controller：首次 present 时创建并 attach 到 panel，
    /// 之后保持存活，present 时只更新 rootView（autoPaste 等参数变化）。
    private var hostingController: NSHostingController<ClipboardOverlayView>?
    private var globalMonitor: Any?
    /// 注意：isPresented 是 @Published 存储属性（ClipboardOverlayView 用
    /// .onChange 观察），但每次 present/dismiss 后与 panel.isVisible 同步，
    /// 防止 orderFrontRegardless 失败时 isPresented=true 而面板实际不可见
    /// 导致 toggleClipboard 方向错误。
    @Published private(set) var isPresented = false

    /// Set by AppCoordinator; called when the user picks an item. AppCoordinator
    /// is responsible for re-applying the payload and (optionally) pasting.
    var onReapply: ((ClipboardItem) -> Void)?

    func present(manager: ClipboardManager) {
        // autoPaste 由 AppCoordinator 在 onReapply 回调中读取 settings.clipboardAutoPaste
        // 决定是否模拟粘贴，本身不影响视图渲染——视图只需 manager 与 controller 引用。
        // 因此 present 不再接收 autoPaste 参数（之前是 dead parameter 被显式丢弃）。

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
            hosting.view.layer?.masksToBounds = true
            self.hostingController = hosting
            panel.contentViewController = hosting
        }

        positionPanel()
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
        if let global = globalMonitor {
            NSEvent.removeMonitor(global)
            globalMonitor = nil
        }
        // 只 orderOut 隐藏窗口，不释放 contentViewController——保留视图树
        // 便于下次 present 时快速复用，避免重建掉帧。
        panel.orderOut(nil)
        isPresented = false
    }

    // MARK: - Private

    private func positionPanel() {
        // 用鼠标所在屏，避免 nonactivatingPanel 场景下 NSScreen.main 取到其他 app 的
        // key window 所在屏，导致面板出现在错误屏幕。
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let screenRect = screen.visibleFrame
        // Full screen width, 1/4 of screen height (was 1/5 — increased for
        // taller cards), anchored to the bottom edge with no gap.
        let height = (screenRect.height / 4).rounded()
        let origin = CGPoint(x: screenRect.minX, y: screenRect.minY)
        let frame = NSRect(origin: origin, size: NSSize(width: screenRect.width, height: height))
        panel.setFrame(frame, display: true)
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
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Only dismiss if the panel is actually showing.
            guard let self, self.panel.isVisible else { return }
            // Non-activating panels may receive their own click through a
            // global monitor. Do not dismiss before the card/button handles it.
            if self.panel.frame.contains(NSEvent.mouseLocation) { return }
            self.dismiss()
        }
    }
}
