import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Wraps the TCC permission checks/prompts required for the event tap and AX APIs.
@MainActor
enum AccessibilityChecker {
    /// True iff the app has been granted Accessibility (required for CGEventTap `.defaultTap`
    /// and for cross-process AXUIElement use).
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Preflight (no prompt) for Screen Recording permission.
    static var isScreenRecordingTrusted: Bool { CGPreflightScreenCaptureAccess() }

    /// Preflight (no prompt) for Input Monitoring permission.
    /// Returns true if the app is already trusted to monitor input events.
    static var isInputMonitoringTrusted: Bool {
        // IOHIDCheckAccess returns kIOHIDAccessTypeGranted when granted.
        // kIOHIDRequestTypeListenEvent = 1 (observe input events).
        return IOHIDCheckAccess(IOHIDRequestType(rawValue: 1)) == kIOHIDAccessTypeGranted
    }

    /// Returns the set of permissions that are currently MISSING — empty
    /// if all required permissions are granted. Used to decide whether to
    /// trigger the system's native permission request flow.
    static var missingPermissions: [PermissionKind] {
        var missing: [PermissionKind] = []
        if !isTrusted { missing.append(.accessibility) }
        if !isScreenRecordingTrusted { missing.append(.screenRecording) }
        if !isInputMonitoringTrusted { missing.append(.inputMonitoring) }
        return missing
    }

    /// Triggers the system's NATIVE permission request flow for ALL missing
    /// permissions, opens EasyMacTool's settings window (to the 系统设置
    /// section so the user sees the three permissions' green/red status), AND
    /// opens macOS System Settings to the FIRST missing permission's pane
    /// (one pane at a time to avoid opening multiple System Settings windows).
    ///
    /// On macOS 15+ (Sequoia), `CGRequestScreenCaptureAccess()` 和
    /// `IOHIDRequestAccess()` 经常静默失败，不会把 app 加入系统列表。
    /// 辅助功能的 `AXIsProcessTrustedWithOptions` 会弹系统对话框所以能成功。
    /// 修复：录屏请求时实际触发一次 CGDisplayCreateImage（会触发 TCC 注册），
    /// 输入监控请求时实际创建一次 CGEventTap（会触发系统把 app 加入列表）。
    ///
    /// Returns true if any permission was missing (and thus requested),
    /// false if all permissions are already granted.
    @discardableResult
    static func requestAllMissingPermissions() -> Bool {
        let missing = missingPermissions
        guard !missing.isEmpty else { return false }

        // Request EACH missing permission's native API — system dialogs will
        // appear one by one. Even if a system API silently fails (e.g. Screen
        // Recording on macOS 15+), calling it is harmless and we still open
        // System Settings below as the reliable fallback.
        for kind in missing {
            switch kind {
            case .screenRecording:
                // CGRequestScreenCaptureAccess 在 macOS 15+ 常静默失败。
                // 实际触发一次 SCScreenshotManager 屏幕捕获会强制 TCC
                // 把 app 加入屏幕录制列表，用户在系统设置中可见。
                _ = CGRequestScreenCaptureAccess()
                triggerScreenCaptureRegistration()
            case .accessibility:
                let options: CFDictionary = [
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue(): kCFBooleanTrue
                ] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            case .inputMonitoring:
                // IOHIDRequestAccess 在 macOS 15+ 常静默失败。
                // 实际创建一次 CGEventTap（.listenOnly）会强制 TCC 把 app
                // 加入输入监控列表。创建后立即停止，只用于触发注册。
                _ = IOHIDRequestAccess(IOHIDRequestType(rawValue: 1))
                triggerInputMonitoringRegistration()
            }
        }

        // Open macOS System Settings to the FIRST missing permission's pane.
        // Opening one pane at a time avoids multiple System Settings windows.
        let order: [PermissionKind] = [.screenRecording, .accessibility, .inputMonitoring]
        if let firstKind = order.first(where: { missing.contains($0) }) {
            let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_\(firstKind.paneAnchor)"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }

        // Open EasyMacTool's own settings window and switch to the 系统设置
        // section so the user can see the three permissions' status icons.
        NotificationCenter.default.post(name: .openSettings, object: nil)
        NotificationCenter.default.post(name: .focusPermissionSection, object: nil)
        return true
    }

    /// 用 SCShareableContent.current 触发 TCC 把 app 注册到屏幕录制列表。
    /// 在 macOS 15+，CGRequestScreenCaptureAccess() 经常静默失败，不会把
    /// app 加入系统列表。SCShareableContent.current 首次调用时会触发系统
    /// 注册 app 到 TCC 数据库（即使最终抛错），用户在系统设置中可见。
    ///
    /// 使用 Task.detached 确保不依赖主 actor，可在主线程被阻塞时运行。
    /// CGDisplayCreateImage/CGDisplayStream 在 macOS 15+ 已不可用，
    /// ScreenCaptureKit 是唯一的现代 API。
    private static func triggerScreenCaptureRegistration() {
        // 用信号量让 async 调用同步等待完成，确保 TCC 注册在打开
        // 系统设置之前完成。最多等 3 秒避免 UI 长时间卡顿。
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            do {
                // 首次调用会触发系统注册 app 到 TCC 屏幕录制列表。
                _ = try await SCShareableContent.current
                print("[TCC] SCShareableContent.current succeeded — app should be in Screen Recording list")
            } catch {
                // 抛错是正常的（用户尚未授权），但 TCC 注册应该已发生。
                print("[TCC] SCShareableContent.current threw (expected if not authorized): \(error)")
            }
        }
        _ = semaphore.wait(timeout: .now() + 3.0)
    }

    /// 创建一个临时的 CGEventTap（headInsertEventTap, listenOnly）来强制
    /// TCC 把 app 加入输入监控列表。创建后立即停止并释放，只用于触发注册。
    /// 如果没有辅助功能权限会返回 nil（CGEventTap 需要 AX 权限才能创建）。
    private static func triggerInputMonitoringRegistration() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        // CGEventTapCallBack 回调签名需要4个参数：proxy, type, event, userInfo
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                    place: .headInsertEventTap,
                                    options: .listenOnly,
                                    eventsOfInterest: CGEventMask(eventMask),
                                    callback: { _, _, _, _ in nil },
                                    userInfo: nil)
        guard let eventTap = tap else {
            // 创建失败：可能缺少辅助功能权限（CGEventTap 需先有 AX 权限）。
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        // 短暂启用让 TCC 注册，然后移除。
        CGEvent.tapEnable(tap: eventTap, enable: true)
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
    }

    enum PermissionKind: String {
        case accessibility
        case screenRecording
        case inputMonitoring

        var displayName: String {
            switch self {
            case .accessibility: return "辅助功能"
            case .screenRecording: return "屏幕录制"
            case .inputMonitoring: return "输入监控"
            }
        }

        var paneAnchor: String {
            switch self {
            case .accessibility: return "Privacy_Accessibility"
            case .screenRecording: return "Privacy_ScreenCapture"
            case .inputMonitoring: return "Privacy_ListenEvent"
            }
        }
    }
}

extension Notification.Name {
    /// Posted when permissions are missing on launch/hotkey; SettingsRootView
    /// listens and switches its sidebar selection to the 系统设置 section so
    /// the user immediately sees the three permissions' status icons.
    static let focusPermissionSection = Notification.Name("EasyMacToolFocusPermissionSection")
}

