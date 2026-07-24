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
        let step: CGFloat = 40
        let dx = -event.deltaY * step
        var origin = contentView.bounds.origin
        origin.x = min(max(0, origin.x + dx), hRoom)
        // 用 animator() 做短动画过渡，让连续滚轮事件叠加成丝滑惯性滚动。
        // duration 调到 0.18s 配合 easeOut，新事件到来时动画上下文会自动接续。
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            contentView.animator().bounds.origin = origin
        } completionHandler: {
            // 同步 scroller 视觉位置（animator 不会自动刷新 scroller）。
            self.reflectScrolledClipView(self.contentView)
        }
    }
}

/// 用 NSHostingController 承载 SwiftUI 内容的横向滚动视图。
/// documentView 的宽度自动跟随 SwiftUI 内容的 intrinsic 大小，
/// 高度锚定到 contentView 高度。
struct HorizontalWheelScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var hostingController: NSHostingController<Content>?
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
        context.coordinator.hostingController?.rootView = content
    }
}
