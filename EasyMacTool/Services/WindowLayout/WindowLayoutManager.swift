import AppKit
import ApplicationServices

/// Applies window layout actions (halves / full screen / corners) to the
/// frontmost window via the Accessibility API. Requires the Accessibility
/// permission to read/write another app's window position and size.
@MainActor
final class WindowLayoutManager {
    static let shared = WindowLayoutManager()

    private init() {}

    /// Applies a layout action to the current frontmost window.
    /// - Parameters:
    ///   - action: the layout to apply.
    ///   - overrideScreen: when non-nil, tile on this screen instead of the
    ///     frontmost window's screen (used by the radial menu, which follows
    ///     the mouse).
    /// - Returns: true on success; false when the window/AX access failed or
    ///   the Accessibility permission is missing.
    @discardableResult
    func apply(_ action: WindowLayoutAction, screen overrideScreen: NSScreen? = nil) -> Bool {
        guard AccessibilityChecker.isTrusted else { return false }
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        guard let window = focusedWindow(of: axApp) else { return false }
        guard let screen = (overrideScreen ?? screen(for: window)) ?? NSScreen.main else { return false }
        let frame = self.frame(for: action, on: screen)
        return setFrame(frame, on: window)
    }

    /// Computes the target frame for a layout action on the given screen,
    /// using that screen's visible frame (bottom-left origin, same space as
    /// AX window coordinates).
    func frame(for action: WindowLayoutAction, on screen: NSScreen) -> CGRect {
        let vf = screen.visibleFrame
        let halfW = vf.width / 2
        let halfH = vf.height / 2
        switch action {
        case .leftHalf:
            return CGRect(x: vf.minX, y: vf.minY, width: halfW, height: vf.height)
        case .rightHalf:
            return CGRect(x: vf.midX, y: vf.minY, width: halfW, height: vf.height)
        case .topHalf:
            return CGRect(x: vf.minX, y: vf.maxY - halfH, width: vf.width, height: halfH)
        case .bottomHalf:
            return CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: halfH)
        case .fullScreen:
            return vf
        case .topLeft:
            return CGRect(x: vf.minX, y: vf.maxY - halfH, width: halfW, height: halfH)
        case .topRight:
            return CGRect(x: vf.midX, y: vf.maxY - halfH, width: halfW, height: halfH)
        case .bottomLeft:
            return CGRect(x: vf.minX, y: vf.minY, width: halfW, height: halfH)
        case .bottomRight:
            return CGRect(x: vf.midX, y: vf.minY, width: halfW, height: halfH)
        }
    }

    // MARK: - Private

    /// The screen containing the frontmost window's current frame, falling
    /// back to the main screen.
    private func screen(for window: AXUIElement) -> NSScreen? {
        if let pos = cgPoint(window, kAXPositionAttribute as CFString),
           let size = cgSize(window, kAXSizeAttribute as CFString) {
            let frame = CGRect(origin: pos, size: size)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(frame.center) }) {
                return screen
            }
        }
        return NSScreen.main
    }

    private func focusedWindow(of axApp: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let window = ref,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return window as! AXUIElement
    }

    @discardableResult
    private func setFrame(_ frame: CGRect, on window: AXUIElement) -> Bool {
        // AX 坐标以主屏左上角为原点、y 向下；NSScreen.visibleFrame 以左下为原点、
        // y 向上。若把 NSScreen 算出的 frame 直接写入 AX，垂直方向会镜像/偏移
        // （上下半屏互换、占满高度的窗口顶部留空）。这里把窗口顶边映射到 AX 的 y。
        let main = NSScreen.main?.frame ?? .zero
        var point = CGPoint(x: frame.minX - main.minX,
                            y: main.maxY - frame.maxY)
        var size = frame.size
        let positionValue = AXValueCreate(.cgPoint, &point)
        let sizeValue = AXValueCreate(.cgSize, &size)
        guard let positionValue, let sizeValue else { return false }
        let okPos = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let okSize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        return okPos == .success && okSize == .success
    }

    private func cgPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func cgSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}