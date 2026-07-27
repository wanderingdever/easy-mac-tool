import AppKit
import Combine
import SwiftUI

/// Bottom-of-screen clipboard history panel, Paste-style. A horizontal strip
/// of preview cards. Click a card to copy/restore that clipboard entry.
///
/// Layout: pinned to the bottom of the screen, full width, height = 1/5 of the
/// screen height. Cards scroll horizontally. Esc or click-outside dismisses.
struct ClipboardOverlayView: View {
    @ObservedObject var manager: ClipboardManager
    var autoPaste: Bool
    var onDismiss: () -> Void
    var onReapply: (ClipboardItem) -> Void

    @State private var query: String = ""
    @State private var hoverID: UUID?
    @State private var activeFilter: ClipboardItem.ContentKind?
    @State private var showFilterMenu: Bool = false

    /// 焦点管理：参考 Paste，默认焦点在卡片而非搜索框——这样用户呼出
    /// 面板后即可用 ←/→ 切换卡片、Enter 复制。需要搜索时主动点击搜索框
    /// 或按 ⌘F。Esc 在搜索态返回卡片，在卡片态关闭面板。
    @FocusState private var focusTarget: FocusTarget?

    /// 键盘选中索引：与 focusTarget=.cards 联动，用户可用 ←/→ 切换，
    /// 回车直接复制选中卡片。鼠标 hover 同步更新此索引，使键盘与鼠标
    /// 视觉状态一致。nil 表示无选中（仅当列表为空时）。
    @State private var selectedIndex: Int = 0

    /// 预览状态：previewItem 非 nil 时弹出放大卡片。previewVisible 驱动
    /// opacity 弹入动画。不改变面板高度——内容过长时由 RTFTextView 内部
    /// 上下滚动处理。
    /// 无全屏遮罩——预览悬浮在卡片上方，用阴影 + 圆角区分背景（tooltip 式）。
    @State private var previewItem: ClipboardItem?
    @State private var previewVisible: Bool = false

    /// 悬停 1 秒自动打开预览的计时器。鼠标进入卡片时启动，离开时取消。
    /// 计时器触发后调 openPreview。移走鼠标后延迟 0.3 秒关闭预览
    /// （给鼠标移到预览卡片上的时间）。
    @State private var hoverTimer: Timer?
    /// 关闭预览的延迟计时器。鼠标离开卡片后延迟 0.3 秒关闭，
    /// 若鼠标在此期间进入预览卡片则取消关闭。
    @State private var closeTimer: Timer?
    /// 鼠标是否在预览卡片内（用于延迟关闭的取消判断）。
    @State private var mouseInPreview: Bool = false

    private var previewIsOpen: Bool { previewItem != nil }

    private var filtered: [ClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return manager.items.filter { item in
            if let f = activeFilter, item.contentKind != f { return false }
            guard !q.isEmpty else { return true }
            return item.title.lowercased().contains(q) || item.footerText.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                searchBar
                Divider()
                // Spacer 把卡片条压到底部：面板在预览模式被拉高时，卡片仍贴底，
                // 预览放大卡片可向上溢出到 Spacer 留出的空白区。
                Spacer(minLength: 0)
                cardStrip
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                // Bottom-flush: no padding at the bottom so the panel sits directly
                // on the screen's bottom edge. Top has a small inset for the bar.
                // 背景更透明：ultraThinMaterial 已是最透明材质之一，叠加一层更低
                // opacity 的白色让整体更通透。
                UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 0, topTrailingRadius: 14)
                    .fill(.ultraThinMaterial.opacity(0.7))
                    .overlay(
                        UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 0,
                                               bottomTrailingRadius: 0, topTrailingRadius: 14)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 8)
            .padding(.top, 4)
            // No bottom padding — the panel's content reaches the screen edge.
            .padding(.bottom, 0)
            // Click anywhere outside the filter menu / preview to dismiss it.
            .contentShape(Rectangle())
            .onTapGesture {
                if showFilterMenu { showFilterMenu = false }
                if previewIsOpen { closePreview() }
            }
            // 仅对主内容禁用隐式动画（防止卡片增删/悬浮抖动）；预览浮层
            // 独立动画，不受此 transaction 影响。
            .transaction { $0.animation = nil }
            .animation(nil, value: manager.items.count)

