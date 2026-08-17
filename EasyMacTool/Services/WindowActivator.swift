import AppKit
import ApplicationServices

/// Brings a specific window (not just its app) to the front via the Accessibility
/// API, and supports closing / minimizing a window via its AX toolbar buttons.
@MainActor
final class WindowActivator {
    private var pendingHiddenActivation: Task<Void, Never>?

    /// Activates the owning app and raises the exact window matching `item.frame`.
    /// For placeholder items (no open windows), uses `NSWorkspace.openApplication`
    /// to reopen the app — this triggers `applicationShouldHandleReopen` which
    /// creates a new window for most macOS apps.
    ///
    /// 根据 windowState 先恢复可见性：
    /// - .visible：直接激活
    /// - .minimized：先 AX deminimize（AXMinimized=false）
    /// - .hidden：先 app.unhide()，再检查是否需要 deminimize（边界：app hidden + 窗口 minimized）
    ///
    /// - Returns: true 表示成功激活窗口（找到 AX 窗口并设置 focus）；
    ///   false 表示窗口未找到或激活失败，调用方可据此保留 item 或提示用户。
    @discardableResult
    func activate(_ item: WindowItem) -> Bool {
        pendingHiddenActivation?.cancel()
        pendingHiddenActivation = nil
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
            app?.unhide()
            pendingHiddenActivation = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self else { return }
                let axApp = AXUIElementCreateApplication(item.pid)
                let resolvedWindow = self.findAXWindow(axApp, matching: item)
                if let window = resolvedWindow {
                    var isMinimizedRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &isMinimizedRef)
                    if (isMinimizedRef as? NSNumber)?.boolValue == true {
                        AXUIElementSetAttributeValue(
                            window, kAXMinimizedAttribute as CFString, kCFBooleanFalse
                        )
                    }
                }
                _ = self.finishActivation(item, app: app, resolvedWindow: resolvedWindow)
                self.pendingHiddenActivation = nil
            }
            return true
        }

        return finishActivation(item, app: app, resolvedWindow: resolvedWindow)
    }

    private func finishActivation(_ item: WindowItem,
                                  app: NSRunningApplication?,
                                  resolvedWindow: AXUIElement?) -> Bool {
        // 激活 app 并通过 AX 提升目标窗口到前台。
        // 复用第一次 findAXWindow 的结果，避免 app.activate 后窗口列表变化导致第二次查找失败。
        app?.activate(options: [.activateAllWindows])

        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = resolvedWindow ?? findAXWindow(axApp, matching: item) else { return false }
        focus(window: window, pid: item.pid)
        // Space 切换 / 部分 app 的 main window 是异步落位（晚一两个 run loop），
        // 单次设置可能失败。按延迟序列重试 focus，直到前台稳定为目标 app。
        scheduleFocusRetries(item: item, delays: [0.12])
        return true
    }

    /// Returns the app's frontmost pid if it matches the target; nil otherwise.
    /// 仅当目标 app 仍是前台时才重试，避免在用户已切走的窗口上抢焦点。
    private static func frontmostPID(matching pid: pid_t) -> pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == pid else { return nil }
        return pid
    }

    /// 对一个窗口做强 focus：设为 app 的 focused/main 窗口并 raise。
    private func focus(window: AXUIElement, pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// 激活后按延迟序列重试 focus，处理异步落位窗口（全屏 / 慢应用）。
    /// 每次重试前守卫：目标 app 仍在运行、仍是前台、目标窗口仍可解析。
    private func scheduleFocusRetries(item: WindowItem, delays: [TimeInterval]) {
        let pid = item.pid
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                // 目标 app 已退出，或前台已不是目标 app（用户已切走），放弃重试。
                guard let app = NSRunningApplication(processIdentifier: pid),
                      !app.isTerminated,
                      Self.frontmostPID(matching: pid) != nil else { return }
                let axApp = AXUIElementCreateApplication(pid)
                guard let window = self.findAXWindow(axApp, matching: item) else { return }
                self.focus(window: window, pid: pid)
            }
        }
    }

    /// Closes the window by pressing its AX close button.
    /// 禁用 frame 兜底匹配：close 涉及数据丢失风险（未保存文档被关），
    /// 仅允许真实 windowID 精确匹配。无 AXWindowID 的窗口放弃关闭——
    /// 安全的 no-op 优于误关近似窗口。
    /// - Returns: true 表示成功找到窗口并按下了 close 按钮；
    ///   false 表示未找到窗口或按钮未暴露。调用方应仅在 true 时从列表移除 item，
    ///   false 时保留 item 并可选提示用户（避免"列表消失但窗口仍开"的困惑）。
    @discardableResult
    func close(_ item: WindowItem) -> Bool {
        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = findAXWindow(axApp, matching: item, allowFrameFallback: false) else { return false }
        return pressButton(window, attribute: kAXCloseButtonAttribute as CFString)
    }

    /// Minimizes the window by pressing its AX minimize button.
    /// 同 close：禁用 frame 兜底，避免误最小化近似窗口。
    /// - Returns: true 表示成功按下 minimize 按钮；false 表示未找到窗口或按钮未暴露。
    @discardableResult
    func minimize(_ item: WindowItem) -> Bool {
        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = findAXWindow(axApp, matching: item, allowFrameFallback: false) else { return false }
        return pressButton(window, attribute: kAXMinimizeButtonAttribute as CFString)
    }

    // MARK: - Private

    /// 在 AX 窗口列表中查找匹配 item 的窗口。
    /// - Parameter allowFrameFallback: 无 AXWindowID 时是否允许 frame 兜底匹配。
    ///   activate 允许（激活错误窗口无数据丢失风险）；close/minimize 禁用
    ///   （误关/误最小化有数据丢失风险）。
    private func findAXWindow(_ axApp: AXUIElement, matching item: WindowItem, allowFrameFallback: Bool = true) -> AXUIElement? {
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

        // 无 AXWindowID 的窗口：仅 activate 允许 frame 兜底匹配。
        // close/minimize 传入 allowFrameFallback=false，直接返回 nil（安全 no-op）。
        guard allowFrameFallback else { return nil }

        // A small number of apps do not expose AXWindowID. Keep a conservative
        // fallback for them, requiring origin + size + title 全部匹配。
        // 仅 frame 匹配会误匹配同 app 近似窗口（如两个全屏终端），
        // 增加 title 辅助校验降低误匹配概率。
        for axWindow in axWindows {
            guard let position = cgPoint(axWindow, kAXPositionAttribute as CFString),
                  let size = cgSize(axWindow, kAXSizeAttribute as CFString) else { continue }
            let frame = CGRect(origin: position, size: size)
            let target = item.frame
            guard abs(frame.origin.x - target.origin.x) < 2,
                  abs(frame.origin.y - target.origin.y) < 2,
                  abs(frame.size.width - target.size.width) < 2,
                  abs(frame.size.height - target.size.height) < 2 else { continue }
            // frame 匹配后追加 title 校验：同 app 近似窗口通常 title 不同
            // （如 "Terminal — bash" vs "Terminal — ssh"），可进一步排除。
            // title 为空时（少数 app 不暴露 title）回退为仅 frame 匹配。
            let axTitle = title(of: axWindow)
            if axTitle.isEmpty || item.title.isEmpty || axTitle == item.title {
                return axWindow
            }
        }
        return nil
    }

    /// 读取 AX 窗口的 title 属性，失败返回空字符串。
    private func title(of element: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref) == .success,
              let title = ref as? String else { return "" }
        return title
    }

    private func windowID(of element: AXUIElement) -> CGWindowID? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXWindowID" as CFString, &ref) == .success,
              let number = ref as? NSNumber else { return nil }
        return CGWindowID(number.uint32Value)
    }

    /// 按下窗口的指定 AX 按钮（close / minimize）。
    /// - Returns: true 表示成功找到按钮并执行了 press；false 表示按钮未暴露
    ///   或属性查询失败。调用方据此决定是否从切换器列表移除 item：
    ///   若返回 false，窗口实际仍开着/未最小化，移除 item 会让用户困惑
    ///   （"列表消失了但窗口还在"）。
    @discardableResult
    private func pressButton(_ window: AXUIElement, attribute: CFString) -> Bool {
        var ref: CFTypeRef?
        // 用 CFGetTypeID 运行时类型检查 + as!：as? 对 CF 类型会被编译器拒绝，
        // 纯 as! 不做运行时类型验证，个别 app 返回非 AXUIElement 类型会崩溃。
        // CFGetTypeID 预检查后 as! 安全（类型已验证）。
        guard AXUIElementCopyAttributeValue(window, attribute, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let button = value as! AXUIElement
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        return true
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
