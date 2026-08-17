import AppKit
import ApplicationServices
import os

/// Applies window layout actions (halves / full screen / corners) to the
/// frontmost window via the Accessibility API. Requires the Accessibility
/// permission to read/write another app's window position and size.
@MainActor
final class WindowLayoutManager {
    static let shared = WindowLayoutManager()
    private static let logger = Logger(subsystem: "com.easymactool", category: "WindowLayoutManager")

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
        Self.targetFrame(for: action, visibleFrame: screen.visibleFrame)
    }

    nonisolated static func targetFrame(for action: WindowLayoutAction,
                                        visibleFrame vf: CGRect) -> CGRect {
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
        guard let pos = cgPoint(window, kAXPositionAttribute as CFString),
              let size = cgSize(window, kAXSizeAttribute as CFString) else { return fallbackScreen() }
        // AX 坐标以主屏左上为原点、y 向下；NSScreen.frame 以主屏左下为原点、
        // y 向上。先把 AX 窗口 frame 翻转回 NSScreen 空间再匹配屏幕，
        // 否则副屏/多屏下会空间错位匹配到主屏。
        let main = NSScreen.screens.first?.frame ?? .zero
        let nsFrame = CGRect(x: pos.x + main.minX,
                             y: main.maxY - pos.y - size.height,
                             width: size.width, height: size.height)
        return NSScreen.screens.first(where: { $0.frame.contains(nsFrame.center) }) ?? fallbackScreen()
    }

    private func fallbackScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.screens.first
    }

    private func focusedWindow(of axApp: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let window = ref,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(window, to: AXUIElement.self)
    }

    @discardableResult
    private func setFrame(_ frame: CGRect, on window: AXUIElement) -> Bool {
        // AX 坐标以主屏左上角为原点、y 向下；NSScreen.visibleFrame 以左下为原点、
        // y 向上。用主显示器（NSScreen.screens.first，Apple 保证为全局原点所在屏，
        // 即 AX 坐标系的真实原点）而非 NSScreen.main——菜单栏 app 中 NSScreen.main
        // 是"key window 所在屏"，可能解析到副屏导致 y 翻转基准错误。
        let main = NSScreen.screens.first?.frame ?? .zero
        var point = CGPoint(x: frame.minX - main.minX,
                            y: main.maxY - frame.maxY)
        var size = frame.size
        let positionValue = AXValueCreate(.cgPoint, &point)
        let sizeValue = AXValueCreate(.cgSize, &size)
        guard let positionValue, let sizeValue else { return false }
        let okPos = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let okSize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let success = okPos == .success && okSize == .success
        // 回读验证：副屏高于/高于主屏时 AX y/x 为负，越界位置可能被
        // WindowServer 钳制回主屏（多屏错屏）。写回后回读 position 与目标点
        // 容差比对，不一致时输出诊断日志，便于实机定位钳制行为。
        if let readback = cgPoint(window, kAXPositionAttribute as CFString),
           abs(readback.x - point.x) > 2 || abs(readback.y - point.y) > 2 {
            Self.logger.warning("[WindowLayout] setFrame mispositioned: target=\(NSStringFromRect(frame)) axTarget=\(NSStringFromPoint(point)) readback=\(NSStringFromPoint(readback)) success=\(success) primary=\(NSStringFromRect(main))")
        }
        return success
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