            // 预览浮层：在所有内容之上，垂直居中弹入。
            if let item = previewItem {
                previewOverlay(item: item)
            }
        }
        // 键盘事件监听（局部 NSEvent monitor，随视图生命周期安装/卸载）。
        // 支持 ←/→ 切换卡片、回车复制选中卡片、空格预览。当搜索框有焦点
        // 时不拦截 ←/→/Enter，让 TextField 自然处理光标移动与提交。
        // 额外处理 ⌘F（切到搜索框）、Esc（搜索态返回卡片，卡片态关闭面板）。
        .background(ClipboardKeyObserver(
            onArrowLeft:  { handleArrow(direction: -1) },
            onArrowRight: { handleArrow(direction: +1) },
            onEnter:      { handleEnter() },
            onSpace:      { handleSpaceKey() },
            onCmdF:       { focusTarget = .search },
            onEsc: {
                if focusTarget == .search {
                    // 搜索态：清空查询 + 焦点回到卡片（不关闭面板）。
                    query = ""
                    focusTarget = .cards
                } else {
                    // 卡片态：关闭面板。
                    onDismiss()
                }
            }
        ).frame(width: 0, height: 0))
        // 搜索/筛选变化导致列表缩短时，把 selectedIndex 拉回有效范围。
        .onChange(of: query) { _, _ in clampSelection() }
        .onChange(of: activeFilter) { _, _ in
            selectedIndex = 0
            hoverID = nil
        }
        // 面板出现时默认焦点在卡片（非搜索框）。
        // 用 DispatchQueue.main.async 确保 SwiftUI 已完成首次布局，
        // 此时设置 focusTarget 才能正确推动 firstResponder。
        .onAppear {
            DispatchQueue.main.async {
                focusTarget = .cards
            }
        }
    }

    /// 卡片高度：以屏幕 1/4 高度推算，并卡死在 [120, 220] 区间。
    /// 卡死上限避免面板在预览模式被拉高时卡片跟着变大，保证卡片始终
    /// 贴底、预览可向上溢出。
    private var cardHeight: CGFloat {
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        // 78pt ≈ searchBar(56) + Divider(1) + vertical padding(20) + 余量(1)
        return min(220, max(120, screenH / 4 - 78))
    }

    // MARK: - Search bar (compact, centered)
    // 头部完全平铺：统计 | 搜索框+筛选 | 删除，三个功能区直接平级在同一个
    // HStack 里，给整个 HStack 固定高度。之前的嵌套 searchFieldGroup 结构
    // 中 TextField 在有内容时会突破外层 frame，导致头部高度变化。现在所有
    // 元素直接受同一个固定 frame 约束，彻底避免高度跳动。

    private var searchBar: some View {
        HStack(spacing: 12) {
            // 1. 统计数量（左）
            HStack(spacing: 5) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Text("\(filtered.count)/\(manager.items.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            // 2. 搜索框 + 筛选按钮（中）。
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField("搜索…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .frame(width: 160)
                    .lineLimit(1)
                    // 与卡片共享 @FocusState：仅当用户主动点击此处或按 ⌘F
                    // 时才获得焦点，避免面板出现时自动抢占焦点导致 ←/→ 失效。
                    .focused($focusTarget, equals: .search)
                filterButton
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.4))
            )
            // 筛选菜单 overlay 锚定在这个搜索框组的右上角，菜单紧贴筛选
            // 按钮下方出现。offset(y: 46) 让菜单越过 40pt 高度 + 一点间隙。
            .overlay(alignment: .topTrailing) {
                if showFilterMenu {
                    filterMenu
                        .offset(y: 46)
                        .zIndex(999)
                        .transition(.opacity)
                        .transaction { $0.animation = nil }
                        .onTapGesture { /* swallow */ }
                }
            }

            Spacer(minLength: 0)

            // 3. 删除按钮（右）
            Button(action: { manager.clearHistory() }) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("清空历史")
        }
        .padding(.horizontal, 16)
        // 头部高度加倍到 56pt，所有元素垂直居中。
        .frame(height: 56, alignment: .center)
        .zIndex(1)
    }

    private var filterButton: some View {
        Button {
            showFilterMenu.toggle()
        } label: {
            Image(systemName: activeFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(activeFilter == nil ? .secondary : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .help("筛选类型")
    }

    private var filterMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            filterRow(nil, label: "全部", symbol: "tray.full")
            Divider().padding(.vertical, 2)
            ForEach(ClipboardItem.ContentKind.allCases) { kind in
                filterRow(kind, label: kind.label, symbol: kind.symbol)
            }
        }
        .padding(8)
        .frame(width: 140)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }

    private func filterRow(_ kind: ClipboardItem.ContentKind?, label: String, symbol: String) -> some View {
        let isActive = (kind == nil && activeFilter == nil) || (kind != nil && activeFilter == kind)
        let tint = kind?.tint ?? NSColor.systemGray
        return Button {
            activeFilter = kind
            showFilterMenu = false
        } label: {
            HStack(spacing: 8) {
                // 彩色圆形图标背景：用种类颜色区分，选中时加深
                ZStack {
                    Circle()
                        .fill(Color(nsColor: tint).opacity(isActive ? 1.0 : 0.7))
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 18, height: 18)

                Text(label)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)

                Spacer()

                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.1) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Card strip
    // cardStrip 必须始终返回单个视图（而非 Group 内多视图）。
    // 之前空状态用 `Spacer, VStack, Spacer` 3 个视图，Group 对布局透明
    // 导致这 3 个视图直接成为父 VStack 的子视图，与非空状态的 1 个
    // ScrollView 子视图数量不一致——Spacer 注入父 VStack 后会改变布局
    // 测量，间接导致头部 searchBar 高度受影响（"有内容时头部高度变化"）。
    // 现在空状态包裹在单个 VStack 中，Spacer 在其内部，父 VStack 始终
    // 只有 searchBar / Divider / cardStrip 3 个子视图，布局稳定。

    @ViewBuilder
    private var cardStrip: some View {
        if filtered.isEmpty {
            VStack {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "剪切板为空" : "无匹配项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // GeometryReader 获取 cardStrip 可用高度，动态计算卡片高度，
            // 避免固定 200pt 在小屏（1/4 屏幕高）上溢出被裁剪。
            // cardHeight = 可用高度 - vertical padding(20) - 2pt 余量；
            // 同时卡死上限 220pt，避免面板在预览模式下被拉高时卡片跟着变大。
            GeometryReader { geo in
                HorizontalWheelScrollView {
                    HStack(spacing: 12) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            // 卡片高亮 = 鼠标 hover OR 键盘选中（任一为 true）。
                            // 视觉上鼠标与键盘状态合并，避免双重边框冲突。
                            let isHighlighted = hoverID == item.id || index == selectedIndex
                            ClipboardCard(item: item,
                                         isHover: isHighlighted,
                                         isDimmed: previewIsOpen && previewItem?.id != item.id,
                                         height: min(220, max(120, geo.size.height - 22)))
                                .onHover { hovering in
                                    if hovering {
                                        hoverID = item.id
                                        // 鼠标 hover 同步键盘选中索引，使回车
                                        // 复制时与视觉选中卡片一致。
                                        selectedIndex = index
                                        // 启动 1 秒悬停计时器自动打开预览。
                                        hoverTimer?.invalidate()
                                        hoverTimer = Timer.scheduledTimer(
                                            withTimeInterval: 1.0, repeats: false
                                        ) { _ in
                                            openPreview(item)
                                        }
                                    } else {
                                        if hoverID == item.id { hoverID = nil }
                                        // 鼠标离开卡片：取消悬停计时器，
                                        // 延迟 0.3 秒关闭预览（给鼠标移到
                                        // 预览卡片上的时间）。
                                        hoverTimer?.invalidate()
                                        scheduleClosePreview()
                                    }
                                }
                                .onTapGesture {
                                    selectedIndex = index
                                    // 点击卡片后焦点切回卡片区，便于后续键盘操作。
                                    focusTarget = .cards
                                    if previewIsOpen { closePreview() }
                                    else { onReapply(item) }
                                }
                                .contextMenu {
                                    Button("预览") {
                                        selectedIndex = index
                                        focusTarget = .cards
                                        openPreview(item)
                                    }
                                    Button("复制") {
                                        selectedIndex = index
                                        focusTarget = .cards
                                        onReapply(item)
                                    }
                                    Divider()
                                    Button("删除") { manager.remove(item) }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            // 卡片容器绑定 @FocusState：默认 focusTarget=.cards（在 onAppear 中设置）。
            // SwiftUI 的 .focusable + .focused 让卡片容器成为 firstResponder 候选，
            // 阻止 NSPanel 默认把 TextField 设为 firstResponder。
            .focusable()
            .focused($focusTarget, equals: .cards)
        }
    }

    // MARK: - Preview

    /// 预览浮层：tooltip 式悬浮在面板上方，无全屏遮罩。
    /// 用阴影 + 圆角边框区分预览与背景。鼠标可移入预览区域
    /// （进入时取消关闭计时器，离开时关闭预览）。
    @ViewBuilder
    private func previewOverlay(item: ClipboardItem) -> some View {
        // 无全屏遮罩——预览直接悬浮在卡片上方。
        // 垂直居中的放大卡片：高度自适应面板可用空间（不超过屏高 70%）。
        GeometryReader { geo in
            let maxH = min(geo.size.height - 16, (NSScreen.main?.visibleFrame.height ?? 800) * 0.7)
            ClipboardPreviewCard(item: item,
                                isExpanded: previewVisible,
                                onClose: { closePreview() },
                                onApply: { onReapply(item); closePreview() })
                .frame(width: 560, height: max(240, maxH))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                // 鼠标进入预览：取消关闭计时器
                .onHover { hovering in
                    if hovering {
                        mouseInPreview = true
                        closeTimer?.invalidate()
                    } else {
                        mouseInPreview = false
                        scheduleClosePreview()
                    }
                }
        }
        .opacity(previewVisible ? 1 : 0)
        .zIndex(1000)
    }

    private func openPreview(_ item: ClipboardItem) {
        // 取消任何待关闭的计时器
        closeTimer?.invalidate()
        previewItem = item
        withAnimation(.easeOut(duration: 0.2)) {
            previewVisible = true
        }
    }

    private func closePreview() {
        hoverTimer?.invalidate()
        closeTimer?.invalidate()
        withAnimation(.easeOut(duration: 0.2)) {
            previewVisible = false
        }
        // 等动画结束后再移除视图，避免突兀消失。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            if !previewVisible {
                previewItem = nil
            }
        }
    }

    /// 延迟 0.3 秒关闭预览。若鼠标在此期间进入预览卡片则取消关闭。
    private func scheduleClosePreview() {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            if !mouseInPreview {
                closePreview()
            }
        }
    }

    /// 空格键触发：若预览已开则关闭；否则预览当前选中卡片。
    private func handleSpaceKey() {
        let editingText = NSApp.keyWindow?.firstResponder is NSTextView
        if previewIsOpen {
            closePreview()
        } else if !editingText,
                  filtered.indices.contains(selectedIndex) {
            openPreview(filtered[selectedIndex])
        }
    }

    /// ←/→ 切换选中卡片。搜索框聚焦时不拦截，让 TextField 处理光标移动。
    private func handleArrow(direction: Int) {
        let editingText = NSApp.keyWindow?.firstResponder is NSTextView
        guard !editingText, !filtered.isEmpty else { return }
        if previewIsOpen { closePreview() }
        // 循环导航：到达边界后绕回另一端。
        let count = filtered.count
        selectedIndex = (selectedIndex + direction + count) % count
    }

    /// 回车复制当前选中卡片。搜索框聚焦时不拦截（让 TextField 提交）。
    private func handleEnter() {
        let editingText = NSApp.keyWindow?.firstResponder is NSTextView
        guard !editingText, filtered.indices.contains(selectedIndex) else { return }
        let item = filtered[selectedIndex]
        if previewIsOpen { closePreview() }
        onReapply(item)
    }

    /// 搜索/筛选导致列表缩短时，把 selectedIndex 拉回有效范围；
    /// 列表为空时置 0（cardStrip 空状态会兜底）。
    private func clampSelection() {
        guard !filtered.isEmpty else { selectedIndex = 0; return }
        if selectedIndex >= filtered.count { selectedIndex = filtered.count - 1 }
        if selectedIndex < 0 { selectedIndex = 0 }
    }
}

/// 局部 NSEvent 监听键盘事件。随宿主视图生命周期安装/卸载。
/// 监听键：←(123) →(124) Enter(36) Space(49) ⌘F(3+cmdMask) Esc(53)。
/// 仅在面板内捕获；当 firstResponder 是 NSTextView（搜索框）时不拦截
/// ←/→/Enter，让 TextField 自然处理光标移动与提交。⌘F 与 Esc 全局拦截。
private struct ClipboardKeyObserver: NSViewRepresentable {
    final class Coordinator {
        var onArrowLeft: () -> Void = {}
        var onArrowRight: () -> Void = {}
        var onEnter: () -> Void = {}
        var onSpace: () -> Void = {}
        var onCmdF: () -> Void = {}
        var onEsc: () -> Void = {}
        var monitor: Any?
    }

    var onArrowLeft: () -> Void
    var onArrowRight: () -> Void
    var onEnter: () -> Void
    var onSpace: () -> Void
    var onCmdF: () -> Void
    var onEsc: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc 始终拦截：搜索态清空查询回卡片，卡片态关闭面板。
            // ClipboardPanelController 不再监听 Esc，全部由此处统一处理。
            if event.keyCode == 53 {  // Esc
                coordinator.onEsc()
                return nil
            }
            // ⌘F：切换到搜索框。keyCode 3 = 'F'。
            if event.keyCode == 3 && event.modifierFlags.contains(.command) {
                coordinator.onCmdF()
                return nil
            }
            // keyCode: 123=←, 124=→, 36=Enter, 49=Space
            switch event.keyCode {
            case 123:  // left arrow
                let editing = NSApp.keyWindow?.firstResponder is NSTextView
                if editing { return event }
                coordinator.onArrowLeft()
                return nil
            case 124:  // right arrow
                let editing = NSApp.keyWindow?.firstResponder is NSTextView
                if editing { return event }
                coordinator.onArrowRight()
                return nil
            case 36:   // Enter
                let editing = NSApp.keyWindow?.firstResponder is NSTextView
                if editing { return event }
                coordinator.onEnter()
                return nil
            case 49:   // space
                coordinator.onSpace()
                return nil
            default:
                return event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onArrowLeft = onArrowLeft
        coordinator.onArrowRight = onArrowRight
        coordinator.onEnter = onEnter
        coordinator.onSpace = onSpace
        coordinator.onCmdF = onCmdF
        coordinator.onEsc = onEsc
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }
}

/// 焦点目标：卡片容器（默认）或搜索框。配合 @FocusState 让面板出现时
/// firstResponder 是卡片容器，而非 TextField——这样 ←/→/Enter 直接生效，
/// 不会被 TextField 拦截。用户点击搜索框或按 ⌘F 才切换到搜索态。
private enum FocusTarget: Hashable {
    case cards
    case search
}

/// 放大预览卡片：与常规 ClipboardCard 同结构（header/middle/footer），
/// 但内容完整可滚动（RTFTextView 无行数限制、图片文件异步加载预览、
/// 链接显示完整 URL）。footer 含操作按钮。
private struct ClipboardPreviewCard: View {
    let item: ClipboardItem
    let isExpanded: Bool
    var onClose: () -> Void
    var onApply: () -> Void

    /// 异步加载的图片文件预览（仅 .file kind 且为图片文件时）。
    @State private var loadedFileImage: NSImage?

    private var headerForeground: Color {
        let ns = item.sourceAppTint.usingColorSpace(.sRGB) ?? NSColor.systemBlue.usingColorSpace(.sRGB)!
        let luminance = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 4)
        .task {
            // 若为单图片文件，异步加载 NSImage 预览。
            if case .file(let urls) = item.kind,
               let url = urls.first,
               urls.count == 1,
               ClipboardItem.isImageFile(url) {
                let img = NSImage(contentsOf: url)
                await MainActor.run { loadedFileImage = img }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = item.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
            }
            Text(item.sourceAppName ?? "未知")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(item.typeLabel)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(headerForeground.opacity(0.2)))
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(headerForeground.opacity(0.8))
            }
            .buttonStyle(.borderless)
            .help("关闭")
        }
        .foregroundStyle(headerForeground)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color(nsColor: item.sourceAppTint), Color(nsColor: item.sourceAppTint).opacity(0.72)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .clipShape(TopRoundedShape(radius: 12))
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text(let s):
            // RTFTextView 支持富文本（保留代码颜色）+ 滚动，可显示完整长文本。
            RTFTextView(rtfData: item.rtfData,
                       plainText: s,
                       font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let img):
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .url(let url, _):
            // 链接预览：显示 host、path、完整 URL 与「打开」按钮。
            VStack(spacing: 12) {
                Image(systemName: "link.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                VStack(spacing: 4) {
                    Text(url.host ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if !url.path.isEmpty, url.path != "/" {
                        Text(url.path)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                Text(url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                if isExpanded {
                    Button("在浏览器中打开") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 12)
        case .file(let urls):
            // 图片文件预览：已异步加载 NSImage 时显示。
            if let img = loadedFileImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: urls.count == 1 ? "doc" : "doc.on.doc")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    if let first = urls.first {
                        Text(first.lastPathComponent)
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .color(let color, let hex):
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: color))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                Text(hex.uppercased())
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Text(item.footerText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button(action: onApply) {
                Label("复制", systemImage: "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
        .clipShape(BottomRoundedShape(radius: 12))
    }
}

/// A single Paste-style preview card with a top-middle-bottom structure:
/// - Top header: app-tinted background, app icon (left), type label + time-
///   ago (right).
/// - Middle: content preview (text / image / URL / file / color).
/// - Bottom footer: transparent floating strip, centered single-line stat.
private struct ClipboardCard: View {
    let item: ClipboardItem
    let isHover: Bool
    /// 预览开启时其他卡片被淡化以突出预览中的卡片。
    var isDimmed: Bool = false
    /// 卡片高度由父 cardStrip 通过 GeometryReader 动态传入，适配不同
    /// 屏幕尺寸的 1/4 屏幕面板高度。最低 120pt 保证内容可见。
    let height: CGFloat

    /// 异步加载的图片文件预览（仅 .file kind 且为单图片文件时）。
    @State private var loadedFileImage: NSImage?

    /// Card width stays modest so many cards fit horizontally.
    private let cardWidth: CGFloat = 230

    /// Decide whether the header text should be light or dark based on the
    /// tint's luminance — keeps the type/time legible on any app color.
    private var headerForeground: Color {
        // Convert to sRGB first — catalog colors (e.g. .systemBlue fallback)
        // don't expose redComponent/greenComponent/blueComponent directly and
        // will raise an exception if accessed without a color-space conversion.
        let ns = item.sourceAppTint.usingColorSpace(.sRGB) ?? NSColor.systemBlue.usingColorSpace(.sRGB)!
        let luminance = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            middle
            footer
        }
        .frame(width: cardWidth, height: height)
        .background(
            // 背景不透明：用接近白色的不透明背景增强卡片层次感，
            // 避免扁平化。深色模式下用稍深的背景区分。
            RoundedRectangle(cornerRadius: 12)
                .fill(isHover ? Color.accentColor.opacity(0.15) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isHover ? Color.accentColor.opacity(0.7) : .black.opacity(0.1),
                              lineWidth: 1)
        )
        // 增加阴影增强层次感，避免扁平化
        .shadow(color: .black.opacity(0.15), radius: isHover ? 8 : 4, y: 2)
        .scaleEffect(isHover ? 1.04 : 1.0)
        .opacity(isDimmed ? 0.4 : 1.0)
        .transaction { $0.animation = nil }
        .task {
            // 单图片文件异步加载缩略图，避免阻塞 UI。
            if case .file(let urls) = item.kind,
               let url = urls.first,
               urls.count == 1,
               ClipboardItem.isImageFile(url) {
                let img = NSImage(contentsOf: url)
                await MainActor.run { loadedFileImage = img }
            }
        }
    }

    // MARK: - Top header

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = item.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
            }
            Text(item.sourceAppName ?? "未知")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(item.typeLabel)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(headerForeground.opacity(0.2)))
            Text(RelativeTimeFormatter.string(from: item.createdAt, now: Date()))
                .font(.system(size: 10))
                .foregroundStyle(headerForeground.opacity(0.8))
        }
        .foregroundStyle(headerForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [Color(nsColor: item.sourceAppTint), Color(nsColor: item.sourceAppTint).opacity(0.72)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .clipShape(TopRoundedShape(radius: 12))
    }

    // MARK: - Middle content

    private var middle: some View {
        previewContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var previewContent: some View {
        switch item.kind {
        case .text(let s):
            // 若有 RTF 富文本（如 VSCode/Xcode 复制的代码），用 AttributedString
            // 渲染保留颜色/字体样式；否则回退普通 Text。Text 不可交互，不拦截
            // 卡片的点击/右键。
            if let rtf = item.rtfData,
               let nsAttr = try? NSAttributedString(
                   data: rtf,
                   options: [.documentType: NSAttributedString.DocumentType.rtf],
                   documentAttributes: nil) {
                Text(AttributedString(nsAttr))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(12)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            } else {
                Text(s.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(12)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            }
        case .url(let url, _):
            VStack(spacing: 8) {
                Image(systemName: "link.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text(url.host ?? url.absoluteString)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        case .image(let img):
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(8)
        case .file(let urls):
            // 单图片文件已加载缩略图时直接展示，否则显示文件图标。
            if let img = loadedFileImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: urls.count == 1 ? "doc" : "doc.on.doc")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    if let first = urls.first {
                        Text(first.lastPathComponent)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }
                }
            }
        case .color(let color, let hex):
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: color))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
                Text(hex.uppercased())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bottom footer

    private var footer: some View {
        HStack {
            Spacer()
            Text(item.footerText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
        .clipShape(BottomRoundedShape(radius: 12))
    }
}

/// Clips the top corners with the given radius, leaving the bottom corners
/// square so the header sits flush against the middle content.
private struct TopRoundedShape: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Clips the bottom corners with the given radius, leaving the top corners
/// square so the footer's top edge sits flush against the middle content.
private struct BottomRoundedShape: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
