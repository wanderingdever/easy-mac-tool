import AppKit
import SwiftUI

nonisolated enum HorizontalScrollGeometry {
    static let animationFactor: CGFloat = 0.18
    static let settleThreshold: CGFloat = 0.5

    static func discreteStep(verticalDelta: CGFloat) -> Int? {
        guard verticalDelta != 0 else { return nil }
        return verticalDelta < 0 ? 1 : -1
    }

    static func smoothedOrigin(current: CGFloat,
                               target: CGFloat,
                               factor: CGFloat = animationFactor,
                               settleThreshold: CGFloat = settleThreshold) -> CGFloat {
        guard abs(target - current) > settleThreshold else { return target }
        let clampedFactor = min(max(factor, 0), 1)
        return current + (target - current) * clampedFactor
    }

    static func targetOrigin(index: Int,
                             currentOrigin: CGFloat,
                             viewportWidth: CGFloat,
                             documentWidth: CGFloat,
                             cardWidth: CGFloat,
                             spacing: CGFloat,
                             horizontalPadding: CGFloat) -> CGFloat? {
        guard index >= 0, viewportWidth > 0, documentWidth > 0 else { return nil }
        let cardMinX = horizontalPadding + CGFloat(index) * (cardWidth + spacing)
        let cardMaxX = cardMinX + cardWidth
        guard cardMaxX <= documentWidth + 1 else { return nil }

        var target = currentOrigin
        if cardMinX < currentOrigin {
            target = cardMinX - horizontalPadding
        } else if cardMaxX > currentOrigin + viewportWidth {
            target = cardMaxX - viewportWidth + horizontalPadding
        }
        return min(max(0, target), max(0, documentWidth - viewportWidth))
    }
}

/// 将离散鼠标滚轮转换为逐卡选择；精确触控板事件继续使用系统的连续增量。
/// 程序化揭示由单个 120Hz timer 追踪最新目标，连续输入不会排队动画。
final class WheelRedirectScrollView: NSScrollView {
    var onDiscreteStep: ((Int) -> Void)?
    var onAnimationStateChange: ((Bool) -> Void)?
    var reduceMotion = false

    private var animationTimer: Timer?
    private var targetOriginX: CGFloat?
    private var animationActive = false

    override func scrollWheel(with event: NSEvent) {
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

        let horizontalRoom = doc.bounds.width - contentSize.width
        guard horizontalRoom > 0.5 else {
            super.scrollWheel(with: event)
            return
        }

        if event.hasPreciseScrollingDeltas {
            cancelProgrammaticScroll()
            var origin = contentView.bounds.origin
            origin.x = min(max(0, origin.x - event.scrollingDeltaY), horizontalRoom)
            contentView.bounds.origin = origin
            reflectScrolledClipView(contentView)
        } else if let step = HorizontalScrollGeometry.discreteStep(
            verticalDelta: event.scrollingDeltaY
        ) {
            onDiscreteStep?(step)
        }
    }

    /// 最小滚动以完整揭示目标卡片。返回 false 表示 SwiftUI document view
    /// 尚未完成布局，调用方应在下一帧重试且不能提前去重该索引。
    func revealCard(at index: Int) -> Bool {
        guard index >= 0, let doc = documentView else { return false }
        doc.layoutSubtreeIfNeeded()
        let documentWidth = doc.bounds.width
        guard documentWidth > 0, contentSize.width > 0 else { return false }

        guard let target = HorizontalScrollGeometry.targetOrigin(
            index: index,
            currentOrigin: contentView.bounds.origin.x,
            viewportWidth: contentSize.width,
            documentWidth: documentWidth,
            cardWidth: DesignTokens.ClipboardLayout.cardWidth,
            spacing: DesignTokens.ClipboardLayout.cardSpacing,
            horizontalPadding: DesignTokens.ClipboardLayout.stripHorizontalPadding
        ) else { return false }
        scroll(to: target)
        return true
    }

    func cancelProgrammaticScroll() {
        targetOriginX = nil
        animationTimer?.invalidate()
        animationTimer = nil
        setAnimationActive(false)
    }

