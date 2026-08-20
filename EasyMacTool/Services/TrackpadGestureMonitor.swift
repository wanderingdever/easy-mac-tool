import AppKit

/// Public-API trackpad swipe monitor. Uses global gesture events instead of a
/// private HID tap; suitable as a first implementation, with tuning knobs for
/// sensitivity if the system delivers smaller deltas.
@MainActor
final class TrackpadGestureMonitor {
    enum Direction {
        case left
        case right
    }

    private var monitor: Any?
    private var gestureStarted = false
    private var onSwipe: (@MainActor (Direction) -> Void)?
    private let minSwipeDelta: CGFloat = 5

    var isRunning: Bool { monitor != nil }

    func start(onSwipe: @escaping @MainActor (Direction) -> Void) {
        stop()
        self.onSwipe = onSwipe
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.gesture, .beginGesture, .endGesture]
        ) { [weak self] event in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        onSwipe = nil
        gestureStarted = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .beginGesture {
            gestureStarted = true
            return
        }
        if event.type == .endGesture {
            gestureStarted = false
            return
        }
        guard gestureStarted, event.type == .gesture else { return }

        let touches = event.allTouches()
        let down = touches.filter {
            $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
        }
        guard down.count >= 3 else { return }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if abs(dx) >= minSwipeDelta, abs(dx) > abs(dy) {
            onSwipe?(dx < 0 ? .left : .right)
            gestureStarted = false
        }
    }
}
