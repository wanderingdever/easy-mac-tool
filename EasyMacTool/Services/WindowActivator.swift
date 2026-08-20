import AppKit
import ApplicationServices
import os

/// Pure matching policy for selecting an AX window from an app's window list.
/// Kept separate from AX calls so the ambiguous-frame rules are unit-testable.
struct AXWindowMatchCandidate {
    let id: CGWindowID?
    let title: String
    let frame: CGRect
}

nonisolated enum AXWindowMatchResolver {
    /// A real WindowServer ID is unambiguous; prefer it whenever present.
    static func exactIndex(in candidates: [AXWindowMatchCandidate], targetID: CGWindowID) -> Int? {
        candidates.firstIndex { $0.id == targetID }
    }

    /// Frame-based fallback for apps that do not expose AXWindowID (Chrome,
    /// Chromium, and some Electron apps). A single frame match is accepted even
    /// when titles differ: SC window titles and AX titles frequently disagree
    /// (Chrome reports the tab title through SC, but "title - Google Chrome"
    /// through AX). With multiple same-frame candidates, titles are used to
    /// disambiguate via exact match or containment (the SC tab title is a
    /// substring of Chrome's AX title). Ambiguity is never guessed.
    static func frameFallbackIndex(
        in candidates: [AXWindowMatchCandidate],
        targetFrame: CGRect,
        targetTitle: String,
        tolerance: CGFloat = 2
    ) -> Int? {
        let frameMatches = candidates.indices.filter { index in
            let candidate = candidates[index]
            guard !candidate.frame.isNull, !targetFrame.isNull else { return false }
            return abs(candidate.frame.origin.x - targetFrame.origin.x) < tolerance
                && abs(candidate.frame.origin.y - targetFrame.origin.y) < tolerance
                && abs(candidate.frame.size.width - targetFrame.size.width) < tolerance
                && abs(candidate.frame.size.height - targetFrame.size.height) < tolerance
        }
        guard !frameMatches.isEmpty else { return nil }
        if frameMatches.count == 1 { return frameMatches[0] }

        let titleMatches = frameMatches.filter { index in
            let title = candidates[index].title
            return titlesAgree(title, targetTitle)
        }
        return titleMatches.count == 1 ? titleMatches[0] : nil
    }

    private static func titlesAgree(_ candidateTitle: String, _ targetTitle: String) -> Bool {
        if candidateTitle.isEmpty || targetTitle.isEmpty || candidateTitle == targetTitle {
            return true
        }
        let a = candidateTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let b = targetTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return a.contains(b) || b.contains(a)
    }
}

/// Brings a specific window (not just its app) to the front via the Accessibility
/// API, and supports closing / minimizing a window via its AX toolbar buttons.
@MainActor
final class WindowActivator {
    private var pendingHiddenActivation: Task<Void, Never>?
    private var pendingFocusActivation: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.easymactool", category: "WindowActivator")

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
        pendingFocusActivation?.cancel()
        pendingFocusActivation = nil
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
        guard let app, !app.isTerminated else { return false }

        // A hidden-app placeholder has no real window to resolve. It is still
        // useful to unhide/activate the app, but do not pretend a window was
        // focused or run an ID-based verification loop.
        if item.frame == .zero && !item.hasRealWindowID {
            app.activate(options: [])
            return true
        }