    private func scroll(to requestedTarget: CGFloat) {
        let maximum = max(0, (documentView?.bounds.width ?? 0) - contentSize.width)
        let target = min(max(0, requestedTarget), maximum)
        if reduceMotion || abs(target - contentView.bounds.origin.x) <= HorizontalScrollGeometry.settleThreshold {
            cancelProgrammaticScroll()
            setOriginX(target)
            return
        }

        targetOriginX = target
        setAnimationActive(true)
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0,
                          target: self,
                          selector: #selector(advanceScrollAnimation),
                          userInfo: nil,
                          repeats: true)
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func advanceScrollAnimation() {
        guard let requestedTarget = targetOriginX else {
            cancelProgrammaticScroll()
            return
        }
        let maximum = max(0, (documentView?.bounds.width ?? 0) - contentSize.width)
        let target = min(max(0, requestedTarget), maximum)
        if reduceMotion {
            setOriginX(target)
            cancelProgrammaticScroll()
            return
        }
        let next = HorizontalScrollGeometry.smoothedOrigin(
            current: contentView.bounds.origin.x,
            target: target
        )
        setOriginX(next)
        if next == target {
            cancelProgrammaticScroll()
        }
    }

    private func setOriginX(_ x: CGFloat) {
        var origin = contentView.bounds.origin
        origin.x = x
        contentView.bounds.origin = origin
        reflectScrolledClipView(contentView)
    }

    private func setAnimationActive(_ active: Bool) {
        guard animationActive != active else { return }
        animationActive = active
        onAnimationStateChange?(active)
    }
}

/// Type-erased coordinator (extracted from generic context to avoid
/// Swift 6.3 SIL optimizer crash on generic class deinit).
final class HWSVCoordinator {
    var hostingController: Any?
    var lastScrolledIndex: Int?
    private var pendingIndex: Int?

    func reveal(_ index: Int, in scrollView: WheelRedirectScrollView, attempt: Int = 0) {
        pendingIndex = index
        DispatchQueue.main.async { [weak self, weak scrollView] in
            guard let self, let scrollView, self.pendingIndex == index else { return }
            if scrollView.revealCard(at: index) {
                self.lastScrolledIndex = index
                self.pendingIndex = nil
            } else if attempt < 4 {
                self.reveal(index, in: scrollView, attempt: attempt + 1)
            } else {
                self.pendingIndex = nil
            }
        }
    }
}

/// 用 NSHostingController 承载 SwiftUI 内容的横向滚动视图。
struct HorizontalWheelScrollView<Content: View>: NSViewRepresentable {
    let content: Content
    var scrollToIndex: Int?
    var onDiscreteStep: (Int) -> Void
    var reduceMotion: Bool
    var onAnimationStateChange: (Bool) -> Void

    init(@ViewBuilder content: () -> Content,
         scrollToIndex: Int? = nil,
         onDiscreteStep: @escaping (Int) -> Void = { _ in },
         reduceMotion: Bool = false,
         onAnimationStateChange: @escaping (Bool) -> Void = { _ in }) {
        self.content = content()
        self.scrollToIndex = scrollToIndex
        self.onDiscreteStep = onDiscreteStep
        self.reduceMotion = reduceMotion
        self.onAnimationStateChange = onAnimationStateChange
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
        configureCallbacks(on: scrollView)

        let hosting = NSHostingController(rootView: content)
        hosting.view.wantsLayer = true
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        scrollView.documentView = hosting.view
        context.coordinator.hostingController = hosting

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
        configureCallbacks(on: nsView)
        if let idx = scrollToIndex, idx != context.coordinator.lastScrolledIndex {
            context.coordinator.reveal(idx, in: nsView)
        }
    }

    static func dismantleNSView(_ nsView: WheelRedirectScrollView, coordinator: HWSVCoordinator) {
        nsView.onDiscreteStep = nil
        nsView.onAnimationStateChange = nil
        nsView.cancelProgrammaticScroll()
    }

    private func configureCallbacks(on scrollView: WheelRedirectScrollView) {
        scrollView.onDiscreteStep = onDiscreteStep
        scrollView.reduceMotion = reduceMotion
        scrollView.onAnimationStateChange = onAnimationStateChange
    }
}
