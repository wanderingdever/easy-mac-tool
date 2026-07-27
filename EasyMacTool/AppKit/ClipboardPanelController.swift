import AppKit
import Combine
import SwiftUI

/// Owns the bottom-of-screen panel that hosts `ClipboardOverlayView`.
/// The panel is full screen width and 1/5 of the screen height, anchored to
/// the bottom edge. Dismisses on Esc or focus loss.
@MainActor
final class ClipboardPanelController: ObservableObject {
    private let panel = OverlayPanel()
    private var hostingController: NSHostingController<ClipboardOverlayView>?
    private var globalMonitor: Any?

    /// Set by AppCoordinator; called when the user picks an item. AppCoordinator
    /// is responsible for re-applying the payload and (optionally) pasting.
    var onReapply: ((ClipboardItem) -> Void)?

    func present(manager: ClipboardManager, autoPaste: Bool) {
        // Tear down any previous session.
        dismissInternal()

        let view = ClipboardOverlayView(
            manager: manager,
            autoPaste: autoPaste,
            onDismiss: { [weak self] in self?.dismiss() },
            onReapply: { [weak self] item in
                self?.dismiss()
                self?.onReapply?(item)
            }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.view.wantsLayer = true
        hosting.view.layer?.cornerRadius = 18
        hosting.view.layer?.masksToBounds = true
        self.hostingController = hosting
        panel.contentViewController = hosting

        positionPanel()
        panel.orderFrontRegardless()
        panel.makeKey()

        installDismissMonitors()
    }

    func dismiss() {
        dismissInternal()
    }

    var isPresented: Bool { hostingController != nil }

    // MARK: - Private

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        // Full screen width, 1/4 of screen height (was 1/5 — increased for
        // taller cards), anchored to the bottom edge with no gap.
        let height = (screenRect.height / 4).rounded()
        let origin = CGPoint(x: screenRect.minX, y: screenRect.minY)
        let frame = NSRect(origin: origin, size: NSSize(width: screenRect.width, height: height))
        panel.setFrame(frame, display: true)
    }

    private func installDismissMonitors() {
        // Esc 处理已下放到 ClipboardOverlayView 的 ClipboardKeyObserver——
        // 视图层根据 focusTarget 决定是清空查询回卡片还是关闭面板。
        // 这里只保留点击面板外部关闭。
        // Click outside the panel dismisses it. Use a small delay after
        // presentation so the initial click that summoned the panel (if any)
        // doesn't immediately dismiss it.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Only dismiss if the panel is actually showing.
            guard let self, self.hostingController != nil else { return }
            self.dismiss()
        }
    }

    private func dismissInternal() {
        if let global = globalMonitor {
            NSEvent.removeMonitor(global)
            globalMonitor = nil
        }
        panel.orderOut(nil)
        hostingController = nil
        panel.contentViewController = nil
    }
}
