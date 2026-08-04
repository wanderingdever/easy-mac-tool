import AppKit
import Combine
import SwiftUI

/// Owns the `OverlayPanel` and drives its contents (window list, selection).
/// `AppCoordinator` calls into this to present/dismiss the switcher.
@MainActor
final class OverlayPanelController: ObservableObject {
    @Published var items: [WindowItem] = []
    // didSet 统一触发 notifySelectionChanged，避免直接赋值绕过 live stream 切换。
    // next()/prev()/removeItem() 中不再显式调用 notifySelectionChanged()。
    @Published var selectedIndex: Int = 0 {
        didSet { notifySelectionChanged() }
    }
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
    /// 切换器打开时检测 AX 权限是否被撤销。AX 失效后 CGEventTap 被系统禁用，
    /// 键盘事件不再到达 handleKeyDown，用户按 Esc 无效。此定时器在 AX 失效时
    /// 自动调用 onDismiss 关闭切换器，避免键盘卡死。
    private var axWatchTimer: Timer?

    init() {
        // 注册 panel 到 HotkeyManager，使 isSwitcherOpen 计算属性能直接
        // 反映 panel.isVisible，消除手动同步导致的状态不一致。
        HotkeyManager.shared.setSwitcherPanel(panel)
    }

    deinit {
        if let global = globalMonitor { NSEvent.removeMonitor(global) }
        axWatchTimer?.invalidate()
    }

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

    /// True if the overlay panel is currently on screen.
    var isPresented: Bool { panel.isVisible }

    func present(with items: [WindowItem],
                 previewSize: AppSettings.PreviewSize,
                 displayTarget: AppSettings.DisplayTarget) {
        self.items = items
        self.previewSize = previewSize
        self.displayTarget = displayTarget
        self.selectedIndex = 0
        self.hoverIndex = nil
        // isSwitcherOpen 现在是计算属性，直接反映 panel.isVisible，
        // 无需手动设置。orderFrontRegardless 后自动变为 true。

        // 复用 hostingController：首次 present 时创建并 attach 到 panel，
        // 后续 present 只更新 @Published 属性（items/selectedIndex 等），
        // SwitcherOverlayView 通过 controller 引用自动响应变化。
        // 避免每次 Cmd+Tab 重建 SwiftUI 视图树造成的首帧延迟。
        if hostingController == nil {
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
        }

        positionPanel()
        panel.orderFrontRegardless()
        // Make the panel key so it accepts mouse clicks immediately (first click
        // works without needing to click twice).
        // 注意：不能用 NSApp.activate()——它会把 EasyMacTool 变成前台 app，
        // 原 frontmostApp 被顶下去，导致 WindowActivator 激活目标窗口时
        // AX 调用混乱、两种 releaseBehavior 模式都卡死。
        // nonactivatingPanel + makeKey() 已经能让 panel 接收点击事件。
        panel.makeKey()
        installDismissMonitor()
        startAXWatchTimer()
    }

