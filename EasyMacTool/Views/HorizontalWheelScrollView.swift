import AppKit
import SwiftUI

/// 横向滚动手势的 NSScrollView 子类：将「无 Shift 修饰的垂直滚轮」
/// 重定向为横向滚动，使鼠标滚轮可直接横向滚动剪切板卡片列表。
/// 保留 trackpad 横向手势（deltaX）、Shift+滚轮、纵向 scroll view 默认行为。
final class WheelRedirectScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // 仅拦截「无 Shift 修饰 + 纯垂直滚轮（deltaY≠0 且 deltaX≈0）」的事件。
        // trackpad 横向手势（deltaX≠0）、Shift+滚轮（系统默认已重定向）、
        // 其他修饰键组合（如 ⌘ 缩放）一律走默认行为。
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function])
        guard mods.isEmpty else {
            super.scrollWheel(with: event)
            return
        }
        guard event.deltaY != 0,
              abs(event.deltaY) >= abs(event.deltaX),
              let doc = documentView else {
            super.scrollWheel(with: event)
            return
        }
        // 仅在横向可滚（文档宽 > 可视宽）时重定向；否则走默认（纵向不滚）。
        let hRoom = doc.bounds.width - contentSize.width
        guard hRoom > 0.5 else {
            super.scrollWheel(with: event)
            return
        }
        // 与系统 Shift+滚轮方向一致：滚轮向上（deltaY>0）→ 看左侧/前面内容
        // → bounds.origin.x 减小。每刻度滚动约 40pt。
        // 直接更新 bounds（去掉逐事件 animator 动画）：快速滚动时旧动画会被
        // 新事件打断并从未到位处重启动画，导致滚动永远追赶不上输入 → 卡顿
        // 滚不动。直接定位每个刻度立即生效、线性累积，与输入同步。
        let step: CGFloat = 40
        let dx = -event.deltaY * step
        var origin = contentView.bounds.origin
        origin.x = min(max(0, origin.x + dx), hRoom)
        contentView.bounds.origin = origin
        reflectScrolledClipView(contentView)
    }

    /// 最小滚动到第 index 张卡片可见（scroll-to-reveal，与滚动翻页一致）：
    /// - 卡片已在可视区内 → 不滚动（避免"提前翻页"）；
    /// - 卡片在右侧外 → 右移刚好让卡片右缘对齐视口右缘（按张步进）；
    /// - 卡片在左侧外 → 左移刚好让卡片左缘对齐视口左缘。
    /// 卡片布局：LazyHStack 固定宽 230、间距 12、水平 padding 16 →
    /// 第 i 张卡片左缘 x = 16 + i*242。无动画直接定位，避免按键连发时
    /// 动画互相打断（与滚轮策略一致）。
    func scrollToCard(at index: Int) {
        guard let doc = documentView else { return }
        let hRoom = doc.bounds.width - contentSize.width
        guard hRoom > 0.5 else { return }
        let cardLeft = 16 + CGFloat(index) * 242
        let cardRight = cardLeft + 230
        let viewLeft = contentView.bounds.origin.x
        let viewRight = viewLeft + contentSize.width
        var target = viewLeft
        if cardLeft < viewLeft {
            // 卡片在可视区左侧之外：向左滚到它可见（左缘对齐）。
            target = cardLeft
        } else if cardRight > viewRight {
            // 卡片在可视区右侧之外：向右滚到它可见（右缘对齐，最小步进 1 张）。
            target = cardRight - contentSize.width
        } else {
            // 卡片已完整可见：不滚动。
            return
        }
        contentView.bounds.origin.x = min(max(0, target), hRoom)
        reflectScrolledClipView(contentView)
    }
}

/// Type-erased coordinator (extracted from generic context to avoid
/// Swift 6.3 SIL optimizer crash on generic class deinit).
final class HWSVCoordinator {
    var hostingController: Any?
    /// 已执行滚动判定的目标卡片索引：用于去重，避免每次 body 更新（hover 变化、
    /// 滚动等）都重复触发 scrollToCard。scrollToCard 内部再做最小滚动揭示
    /// （卡片已在可视区内则直接返回、不滚动）。
    var lastScrolledIndex: Int?
}

/// 用 NSHostingController 承载 SwiftUI 内容的横向滚动视图。
/// documentView 的宽度自动跟随 SwiftUI 内容的 intrinsic 大小，
/// 高度锚定到 contentView 高度。
struct HorizontalWheelScrollView<Content: View>: NSViewRepresentable {
    let content: Content
    /// 键盘方向键选中的卡片索引：变化时自动做最小滚动揭示（仅当卡片超出
    /// 可视区才按张滚动，与滚动翻页一致）。仅在键盘选择（而非 hover）时更新——
    /// hover 会在滚轮滚动时随鼠标掠过卡片而频繁变化，若也触发滚动会与滚轮
    /// 滚动互相打架（复现"滚不动"）。
    var scrollToIndex: Int?

    init(@ViewBuilder content: () -> Content, scrollToIndex: Int? = nil) {
        self.content = content()
        self.scrollToIndex = scrollToIndex
    }

    func makeCoordinator() -> HWSVCoordinator {
        HWSVCoordinator()
    }

    func makeNSView(context: Context) -> WheelRedirectScrollView {
        let scrollView = WheelRedirectScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerStyle = .overlay

        let hosting = NSHostingController(rootView: content)
        hosting.view.wantsLayer = true
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        scrollView.documentView = hosting.view
        context.coordinator.hostingController = hosting

        // documentView 高度锚定到 contentView，宽度由 SwiftUI 内容撑开。
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.view.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])

        return scrollView
    }

    func updateNSView(_ nsView: WheelRedirectScrollView, context: Context) {
        guard let hosting = context.coordinator.hostingController as? NSHostingController<Content> else {
            assertionFailure("hostingController type mismatch")
            return
        }
        hosting.rootView = content
        // 键盘选中索引变化 → 延后到当前布局完成后再滚动到该卡片，
        // 避免在 SwiftUI 布局中途直接改 bounds 被后续布局覆盖。
        if let idx = scrollToIndex, idx != context.coordinator.lastScrolledIndex {
            context.coordinator.lastScrolledIndex = idx
            DispatchQueue.main.async {
                nsView.scrollToCard(at: idx)
            }
        }
    }
}
