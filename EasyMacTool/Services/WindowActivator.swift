import AppKit
import ApplicationServices

/// Brings a specific window (not just its app) to the front via the Accessibility
/// API, and supports closing / minimizing a window via its AX toolbar buttons.
@MainActor
final class WindowActivator {
    /// Activates the owning app and raises the exact window matching `item.frame`.
    /// For placeholder items (no open windows), uses `NSWorkspace.openApplication`
    /// to reopen the app — this triggers `applicationShouldHandleReopen` which
    /// creates a new window for most macOS apps.
    ///
    /// 根据 windowState 先恢复可见性：
    /// - .visible：直接激活
    /// - .minimized：先 AX deminimize（AXMinimized=false）
    /// - .hidden：先 app.unhide()，再检查是否需要 deminimize（边界：app hidden + 窗口 minimized）
    func activate(_ item: WindowItem) {
        let app = NSRunningApplication(processIdentifier: item.pid)
        // 缓存第一次 findAXWindow 找到的窗口引用，app.activate 后窗口列表可能变化，
        // 第二次查找可能失败。复用引用避免 deminimize 后未正确 focus。
        var resolvedWindow: AXUIElement?

        // 根据窗口状态先恢复可见性
        switch item.windowState {
        case .visible:
            break // 无需恢复
        case .minimized:
            // 先 deminimize：AX 设置 AXMinimized=false
            let axApp = AXUIElementCreateApplication(item.pid)
            if let window = findAXWindow(axApp, matching: item) {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                resolvedWindow = window
            }
        case .hidden:
            // 先 unhide app（Cmd+H 隐藏的 app 需要 unhide 才能显示窗口）
            app?.unhide()
            // 边界情况：app hidden + 窗口 minimized
            // unhide 后该窗口可能仍然是 minimized 的，需要同时 deminimize
            let axApp = AXUIElementCreateApplication(item.pid)
            if let window = findAXWindow(axApp, matching: item) {
                var isMinimizedRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &isMinimizedRef)
                if (isMinimizedRef as? NSNumber)?.boolValue == true {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                resolvedWindow = window
            }
        }

        // 激活 app 并通过 AX 提升目标窗口到前台。
        // 复用第一次 findAXWindow 的结果，避免 app.activate 后窗口列表变化导致第二次查找失败。
        app?.activate(options: [.activateAllWindows])

        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = resolvedWindow ?? findAXWindow(axApp, matching: item) else { return }
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Closes the window by pressing its AX close button.
    func close(_ item: WindowItem) {
        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = findAXWindow(axApp, matching: item) else { return }
        pressButton(window, attribute: kAXCloseButtonAttribute as CFString)
    }

    /// Minimizes the window by pressing its AX minimize button.
    func minimize(_ item: WindowItem) {
        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = findAXWindow(axApp, matching: item) else { return }
        pressButton(window, attribute: kAXMinimizeButtonAttribute as CFString)
    }

    // MARK: - Private

    private func findAXWindow(_ axApp: AXUIElement, matching item: WindowItem) -> AXUIElement? {
        var count: CFIndex = 0
        AXUIElementGetAttributeValueCount(axApp, kAXWindowsAttribute as CFString, &count)
        var windowsRef: CFArray?
        AXUIElementCopyAttributeValues(axApp, kAXWindowsAttribute as CFString, 0, count, &windowsRef)
        guard let axWindows = windowsRef as? [AXUIElement] else { return nil }

        // AXWindowID is the same identifier supplied by ScreenCaptureKit and
        // is therefore unambiguous even when several windows share an origin.
        // 仅对真实 windowID 做精确匹配：降级 ID（哈希生成，0xF0000000 高位
        // 标记）可能与系统分配的真实 ID 碰撞，误匹配会操作到错误窗口。
        if item.hasRealWindowID {
            for axWindow in axWindows where windowID(of: axWindow) == item.id {
                return axWindow
            }
        }

        // A small number of apps do not expose AXWindowID. Keep a conservative
        // fallback for them, requiring both origin and size to match.
        for axWindow in axWindows {
            guard let position = cgPoint(axWindow, kAXPositionAttribute as CFString),
                  let size = cgSize(axWindow, kAXSizeAttribute as CFString) else { continue }
            let frame = CGRect(origin: position, size: size)
            let target = item.frame
            if abs(frame.origin.x - target.origin.x) < 2,
               abs(frame.origin.y - target.origin.y) < 2,
               abs(frame.size.width - target.size.width) < 2,
               abs(frame.size.height - target.size.height) < 2 {
                return axWindow
            }
        }
        return nil
    }

    private func windowID(of element: AXUIElement) -> CGWindowID? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXWindowID" as CFString, &ref) == .success,
              let number = ref as? NSNumber else { return nil }
        return CGWindowID(number.uint32Value)
    }

    private func pressButton(_ window: AXUIElement, attribute: CFString) {
        var ref: CFTypeRef?
        // 用 CFGetTypeID 运行时类型检查 + as!：as? 对 CF 类型会被编译器拒绝，
        // 纯 as! 不做运行时类型验证，个别 app 返回非 AXUIElement 类型会崩溃。
        // CFGetTypeID 预检查后 as! 安全（类型已验证）。
        guard AXUIElementCopyAttributeValue(window, attribute, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let button = value as! AXUIElement
        AXUIElementPerformAction(button, kAXPressAction as CFString)
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
