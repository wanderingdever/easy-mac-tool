import AppKit
import Combine
import SwiftUI

/// Bottom-of-screen clipboard history panel, Paste-style. A horizontal strip
/// of preview cards. Click a card to copy/restore that clipboard entry.
///
/// Layout: pinned to the bottom of the screen, full width, height = 1/4 of the
/// screen height. Cards scroll horizontally. Esc or click-outside dismisses.
///
/// 性能优化：
/// - `controller` 改用 @ObservedObject，回调通过 controller 方法调用——
///   避免 present 时构造新闭包导致 SwiftUI diff 与重渲染。
/// - `filtered` 缓存到 @State，仅在 query/items/filter 变化时重算，
///   避免每次 body 访问都重过滤（多次访问：isEmpty / count / ForEach）。
struct ClipboardOverlayView: View {
    @ObservedObject var manager: ClipboardManager
    @ObservedObject var controller: ClipboardPanelController

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
    /// opacity/scale 弹入动画。不改变面板高度——内容过长时由 RTFTextView 内部
    /// 上下滚动处理。
    /// 无全屏遮罩——预览悬浮在卡片上方，用阴影 + 圆角区分背景（tooltip 式）。
    /// 仅通过右键菜单「预览」或空格键触发，不再 hover 自动弹出。
    @State private var previewItem: ClipboardItem?
    @State private var previewVisible: Bool = false

    /// 面板出现动画驱动：onAppear 时切换为 true，触发 opacity + 上移动画。
    @State private var panelAppeared: Bool = false

    /// 清空全部历史前的确认弹窗。
    @State private var showClearAlert: Bool = false

    /// 过滤后的卡片列表（计算属性）。
    /// 之前用 @State filtered + onReceive(manager.$items) 手动更新，但右键菜单
    /// (NSMenu) 的 modal session 会延迟 onReceive 回调，导致删除/新增后 UI 不
    /// 立即刷新。改为计算属性后，manager.items（@Published）的任何变化都会
    /// 通过 @ObservedObject 自动触发 body 重绘，filtered 随之重算。
    /// 性能：body 中多次访问 filtered 会多次计算，但 manager.items 通常 ≤ 100，
    /// filter 闭包开销可忽略；真正昂贵的是卡片渲染（已用 LazyHStack 懒加载）。
    private var filtered: [ClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return manager.items.filter { item in
            if let f = activeFilter, item.contentKind != f { return false }
            guard !q.isEmpty else { return true }
            return item.title.lowercased().contains(q) || item.footerText.lowercased().contains(q)
        }
    }

    private var previewIsOpen: Bool { previewItem != nil }

