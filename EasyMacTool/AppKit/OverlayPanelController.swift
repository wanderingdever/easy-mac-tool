import AppKit
import Combine
import SwiftUI

/// Owns the `OverlayPanel` and drives its contents (window list, selection).
/// `AppCoordinator` calls into this to present/dismiss the switcher.
@MainActor
final class OverlayPanelController: ObservableObject {
    @Published var items: [WindowItem] = []
    @Published var selectedIndex: Int = 0
    /// Mouse-hover "aim" index — a lighter preview border, NOT the actual
    /// selection. Keyboard navigation (Tab/Shift+Tab) changes `selectedIndex`
    /// which has higher priority. Clicking a hovered cell promotes it to
    /// `selectedIndex` and activates the window. Mirrors Windows Alt+Tab:
    /// hover is a visual aim, click is the commit.
    @Published var hoverIndex: Int? = nil
    @Published var previewSize: AppSettings.PreviewSize = .small
    /// Which screen the panel appears on (set per presentation from
    /// AppSettings.displayTarget).
    private var displayTarget: AppSettings.DisplayTarget = .active

    private let panel = OverlayPanel()
    private var hostingController: NSHostingController<SwitcherOverlayView>?
    // 点击面板外部关闭切换器——否则切换器会常驻遮挡其他窗口。
    private var globalMonitor: Any?

    /// Set by `AppCoordinator` so clicks can activate the target window.
    var onActivateItem: ((WindowItem) -> Void)?
    /// Set by `AppCoordinator` so selection changes trigger live stream switch.
    var onSelectChanged: ((WindowItem?) -> Void)?
    /// 点击面板外部时由 AppCoordinator 执行完整关闭流程（停 capture、清
    /// activeShortcut）。不能只调 dismiss——会漏掉 AppCoordinator 的清理。
    var onDismiss: (() -> Void)?

    var selectedItem: WindowItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func present(with items: [WindowItem],
                 previewSize: AppSettings.PreviewSize,
                 displayTarget: AppSettings.DisplayTarget) {
        self.items = items
        self.previewSize = previewSize
        self.displayTarget = displayTarget
        self.selectedIndex = 0
        self.hoverIndex = nil
        HotkeyManager.shared.isSwitcherOpen = true

        let view = SwitcherOverlayView(
            controller: self,
            onHoverChange: { [weak self] index in self?.setHover(index) },
            onActivate: { [weak self] index in self?.activate(at: index) }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.view.wantsLayer = true
        // 多层面设透明，彻底消除 hosting.view 默认不透明背景色：
        // - layer?.isOpaque=false 告诉 Core Graphics 此 layer 有 alpha 通道
        // - layer?.backgroundColor=nil 比设 clear 更彻底，不留任何填充色
        // NSView.isOpaque 是只读的（NSHostingController.view 是私有子类），
        // 但 layer 层面设透明已足够——AppKit 的不透明绘制由 layer 主导。
        hosting.view.layer?.isOpaque = false
        hosting.view.layer?.backgroundColor = nil
        // 圆角与 SwiftUI 背景一致（24pt），masksToBounds 裁掉圆角外的内容。
        hosting.view.layer?.cornerRadius = 24
        hosting.view.layer?.masksToBounds = true
        self.hostingController = hosting
        panel.contentViewController = hosting

        positionPanel()
        panel.orderFrontRegardless()
        // Make the panel key so it accepts mouse clicks immediately (first click
        // works without needing to click twice).
        panel.makeKey()
        installDismissMonitor()
    }

    func dismiss() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        panel.orderOut(nil)
        HotkeyManager.shared.isSwitcherOpen = false
        HotkeyManager.shared.resetActiveShortcut()
        items = []
        selectedIndex = 0
        hoverIndex = nil
        hostingController = nil
        panel.contentViewController = nil
    }