        // Resolve before app.activate. `activateAllWindows` used to let Chrome
        // restore Profile A after the app activation, racing the later AX focus
        // of Profile B. Resolve the exact AX window first and activate only the
        // app, then focus the same AX element again.
        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = resolvedWindow ?? findAXWindow(axApp, matching: item) else {
            Self.logger.error("Unable to resolve target window id=\(item.id, privacy: .public) title=\(item.title, privacy: .public)")
            return false
        }
        focus(window: window, pid: item.pid)
        app.activate(options: [])
        focus(window: window, pid: item.pid)
        scheduleFocusRetries(item: item, delays: [0.05, 0.12, 0.25])
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
        // Set both main and focused attributes. Some Chromium builds only
        // honor one of them when two profile windows share the same process.
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// 激活后按延迟序列重试 focus，处理异步落位窗口（全屏 / 慢应用）。
    /// 每次重试前守卫：目标 app 仍在运行、仍是前台、目标窗口仍可解析。
    private func scheduleFocusRetries(item: WindowItem, delays: [TimeInterval]) {
        let pid = item.pid
        pendingFocusActivation = Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in delays {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled,
                      let app = NSRunningApplication(processIdentifier: pid),
                      !app.isTerminated,
                      Self.frontmostPID(matching: pid) != nil else { return }
                guard let window = self.findAXWindow(
                    AXUIElementCreateApplication(pid), matching: item
                ) else { return }
                self.focus(window: window, pid: pid)
                if Self.frontmostWindowID(pid: pid) == item.id {
                    self.pendingFocusActivation = nil
                    return
                }
            }
            // Do not silently accept Chrome's other window as success. The
            // caller has already closed the overlay, but diagnostics make the
            // failed activation visible and the next snapshot can recover MRU.
            if Self.frontmostWindowID(pid: pid) != item.id {
                Self.logger.error("Target window id=\(item.id, privacy: .public) was not frontmost after AX focus retries")
            }
            self.pendingFocusActivation = nil
        }
    }

    /// WindowServer orders entries front-to-back. Restrict to normal/floating/
    /// modal levels so Chrome menus and omnibox popups do not count as windows.
    private static func frontmostWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  pid_t(ownerPID) == pid,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  (0...8).contains(layer),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 0, height > 0 else { continue }
            return CGWindowID(number)
        }
        return nil
    }

    /// Closes the window by pressing its AX close button.
    /// frame 兜底仅在唯一候选时生效；多个同 frame 候选且标题无法
    /// 区分时仍返回 nil，避免误关近似窗口。
    /// - Returns: true 表示成功找到窗口并按下了 close 按钮；
    ///   false 表示未找到窗口或按钮未暴露。调用方应仅在 true 时从列表移除 item，
    ///   false 时保留 item 并可选提示用户（避免"列表消失但窗口仍开"的困惑）。
    @discardableResult
    func close(_ item: WindowItem) -> Bool {
        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = findAXWindow(axApp, matching: item, allowFrameFallback: true) else { return false }
        return pressButton(window, attribute: kAXCloseButtonAttribute as CFString)
    }

    /// Minimizes the window by pressing its AX minimize button.
    /// 同 close：唯一 frame 候选允许兜底，歧义时不猜测。
    /// - Returns: true 表示成功按下 minimize 按钮；false 表示未找到窗口或按钮未暴露。
    @discardableResult
    func minimize(_ item: WindowItem) -> Bool {
        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = findAXWindow(axApp, matching: item, allowFrameFallback: true) else { return false }
        return pressButton(window, attribute: kAXMinimizeButtonAttribute as CFString)
    }

    /// Toggles fullscreen using the window's AX fullscreen button.
    /// - Returns: true when the button was found and the press succeeded.
    @discardableResult
    func toggleFullscreen(_ item: WindowItem) -> Bool {
        let axApp = AXUIElementCreateApplication(item.pid)
        guard let window = findAXWindow(axApp, matching: item, allowFrameFallback: true) else { return false }
        var fullscreenRef: CFTypeRef?
        let readResult = AXUIElementCopyAttributeValue(
            window, "AXFullScreen" as CFString, &fullscreenRef
        )
        let isFullscreen = (fullscreenRef as? NSNumber)?.boolValue ?? false
        let writeResult = AXUIElementSetAttributeValue(
            window,
            "AXFullScreen" as CFString,
            isFullscreen ? kCFBooleanFalse : kCFBooleanTrue
        )
        return readResult == .success && writeResult == .success
    }

    // MARK: - Private

    /// 在 AX 窗口列表中查找匹配 item 的窗口。
    /// - Parameter allowFrameFallback: 无 AXWindowID 时是否允许 frame 兜底匹配。
    ///   唯一 frame 候选可安全用于 activate/close/minimize/fullscreen；
    ///   多个同 frame 候选且标题无法区分时统一返回 nil。
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
        let candidates = axWindows.map { window in
            AXWindowMatchCandidate(
                id: windowID(of: window),
                title: title(of: window),
                frame: frame(of: window) ?? .null
            )
        }
        if item.hasRealWindowID {
            if let index = AXWindowMatchResolver.exactIndex(
                in: candidates,
                targetID: item.id
            ) {
                return axWindows[index]
            }
            // Some apps (e.g. Chrome) expose a CGWindowID through
            // ScreenCaptureKit but not through AXWindowID. Exact match can
            // legitimately fail, so activation still falls back to frame+title.
        }

        // 无 AXWindowID 的窗口：仅 activate 允许 frame 兜底匹配。
        // close/minimize 传入 allowFrameFallback=false，直接返回 nil（安全 no-op）。
        guard allowFrameFallback else { return nil }

        // Frame 唯一时直接采纳，不再要求 title 一致：Chrome 的 SC title 与
        // AX title 格式不同（Bilibili 标签页 vs "标题 - Google Chrome"）。
        // 多个同 frame 候选时再用 title 缩小；仍不唯一则返回 nil 不猜测。
        if let index = AXWindowMatchResolver.frameFallbackIndex(
            in: candidates,
            targetFrame: item.frame,
            targetTitle: item.title
        ) {
            return axWindows[index]
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
        let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if status != .success {
            Self.logger.error("AX press action failed: attribute=\(attribute, privacy: .public) status=\(status.rawValue, privacy: .public)")
        }
        return status == .success
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

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = cgPoint(element, kAXPositionAttribute as CFString),
              let size = cgSize(element, kAXSizeAttribute as CFString) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