    var body: some View {
        // filtered 在本帧只计算一次，作为参数下传给 searchBar / cardStrip。
        // 之前 filtered 是计算属性，body 中 searchBar(count)、cardStrip
        // (isEmpty + ForEach)各独立访问，每次 body 重绘过滤闭包跑 3 遍。
        // 鼠标滚动时 hoverID 变化触发 body 重绘，导致每帧 3 倍过滤成本
        // （含 footerText 对大文本的 trimming/split）。改局部 let 下传后
        // 降至 1 倍。handleSpaceKey/handleArrow/handleEnter/clampSelection
        // 是事件处理方法，不在滚动热路径上，仍直接访问 filtered 计算属性。
        let filteredItems = filtered
        return ZStack {
            VStack(spacing: 0) {
                searchBar(filtered: filteredItems)
                // Aurora v2：渐变发丝分隔线替代生硬 Divider，两端渐隐。
                DesignTokens.Aurora.brandHorizontal
                    .opacity(0.25)
                    .frame(height: 1)
                    .mask(
                        LinearGradient(colors: [.clear, .black, .black, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .padding(.horizontal, 20)
                // Spacer 把卡片条压到底部：面板在预览模式被拉高时，卡片仍贴底，
                // 预览放大卡片可向上溢出到 Spacer 留出的空白区。
                Spacer(minLength: 0)
                cardStrip(filtered: filteredItems)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                // Aurora v2：全浮动玻璃卡片（四边留白、圆角 20）。
                // 层序：ultraThinMaterial 底 → 极光微光 sheen → 白色发丝描边 →
                // 顶部玻璃反光高光线。阴影由 NSPanel.hasShadow 依内容 alpha 渲染。
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.85))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(DesignTokens.Aurora.glassSheen)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        )
                    // 顶部发丝高光线（玻璃上缘反光），两端渐隐。
                    DesignTokens.Aurora.glassEdgeLight
                        .frame(height: 1)
                        .mask(
                            LinearGradient(colors: [.clear, .black, .black, .clear],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 0.5)
                }
            )
            .padding(.horizontal, 10)
            .padding(.top, 6)
            // 底部同步留白：卡片完全浮起，不再贴屏幕底边。
            .padding(.bottom, 10)
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
            // 面板出现动画：opacity + 轻微上移，spring 更流畅。
            .opacity(panelAppeared ? 1 : 0)
            .offset(y: panelAppeared ? 0 : 24)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: panelAppeared)

            // 预览浮层：在所有内容之上，垂直居中弹入。
            if let item = previewItem {
                previewOverlay(item: item)
            }
        }
        .alert("清空全部剪切板历史？", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) { manager.clearHistory() }
        } message: {
            Text("此操作不可撤销，将删除所有 \(manager.items.count) 条记录。")
        }
        // 键盘事件监听（局部 NSEvent monitor，随视图生命周期安装/卸载）。
        // 支持 ←/→ 切换卡片、回车复制选中卡片、空格预览。当搜索框有焦点
        // 时不拦截 ←/→/Enter，让 TextField 自然处理光标移动与提交。
        // 额外处理 ⌘F（切到搜索框）、Esc（搜索态返回卡片，卡片态关闭面板）。
        .background(ClipboardKeyObserver(
            isActive: controller.isPresented,
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
                    controller.dismiss()
                }
            },
            isEditingText: { focusTarget == .search }
        ).frame(width: 0, height: 0))
        // 搜索/筛选变化导致列表缩短时，把 selectedIndex 拉回有效范围。
        // filtered 是计算属性，manager.items 变化时自动重算，无需手动刷新。
        .onChange(of: query) { _, _ in
            clampSelection()
        }
        .onChange(of: activeFilter) { _, _ in
            selectedIndex = 0
            hoverID = nil
        }
        // 删除卡片后 manager.items.count 变化，selectedIndex 可能越界——clamp 回有效范围。
        .onChange(of: manager.items.count) { _, _ in
            clampSelection()
        }
        // 面板出现时默认焦点在卡片（非搜索框）。
        // 策略：ClipboardPanelController.present() 在 panel.makeKey() 后主动
        // makeFirstResponder(hosting.view)，阻止 NSPanel 默认抢设搜索框；
        // 这里在 onAppear 中显式设置 focusTarget = .cards，让 SwiftUI 的
        // .focused($focusTarget, equals: .cards) 把 firstResponder 推到卡片容器。
        // 用 DispatchQueue.main.async 确保 SwiftUI 已完成首次布局，且 panel
        // 的 makeFirstResponder 调用已落地，此时设置 focusTarget 才能正确推动。
        .onAppear {
            // 触发面板出现动画：下一 render pass 切换 panelAppeared=true，
            // 让 .animation(.spring...) 观察 opacity/offset 的变化并播放。
            DispatchQueue.main.async {
                panelAppeared = true
                focusTarget = .cards
            }
        }
        // 面板每次重新打开（isPresented false→true）时重置视图状态：
        // 让焦点回到第一张（最新）卡片，清空搜索/筛选/预览。
        // hostingController 常驻导致 @State 在 dismiss 后仍保留，若不重置
        // 用户每次打开都会看到上次的位置/搜索词/预览状态。
        // filtered 是计算属性，自动反映 manager.items 最新状态，无需手动刷新。
        .onChange(of: controller.isPresented) { _, isPresented in
            if isPresented {
                selectedIndex = 0
                hoverID = nil
                query = ""
                activeFilter = nil
                previewItem = nil
                previewVisible = false
                showFilterMenu = false
                focusTarget = .cards
                // 修复：onAppear 只在首次 present 触发（hostingController 常驻），
                // 必须在此处重新置 true，否则 dismiss 后 panelAppeared 永远为 false，
                // 面板内容 opacity=0、再次 present 时不可见。
                // 用 DispatchQueue.main.async 延后一拍，让 opacity/offset 先回到
                // 初值再触发 spring 动画重放（与 onAppear 写法一致）。
                DispatchQueue.main.async {
                    panelAppeared = true
                }
            } else {
                // dismiss 后重置 panelAppeared，使下次 present 时入场动画
                // （spring 滑入）能正常播放。之前不重置导致第二次打开
                // 面板时直接显示而无动画。
                panelAppeared = false
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

    private func searchBar(filtered: [ClipboardItem]) -> some View {
        HStack(spacing: 12) {
            // 1. 统计数量（左）：渐变图标 chip + 计数（Aurora v2）。
            HStack(spacing: 8) {
                AuroraIconChip(systemName: "list.clipboard", size: 26)
                Text("\(filtered.count) 条")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            // 2. 搜索框 + 筛选按钮（中）：胶囊玻璃搜索框。
            // 聚焦时外圈品牌渐变描边（聚焦环），非聚焦发丝描边。
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(focusTarget == .search
                                     ? AnyShapeStyle(DesignTokens.Aurora.brandGradient)
                                     : AnyShapeStyle(.secondary))
                TextField("搜索…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .frame(width: 170)
                    .lineLimit(1)
                    // 与卡片共享 @FocusState：仅当用户主动点击此处或按 ⌘F
                    // 时才获得焦点，避免面板出现时自动抢占焦点导致 ←/→ 失效。
                    .focused($focusTarget, equals: .search)
                filterButton
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                // 聚焦环：品牌渐变 1.5pt，仅搜索态可见。
                Capsule()
                    .strokeBorder(DesignTokens.Aurora.brandGradient,
                                  lineWidth: focusTarget == .search ? 1.5 : 0)
                    .opacity(focusTarget == .search ? 1 : 0)
            )
            // 筛选菜单 overlay 锚定在这个搜索框组的右上角，菜单紧贴筛选
            // 按钮下方出现。offset(y: 42) 让菜单越过 36pt 高度 + 一点间隙。
            .overlay(alignment: .topTrailing) {
                if showFilterMenu {
                    filterMenu
                        .offset(y: 42)
                        .zIndex(999)
                        .transition(.opacity)
                        .transaction { $0.animation = nil }
                        .onTapGesture { /* swallow */ }
                }
            }

            Spacer(minLength: 0)

            // 3. 删除按钮（右）—— 圆形 hover 红色淡底，点击弹出确认 alert。
            ClearHistoryButton { showClearAlert = true }
        }
        .padding(.horizontal, 16)
        // 头部高度 58pt，所有元素垂直居中。
        .frame(height: 58, alignment: .center)
        .zIndex(1)
    }

    private var filterButton: some View {
        Button {
            showFilterMenu.toggle()
        } label: {
            Image(systemName: activeFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(activeFilter == nil
                                 ? AnyShapeStyle(.secondary)
                                 : AnyShapeStyle(DesignTokens.Aurora.brandGradient))
        }
        .buttonStyle(.borderless)
        .help("筛选类型")
    }

    private var filterMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            filterRow(nil, label: "全部")
            Rectangle()
                .fill(DesignTokens.Aurora.insetSeparator)
                .frame(height: 1)
                .padding(.vertical, 3)
            ForEach(ClipboardItem.ContentKind.allCases) { kind in
                filterRow(kind, label: kind.label)
            }
        }
        .padding(8)
        .frame(width: 148)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DesignTokens.Aurora.glassSheen)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
        )
        .shadow(color: DesignTokens.Aurora.floatShadowColor, radius: 12, y: 4)
    }

    private func filterRow(_ kind: ClipboardItem.ContentKind?, label: String) -> some View {
        let isActive = (kind == nil && activeFilter == nil) || (kind != nil && activeFilter == kind)
        // 设计稿指定 6 色固定圆点色值（不再依赖 kind.tint 派生色）。
        let dotColor = filterDotColor(for: kind)
        return Button {
            activeFilter = kind
            showFilterMenu = false
        } label: {
            HStack(spacing: 8) {
                // 类型圆点（18×18）：颜色区分种类，选中态全亮 + 微光晕。
                Circle()
                    .fill(dotColor.opacity(isActive ? 1.0 : 0.7))
                    .frame(width: 18, height: 18)
                    .shadow(color: dotColor.opacity(isActive ? 0.45 : 0), radius: 3)

                Text(label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)

                Spacer()

                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DesignTokens.Aurora.brandGradient)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive
                          ? AnyShapeStyle(DesignTokens.Aurora.brandGradient.opacity(0.12))
                          : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 设计稿固定的筛选圆点颜色（6 类）。
    private func filterDotColor(for kind: ClipboardItem.ContentKind?) -> Color {
        switch kind {
        case nil:       return DesignTokens.FilterDot.all
        case .text:     return DesignTokens.FilterDot.text
        case .link:     return DesignTokens.FilterDot.link
        case .image:    return DesignTokens.FilterDot.image
        case .file:     return DesignTokens.FilterDot.file
        case .color:    return DesignTokens.FilterDot.color
        }
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
    private func cardStrip(filtered: [ClipboardItem]) -> some View {
        if filtered.isEmpty {
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    // Aurora v2 空状态：渐变淡底圆形托底 + 渐变图标。
                    ZStack {
                        Circle()
                            .fill(DesignTokens.Aurora.brandGradient.opacity(0.10))
                        Image(systemName: query.isEmpty ? "tray" : "magnifyingglass")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(DesignTokens.Aurora.brandGradient)
                    }
                    .frame(width: 56, height: 56)
                    Text(query.isEmpty ? "剪切板为空" : "无匹配项")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    if query.isEmpty {
                        Text("复制的内容会自动出现在这里")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
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
                    // LazyHStack 仅渲染可见卡片 + 缓冲区，避免 100 条卡片
                    // 同时渲染导致的内存浪费与滚动卡顿。HStack 会一次性构建
                    // 所有子视图，每张卡片的 RTF 解析/图片解码都立即执行，
                    // 100 条历史时滚动明显掉帧。
                    LazyHStack(spacing: 12) {
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
                                    } else {
                                        if hoverID == item.id { hoverID = nil }
                                    }
                                }
                                .onTapGesture {
                                    selectedIndex = index
                                    // 点击卡片后焦点切回卡片区，便于后续键盘操作。
                                    focusTarget = .cards
                                    if previewIsOpen { closePreview() }
                                    else { reapply(item) }
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
                                        reapply(item)
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
            // 注意：.focusable() 会自动给获得焦点的视图加默认蓝色 focus ring，
            // 用 .focusEffectDisabled() 关掉——选中态由卡片自身的 isHover 边框表达。
            .focusable()
            .focusEffectDisabled()
            .focused($focusTarget, equals: .cards)
        }
    }

    // MARK: - Preview

    /// 预览浮层：tooltip 式悬浮在面板上方，无全屏遮罩。
    /// 用阴影 + 圆角边框区分预览与背景。
    /// 仅通过右键菜单「预览」或空格键触发，关闭方式：
    /// 关闭按钮 / Esc / 点击面板背景 / 点击其他卡片。
    @ViewBuilder
    private func previewOverlay(item: ClipboardItem) -> some View {
        // 无全屏遮罩——预览直接悬浮在卡片上方。
        // 垂直居中的放大卡片：高度自适应面板可用空间（不超过屏高 70%）。
        GeometryReader { geo in
            let maxH = min(geo.size.height - 16, (NSScreen.main?.visibleFrame.height ?? 800) * 0.7)
            ClipboardPreviewCard(item: item,
                                isExpanded: previewVisible,
                                onClose: { closePreview() },
                                onApply: { reapply(item); closePreview() })
                .frame(width: 560, height: max(240, maxH))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .opacity(previewVisible ? 1 : 0)
        .scaleEffect(previewVisible ? 1.0 : 0.92, anchor: .center)
        .animation(.spring(response: 0.42, dampingFraction: 0.6), value: previewVisible)
        .zIndex(1000)
    }

    private func openPreview(_ item: ClipboardItem) {
        previewItem = item
        // 两阶段渲染：先设 previewVisible=false（初始 scale 0.92/opacity 0），
        // 下一 render pass 切换为 true，让 SwiftUI 观察到值变化播放 spring 动画。
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) {
                previewVisible = true
            }
        }
    }

    private func closePreview() {
        let closedID = previewItem?.id
        withAnimation(.easeOut(duration: 0.18)) {
            previewVisible = false
        }
        // 等动画结束后再移除视图，避免突兀消失。
        // 捕获关闭时的 item id，0.2s 后比较才置 nil——防止快速关再开预览时
        // 旧 closePreview 的 asyncAfter 误清新的 previewItem。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !previewVisible, previewItem?.id == closedID {
                previewItem = nil
            }
        }
    }

    /// 触发复制/重应用：通过 controller 路由，避免在视图内捕获大量闭包。
    private func reapply(_ item: ClipboardItem) {
        controller.dismiss()
        controller.onReapply?(item)
    }

    /// 空格键触发：若预览已开则关闭；否则预览当前选中卡片。
    private func handleSpaceKey() {
        // 用 focusTarget 判断搜索框聚焦，避免 NSApp.keyWindow 在 nonactivatingPanel
        // 场景下取错导致误判。
        let editingText = focusTarget == .search
        if previewIsOpen {
            closePreview()
        } else if !editingText,
                  filtered.indices.contains(selectedIndex) {
            openPreview(filtered[selectedIndex])
        }
    }

    /// ←/→ 切换选中卡片。搜索框聚焦时不拦截，让 TextField 处理光标移动。
    private func handleArrow(direction: Int) {
        let editingText = focusTarget == .search
        guard !editingText, !filtered.isEmpty else { return }
        if previewIsOpen { closePreview() }
        // 循环导航：到达边界后绕回另一端。
        let count = filtered.count
        selectedIndex = (selectedIndex + direction + count) % count
    }

    /// 回车复制当前选中卡片。搜索框聚焦时不拦截（让 TextField 提交）。
    private func handleEnter() {
        let editingText = focusTarget == .search
        guard !editingText, filtered.indices.contains(selectedIndex) else { return }
        let item = filtered[selectedIndex]
        if previewIsOpen { closePreview() }
        reapply(item)
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
        /// 由父视图传入的焦点判断闭包。用 focusTarget == .search 替代
        /// NSApp.keyWindow?.firstResponder is NSTextView——后者在 nonactivatingPanel
        /// 场景下可能取错 key window 导致误判，且会被预览态的 selectable NSTextView 干扰。
        var isEditingText: () -> Bool = { false }
        var monitor: Any?

        func updateMonitoring(isActive: Bool) {
            if isActive, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    return self.handle(event)
                }
            } else if !isActive, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if event.keyCode == 53 {  // Esc
                onEsc()
                return nil
            }
            if event.keyCode == 3 && event.modifierFlags.contains(.command) {
                onCmdF()
                return nil
            }
            switch event.keyCode {
            case 123:
                if isEditingText() { return event }
                onArrowLeft()
                return nil
            case 124:
                if isEditingText() { return event }
                onArrowRight()
                return nil
            case 36:
                if isEditingText() { return event }
                onEnter()
                return nil
            case 49:
                if isEditingText() { return event }
                onSpace()
                return nil
            default:
                return event
            }
        }

        func stopMonitoring() {
            updateMonitoring(isActive: false)
        }
    }

    var isActive: Bool
    var onArrowLeft: () -> Void
    var onArrowRight: () -> Void
    var onEnter: () -> Void
    var onSpace: () -> Void
    var onCmdF: () -> Void
    var onEsc: () -> Void
    var isEditingText: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onArrowLeft = onArrowLeft
        coordinator.onArrowRight = onArrowRight
        coordinator.onEnter = onEnter
        coordinator.onSpace = onSpace
        coordinator.onCmdF = onCmdF
        coordinator.onEsc = onEsc
        coordinator.isEditingText = isEditingText
        coordinator.updateMonitoring(isActive: isActive)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }
}