    /// 点击面板外部（鼠标按下事件发生在 panel frame 之外）时关闭切换器。
    /// 避免切换器常驻遮挡其他窗口/应用。
    private func installDismissMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self else { return }
            // 通知 AppCoordinator 执行完整关闭流程。
            self.onDismiss?()
        }
    }

    func next() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
        // Keyboard navigation takes priority over mouse hover — clear the
        // visual aim so it doesn't linger on a different cell than selected.
        hoverIndex = nil
        notifySelectionChanged()
    }

    func prev() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        hoverIndex = nil
        notifySelectionChanged()
    }

    /// Sets the mouse-hover "aim" index — a lighter preview border only.
    /// Does NOT change `selectedIndex` and does NOT trigger the live stream
    /// switch. Pass `nil` to clear the aim when the mouse leaves a cell.
    func setHover(_ index: Int?) {
        guard let index else {
            hoverIndex = nil
            return
        }
        guard items.indices.contains(index) else { return }
        hoverIndex = index
    }

    /// Mouse-click selection: update selection to the clicked cell.
    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
        notifySelectionChanged()
    }

    /// Mouse-click activation: select then commit (activate the window).
    func activate(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
        if let item = items[safe: index] {
            onActivateItem?(item)
        }
    }

    /// Notifies AppCoordinator that the selected window changed, so the live
    /// stream can switch to the newly selected window.
    private func notifySelectionChanged() {
        onSelectChanged?(selectedItem)
    }

    // MARK: - Private

    /// Selects the screen the switcher panel appears on, based on the
    /// configured `displayTarget`:
    /// - `.active`:  `NSScreen.main` — the screen with keyboard focus
    /// - `.mouse`:   the screen under the current mouse cursor
    /// - `.menuBar`: the screen that contains the menu bar (primary display)
    private func selectScreen() -> NSScreen? {
        switch displayTarget {
        case .active:
            return NSScreen.main
        case .mouse:
            let mouseLocation = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        case .menuBar:
            // The menu bar lives at the top of the primary display, whose
            // frame.origin.y == 0 (menu bar occupies y < 0 in flipped coords).
            return NSScreen.screens.first { $0.frame.minY >= 0 } ?? NSScreen.main
        }
    }

    private func positionPanel() {
        guard let screen = selectScreen() else { return }
        let screenRect = screen.visibleFrame

        // 与 SwitcherOverlayView/WindowThumbnailCell 一致的布局参数。
        let interCell: CGFloat = 12          // FlowLayout spacing
        let outerPadding: CGFloat = 20      // SwitcherOverlayView .padding(20)
        // 外层 padding(12) 已移除（背景直接撑满 hosting.view）。
        let panelPadding: CGFloat = 0
        let cellInnerPadding: CGFloat = 10  // WindowThumbnailCell .padding(10)
        let vStackSpacing: CGFloat = 8      // VStack(spacing: 8)
        let captionHeight: CGFloat = 16     // icon(16) / caption 行高

        // 精确计算每个 cell 的实际尺寸（与 WindowThumbnailCell.thumbnailSize 一致）。
        // 之前用 thumbnailWidth + 20 估算 cellWidth，但窄窗口的 thumbnailSize.width
        // 可能远小于 thumbnailWidth，导致估算列数偏少 → 实际 FlowLayout 换行更少 →
        // 面板高度过大或反过来估算行数偏少 → 底部窗口被裁切。
        let cells: [CGSize] = items.map { item in
            let thumb = computeThumbnailSize(for: item)
            let cellWidth = thumb.width + cellInnerPadding * 2
            let cellHeight = thumb.height + cellInnerPadding * 2 + vStackSpacing + captionHeight
            return CGSize(width: cellWidth, height: cellHeight)
        }
        guard !cells.isEmpty else { return }

        // 最大可用宽度：屏幕 92%。FlowLayout 在此宽度内换行。
        let maxPanelWidth = screenRect.width * 0.92
        let maxInnerWidth = maxPanelWidth - outerPadding * 2 - panelPadding * 2

        // 与 FlowLayout.computeRows 相同的换行逻辑：逐个 cell 尝试放入当前行，
        // 超过 maxWidth 就换行。
        var rows: [(width: CGFloat, height: CGFloat, count: Int)] = [(0, 0, 0)]
        for cellSize in cells {
            let currentRow = rows[rows.count - 1]
            let candidateWidth = currentRow.width
                + (currentRow.count > 0 ? interCell : 0)
                + cellSize.width
            if candidateWidth > maxInnerWidth, currentRow.count > 0 {
                rows.append((0, 0, 0))
            }
            let rowIdx = rows.count - 1
            if rows[rowIdx].count > 0 {
                rows[rowIdx].width += interCell
            }
            rows[rowIdx].width += cellSize.width
            rows[rowIdx].height = max(rows[rowIdx].height, cellSize.height)
            rows[rowIdx].count += 1
        }

        // 面板宽度：取最宽行的实际宽度，加上 padding。
        let contentWidth = rows.map { $0.width }.max() ?? 0
        let width = min(contentWidth + outerPadding * 2 + panelPadding * 2, maxPanelWidth)

        // 面板高度：所有行高度之和 + 行间距 + padding。
        let contentHeight = rows.reduce(CGFloat.zero) { partial, row in
            partial + row.height + (partial > 0 ? interCell : 0)
        }
        let heightToFit = contentHeight + outerPadding * 2 + panelPadding * 2
        // 硬上限：屏幕高度 95%，避免极端情况超出屏幕。
        let height = min(heightToFit, screenRect.height * 0.95)

        let origin = CGPoint(
            x: screenRect.midX - width / 2,
            y: screenRect.midY - height / 2
        )
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        panel.setFrame(frame, display: true)
    }

    /// 与 WindowThumbnailCell.thumbnailSize 完全一致的缩略图尺寸计算。
    /// 保证 positionPanel 估算的 cell 尺寸与实际渲染一致，避免换行不匹配。
    private func computeThumbnailSize(for item: WindowItem) -> CGSize {
        let maxWidth = previewSize.thumbnailWidth
        let maxHeight = previewSize.thumbnailHeight
        if item.isPlaceholder || item.frame == .zero {
            return CGSize(width: maxWidth, height: maxHeight)
        }
        let aspect = item.aspectRatio
        if aspect >= maxWidth / maxHeight {
            return CGSize(width: maxWidth, height: maxWidth / aspect)
        } else {
            return CGSize(width: maxHeight * aspect, height: maxHeight)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
