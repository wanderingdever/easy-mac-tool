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

    /// 按方向键时滚动一张卡片步进（242pt = 卡片宽 230 + 间距 12）。
    /// 与滚轮的 40pt/tick 同源，但每次按一张卡片，平滑不跳页。
    /// direction: +1 向右（看后面），-1 向左（看前面）。
    func scrollByCards(_ direction: Int) {
        guard let doc = documentView else { return }
        let hRoom = doc.bounds.width - contentSize.width
        guard hRoom > 0.5 else { return }
        let cardStep: CGFloat = 242  // 卡片宽 230 + 间距 12
        var origin = contentView.bounds.origin
        origin.x = min(max(0, origin.x + CGFloat(direction) * cardStep), hRoom)
        contentView.bounds.origin = origin
        reflectScrolledClipView(contentView)
    }
}

/// Type-erased coordinator (extracted from generic context to avoid
/// Swift 6.3 SIL optimizer crash on generic class deinit).
final class HWSVCoordinator {
    var hostingController: Any?
    /// 记录上次方向键索引，用于推导滚动方向（+1/-1），并对重复 body
    /// 更新去重。
    var lastScrolledIndex: Int?
}

/// 用 NSHostingController 承载 SwiftUI 内容的横向滚动视图。
/// documentView 的宽度自动跟随 SwiftUI 内容的 intrinsic 大小，
/// 高度锚定到 contentView 高度。
struct HorizontalWheelScrollView<Content: View>: NSViewRepresentable {
    let content: Content
    /// 键盘方向键选中的卡片索引：变化时按方向步进滚动一张卡片（242pt），
    /// 与滚轮手感一致。仅在键盘选择（而非 hover）时更新——hover 会在滚轮
    /// 滚动时随鼠标掠过卡片而频繁变化，若也触发滚动会与滚轮互相打架。
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
        // 键盘选中索引变化 → 推导方向（+1/-1），延后到布局完成后步进滚动。
        if let idx = scrollToIndex, idx != context.coordinator.lastScrolledIndex {
            let prev = context.coordinator.lastScrolledIndex ?? idx
            context.coordinator.lastScrolledIndex = idx
            let direction = idx > prev ? 1 : -1
            DispatchQueue.main.async {
                nsView.scrollByCards(direction)
            }
        }
    }
}