    func dismiss() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        axWatchTimer?.invalidate()
        axWatchTimer = nil
        panel.orderOut(nil)
        // isSwitcherOpen 现在是计算属性，orderOut 后自动变为 false。
        HotkeyManager.shared.resetActiveShortcut()
        items = []
        selectedIndex = 0
        hoverIndex = nil
        // 不释放 hostingController —— 复用，下次 present 时不再重建视图树
    }

    /// 点击面板外部（鼠标按下事件发生在 panel frame 之外）时关闭切换器。
    /// 避免切换器常驻遮挡其他窗口/应用。
    private func installDismissMonitor() {
        // 幂等守卫：若已有 monitor 在监听，直接返回，避免连续 present()
        // 覆盖旧 monitor 引用导致 NSEvent monitor 永久泄漏。
        if globalMonitor != nil { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation
            let panelFrame = self.panel.frame
            // 检查鼠标位置是否在 panel frame 内：若在 panel 内则不 dismiss
            Task { @MainActor [weak self] in
                guard let self else { return }
                if panelFrame.contains(mouseLocation) { return }
                self.onDismiss?()
            }
        }
    }

    /// 启动 AX 权限监控定时器：切换器打开期间若 AX 被撤销，CGEventTap 失效，
    /// 键盘事件不再到达 handleKeyDown，用户无法用 Esc 关闭切换器。此定时器
    /// 每 1s 检查 isTrusted，失效时通过 onDismiss 自动关闭切换器。
    private func startAXWatchTimer() {
        axWatchTimer?.invalidate()
        axWatchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !AccessibilityChecker.isTrusted {
                self.onDismiss?()
            }
        }
    }

    func next() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
        // Keyboard navigation takes priority over mouse hover — clear the
        // visual aim so it doesn't linger on a different cell than selected.
        hoverIndex = nil
        // selectedIndex 的 didSet 已触发 notifySelectionChanged，无需显式调用。
    }

    func prev() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        hoverIndex = nil
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

    /// 从 items 列表移除已关闭/最小化的窗口并调整选中索引。
    /// 用于 .close/.minimize 后立即更新列表，避免用户继续 Tab 切到
    /// 已关闭的窗口（激活失败）。Windows Alt+Tab 也是立即移除。
    /// 移除后 selectedIndex 自动夹紧到有效范围；若列表变空则关闭切换器。
    func removeItem(_ item: WindowItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: idx)
        if items.isEmpty {
            // 所有窗口都关闭/最小化：关闭切换器
            onDismiss?()
            return
        }
        // 调整 selectedIndex：若移除的是当前选中项之前的，索引前移；
        // 若移除的是当前选中项或之后的，索引不变但需夹紧到有效范围。
        if idx < selectedIndex {
            selectedIndex -= 1
        } else if idx == selectedIndex {
            // 移除的就是当前选中项：保持 selectedIndex 指向同位置（下一个窗口）
            if selectedIndex >= items.count {
                selectedIndex = items.count - 1
            }
        }
        hoverIndex = nil
    }

    /// Mouse-click activation: select then commit (activate the window).
    func activate(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
        let item = items[index]
        onActivateItem?(item)
    }

    /// Notifies AppCoordinator that the selected window changed, so the live
    /// stream can switch to the newly selected window.
    private func notifySelectionChanged() {
        onSelectChanged?(selectedItem)
    }

    // MARK: - Private

    /// Selects the screen the switcher panel appears on, based on the
    /// configured `displayTarget`:
    /// - `.active`:  键盘焦点所在屏（nonactivatingPanel 场景 keyWindow 常为 nil，
    ///                fallback 到鼠标所在屏，再退到 NSScreen.main）
    /// - `.mouse`:   the screen under the current mouse cursor
    /// - `.menuBar`: the screen that contains the menu bar (primary display)
    private func selectScreen() -> NSScreen? {
        switch displayTarget {
        case .active:
            // nonactivatingPanel 场景下 NSApp.keyWindow 常为 nil，
            // fallback 到鼠标所在屏（比 NSScreen.main 更接近"活跃屏"），
            // 再退到 NSScreen.main。之前直接用 NSScreen.main 会取到含菜单栏
            // 的主屏，多屏副屏工作时面板出现在错误屏幕。
            if let screen = NSApp.keyWindow?.screen { return screen }
            let mouseLocation = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
                return screen
            }
            return NSScreen.main
        case .mouse:
            let mouseLocation = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        case .menuBar:
            // 主屏幕（含菜单栏）：Apple 文档保证 NSScreen.screens[0] 是主屏。
            return NSScreen.screens.first ?? NSScreen.main
        }
    }

    private func positionPanel() {
        guard let screen = selectScreen() else { return }
        let screenRect = screen.visibleFrame

        // 与 SwitcherOverlayView/WindowThumbnailCell 一致的布局参数。
        let interCell: CGFloat = DesignTokens.Spacing.md    // FlowLayout spacing
        let outerPadding: CGFloat = DesignTokens.Spacing.lg  // SwitcherOverlayView .padding(20)
        // 外层 padding(12) 已移除（背景直接撑满 hosting.view）。
        let panelPadding: CGFloat = 0
        let cellInnerPadding: CGFloat = 10  // WindowThumbnailCell .padding(10)
        let vStackSpacing: CGFloat = DesignTokens.Spacing.sm // VStack(spacing: 8)
        // 13pt .medium 系统字体的实际行高（含 ascender+descender+leading）约 17-18pt，
        // 用 18pt 留 1pt 余量，避免每个 cell 高度低估 1-2pt 累计导致面板高度不足。
        let captionHeight: CGFloat = 18
        // SwitcherOverlayView 当前只有 FlowLayout（无 header/footer），面板高度
        // 只需 contentHeight + padding，不再预留 headerHeight/footerHeight。

        // 精确计算每个 cell 的实际尺寸（与 WindowThumbnailCell.thumbnailSize 一致）。
        let cells: [CGSize] = items.map { item in
            let thumb = computeThumbnailSize(for: item)
            let cellWidth = thumb.width + cellInnerPadding * 2
            let cellHeight = thumb.height + cellInnerPadding * 2 + vStackSpacing + captionHeight
            return CGSize(width: cellWidth, height: cellHeight)
        }
        guard !cells.isEmpty else { return }

        // 最大可用宽度：屏幕 92%。
        let maxPanelWidth = screenRect.width * 0.92
        let maxInnerWidth = maxPanelWidth - outerPadding * 2 - panelPadding * 2

        // 两遍计算：消除 positionPanel 估算宽度与 FlowLayout 实际渲染宽度的不一致。
        //
        // 之前直接用 maxInnerWidth 估算换行，再把面板宽度收口为 contentWidth+padding。
        // 但 FlowLayout 实际拿到的可用宽度 = panelWidth-padding = contentWidth（比 maxInnerWidth 窄，
        // 且零余量）。边界项（如第 6 个 cell）在估算中落在第一行（W6 ≤ maxInnerWidth），
        // 但 FlowLayout 用 subview.sizeThatFits(.unspecified) 重新测量时可能有亚像素差异，
        // 导致 W6+ε > contentWidth → 换到第二行，而面板高度按 1 行算 → 第二行被 masksToBounds 裁掉。
        //
        // 修复：第一遍用 maxInnerWidth 估算得到 contentWidth；第二遍用 contentWidth+safetyMargin
        // 作为换行阈值（与 FlowLayout 实际可用宽度一致），重新算行数和高度。
        // safetyMargin=4 吸收亚像素差异，避免边界项被挤到下一行。

        // 第一遍：用 maxInnerWidth 估算换行，得到 contentWidth
        let rowsPass1 = computeLayoutRows(cells: cells, maxWidth: maxInnerWidth, interCell: interCell)
        let contentWidth = rowsPass1.map { $0.width }.max() ?? 0

        // 面板宽度：contentWidth + padding + safetyMargin（吸收亚像素差异）
        let safetyMargin: CGFloat = 4
        let width = min(contentWidth + outerPadding * 2 + panelPadding * 2 + safetyMargin, maxPanelWidth)
        // FlowLayout 实际可用宽度
        let actualInnerWidth = width - outerPadding * 2 - panelPadding * 2

        // 第二遍：用 actualInnerWidth 重新算行（与 FlowLayout 实际渲染一致）
        let rows = computeLayoutRows(cells: cells, maxWidth: actualInnerWidth, interCell: interCell)

        // 面板高度：按第二遍的行数计算
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

    /// 与 FlowLayout.computeRows 相同的换行逻辑：逐个 cell 尝试放入当前行，
    /// 超过 maxWidth 就换行。提取为独立方法避免 positionPanel 两遍计算重复代码。
    private func computeLayoutRows(cells: [CGSize], maxWidth: CGFloat, interCell: CGFloat)
        -> [(width: CGFloat, height: CGFloat, count: Int)] {
        var rows: [(width: CGFloat, height: CGFloat, count: Int)] = [(0, 0, 0)]
        for cellSize in cells {
            let currentRow = rows[rows.count - 1]
            let candidateWidth = currentRow.width
                + (currentRow.count > 0 ? interCell : 0)
                + cellSize.width
            if candidateWidth > maxWidth, currentRow.count > 0 {
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
        return rows
    }

    /// 与 WindowThumbnailCell.thumbnailSize 完全一致的缩略图尺寸计算。
    /// 保证 positionPanel 估算的 cell 尺寸与实际渲染一致，避免换行不匹配。
    private func computeThumbnailSize(for item: WindowItem) -> CGSize {
        let maxWidth = previewSize.thumbnailWidth
        let maxHeight = previewSize.thumbnailHeight
        if item.frame == .zero {
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