/// 清空历史按钮（Aurora v2）：圆形图标按钮，hover 时红色淡底 + 红图标，
/// 与设置页破坏按钮的语义色一致。
private struct ClearHistoryButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? DesignTokens.Colors.error : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isHovered
                              ? DesignTokens.Colors.errorSurface
                              : Color.primary.opacity(0.05))
                )
        }
        .buttonStyle(.borderless)
        .help("清空历史")
        .onHover { hovering in
            withAnimation(DesignTokens.Aurora.standard) { isHovered = hovering }
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

    // 直接复用 ClipboardItem 缓存的 headerForeground，避免每次 body 重算 luminance。
    private var headerForeground: Color { item.headerForeground }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DesignTokens.Aurora.cardSurface)
        )
        .overlay(
            // Aurora v2：品牌渐变描边替代单色 accent 描边。
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DesignTokens.Aurora.brandGradient.opacity(0.6), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: DesignTokens.Aurora.floatShadowColor, radius: 20, y: 6)
        .shadow(color: DesignTokens.Aurora.brandGlow.opacity(0.5), radius: 24, y: 0)
        .task {
            // 若为单图片文件，后台加载避免阻塞主线程。
            // NSImage(contentsOf:) 是同步磁盘 I/O，在 .task（@MainActor）中
            // 直接调用会冻结 UI。改用 Task.detached 在后台读取 Data，
            // 再回主线程创建 NSImage(data:)。
            if case .file(let urls) = item.kind,
               let url = urls.first,
               urls.count == 1,
               ClipboardItem.isImageFile(url) {
                let data = await Task.detached { try? Data(contentsOf: url) }.value
                if let data {
                    await MainActor.run { loadedFileImage = NSImage(data: data) }
                }
            }
            // 冷数据图片（>7天）：warmUpAsync() 从磁盘加载 TIFF Data + thumbnail。
            // 预览卡片同样需要触发 warmUp，否则全屏预览显示空白。
            if case .image(let data, _) = item.kind, data == nil, item.imageFileURL != nil {
                await item.warmUpAsync()
            }
        }
    }

    private var header: some View {
        // 设计稿：[icon][name][badge]  [time][close-btn]
        HStack(spacing: 8) {
            if let icon = item.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
            }
            Text(item.sourceAppName ?? "未知")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(item.typeLabel)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(headerForeground.opacity(0.22)))
            Spacer(minLength: 0)
            Text(RelativeTimeFormatter.string(from: item.createdAt, now: Date()))
                .font(.system(size: 11))
                .foregroundStyle(headerForeground.opacity(0.9))
            // 设计稿：close-btn 22×22，bg rgba(255,255,255,0.2)，白色 X 图标
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.2))
                    )
            }
            .buttonStyle(.borderless)
            .help("关闭")
        }
        .foregroundStyle(headerForeground)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color(nsColor: item.sourceAppTint),
                         Color(nsColor: item.sourceAppTint).opacity(0.72)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(TopRoundedShape(radius: 16))
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
        case .image:
            Image(nsImage: item.imageThumbnail ?? NSImage())
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
            // Aurora v2：品牌渐变主按钮，替代原生 borderedProminent。
            Button(action: onApply) {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(AuroraPrimaryButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(DesignTokens.Aurora.cardSurface.opacity(0.85))
        .clipShape(BottomRoundedShape(radius: 16))
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
    // 直接复用 ClipboardItem 缓存的 headerForeground，避免每次 body 重算 luminance。
    private var headerForeground: Color { item.headerForeground }

    var body: some View {
        VStack(spacing: 0) {
            header
            middle
            footer
        }
        .frame(width: cardWidth, height: height)
        .background(
            // Aurora v2：卡片用自适应 cardSurface（light 纯白 / dark #242429），
            // 与玻璃面板拉开层次；hover 不改变背景填充。
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignTokens.Aurora.cardSurface)
        )
        .overlay {
            // 描边二选一（条件挂载，非 opacity 切换）：
            // 之前渐变描边对所有卡片常驻（lineWidth 0 / opacity 0 仍每帧
            // 求值渐变着色器），快速滚动时 5-10 张可见卡片的渐变求值
            // 是掉帧主因之一。现在非 hover 卡片只画纯色发丝描边，
            // hover 的那一张才挂载渐变描边。
            if isHover {
                // 选中/hover 态：品牌渐变描边 2.5pt——键盘选中与鼠标 hover
                // 合并为同一视觉（isHover 已合并两态），选中反馈清晰明确。
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(DesignTokens.Aurora.brandGradient, lineWidth: 2.5)
            } else {
                // 常驻发丝描边，让卡片在玻璃上边缘清晰。
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(DesignTokens.Aurora.cardBorder, lineWidth: 1)
            }
        }
        // 性能：非 hover 卡片不渲染阴影（radius 0 不触发离屏模糊）。
        // hover 态用品牌色外发光 + 轻微上浮，突出当前操作目标。
        .shadow(color: isHover ? DesignTokens.Aurora.brandGlow : .clear,
                radius: isHover ? 10 : 0, y: isHover ? 4 : 0)
        .scaleEffect(isHover ? 1.03 : 1.0)
        .offset(y: isHover ? -2 : 0)
        .opacity(isDimmed ? 0.4 : 1.0)
        // hover 视觉即时切换（不加动画）：快速滚动时鼠标掠过会连续触发
        // hover 变化，若带动画则品牌外发光（离屏模糊）会每帧重渲染，
        // 是滚动掉帧的来源之一。列表增删动画仍由父容器 transaction nil 抑制。
        .transaction { $0.animation = nil }
        .task {
            // 单图片文件后台加载缩略图，避免阻塞主线程。
            // NSImage(contentsOf:) 是同步磁盘 I/O，在 .task（@MainActor）中
            // 直接调用会冻结 UI。改用 Task.detached 在后台读取 Data，
            // 再回主线程创建 NSImage(data:)。
            if case .file(let urls) = item.kind,
               let url = urls.first,
               urls.count == 1,
               ClipboardItem.isImageFile(url) {
                let data = await Task.detached { try? Data(contentsOf: url) }.value
                if let data {
                    await MainActor.run { loadedFileImage = NSImage(data: data) }
                }
            }
            // 冷数据图片（>7天）：warmUpAsync() 从磁盘加载 TIFF Data + thumbnail。
            // 之前卡片渲染路径完全不触发 warmUp，冷数据图片显示空白 NSImage()。
            // warmUpAsync 内部用 Task.detached 在后台读盘，回主线程更新 kind，
            // 避免阻塞主线程。
            if case .image(let data, _) = item.kind, data == nil, item.imageFileURL != nil {
                await item.warmUpAsync()
            }
        }
    }

    // MARK: - Top header

    private var header: some View {
        // 设计稿：[icon][app-name][type-badge]  [card-time(margin-left:auto)]
        // badge 紧跟 name，时间用 Spacer 推到最右
        HStack(spacing: 6) {
            if let icon = item.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
            }
            Text(item.sourceAppName ?? "未知")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(item.typeLabel)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(headerForeground.opacity(0.22)))
            Spacer(minLength: 0)
            Text(RelativeTimeFormatter.string(from: item.createdAt, now: Date()))
                .font(.system(size: 10))
                .foregroundStyle(headerForeground.opacity(0.85))
        }
        .foregroundStyle(headerForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            // Aurora v2：应用色调对角渐变，比垂直渐变更有层次。
            LinearGradient(
                colors: [Color(nsColor: item.sourceAppTint),
                         Color(nsColor: item.sourceAppTint).opacity(0.72)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(TopRoundedShape(radius: 14))
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
            // 若有 RTF 富文本（如 VSCode/Xcode 复制的代码），用缓存的
            // AttributedString 渲染保留颜色/字体样式；否则回退普通 Text。
            // 之前每次 body 都重新解析 RTF，100 张卡片滚动时严重卡顿。
            // 现在从 ClipboardItem.cachedAttributedString 取缓存结果。
            if let attr = item.cachedAttributedString {
                Text(attr)
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
            // 注：曾用 .mask 做底部渐隐，但 mask 会强制每张文本卡片离屏渲染，
            // 快速滚动时每帧多次离屏 pass 导致严重掉帧，已移除（性能优先）。
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
        case .image:
            Image(nsImage: item.fullImage ?? NSImage())
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

    /// 类型圆点颜色：与筛选菜单一致的 6 类固定色。
    private var kindDotColor: Color {
        switch item.contentKind {
        case .text:  return DesignTokens.FilterDot.text
        case .link:  return DesignTokens.FilterDot.link
        case .image: return DesignTokens.FilterDot.image
        case .file:  return DesignTokens.FilterDot.file
        case .color: return DesignTokens.FilterDot.color
        }
    }

    private var footer: some View {
        // Aurora v2：左 = 类型圆点 + 类型名（彩色），右 = 统计信息。
        // 替代原来的居中单行统计，信息层级更清晰。
        HStack(spacing: 5) {
            Circle()
                .fill(kindDotColor)
                .frame(width: 6, height: 6)
            Text(item.typeLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(kindDotColor)
            Spacer(minLength: 0)
            Text(item.footerText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
        .clipShape(BottomRoundedShape(radius: 14))
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
