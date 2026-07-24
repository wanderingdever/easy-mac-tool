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
    func activate(_ item: WindowItem) {
        let app = NSRunningApplication(processIdentifier: item.pid)

        if item.isPlaceholder {
            // 无窗口的运行中 app：用 NSWorkspace.openApplication 重新打开。
            // 这会触发 app 的 applicationShouldHandleReopen 回调，创建新窗口。
            // 比 app?.activate() 更可靠——后者对无窗口 app 不做任何事。
            if let bundleURL = app?.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: config)
            } else {
                // 无 bundleURL（极少见）：回退到 activate
                app?.activate(options: [.activateAllWindows])
            }
            return
        }

        // 有窗口：激活 app 并通过 AX 提升目标窗口到前台。
        app?.activate(options: [.activateAllWindows])

        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = findAXWindow(axApp, matching: item.frame) else { return }
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Closes the window by pressing its AX close button.
    func close(_ item: WindowItem) {
        guard !item.isPlaceholder else { return }
        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = findAXWindow(axApp, matching: item.frame) else { return }
        pressButton(window, attribute: kAXCloseButtonAttribute as CFString)
    }

    /// Minimizes the window by pressing its AX minimize button.
    func minimize(_ item: WindowItem) {
        guard !item.isPlaceholder else { return }
        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = findAXWindow(axApp, matching: item.frame) else { return }
        pressButton(window, attribute: kAXMinimizeButtonAttribute as CFString)
    }

    // MARK: - Private

    private func findAXWindow(_ axApp: AXUIElement, matching target: CGRect) -> AXUIElement? {
        var count: CFIndex = 0
        AXUIElementGetAttributeValueCount(axApp, kAXWindowsAttribute as CFString, &count)
        var windowsRef: CFArray?
        AXUIElementCopyAttributeValues(axApp, kAXWindowsAttribute as CFString, 0, count, &windowsRef)
        guard let axWindows = windowsRef as? [AXUIElement] else { return nil }

        for axWindow in axWindows {
            guard let position = cgPoint(axWindow, kAXPositionAttribute as CFString),
                  let size = cgSize(axWindow, kAXSizeAttribute as CFString) else { continue }
            let frame = CGRect(origin: position, size: size)
            // Match by origin (tolerant of sub-pixel drift); size is a secondary check.
            if abs(frame.origin.x - target.origin.x) < 2,
               abs(frame.origin.y - target.origin.y) < 2 {
                return axWindow
            }
        }
        return nil
    }

    private func pressButton(_ window: AXUIElement, attribute: CFString) {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &ref) == .success,
              let value = ref else { return }
        let button = value as! AXUIElement
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    private func cgPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let value = ref else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func cgSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let value = ref else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
