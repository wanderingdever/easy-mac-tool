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

    /// Returns the set of permissions that are currently MISSING — empty
    /// if all required permissions are granted. Used to decide whether to
    /// trigger the system's native permission request flow.
    ///
    /// 输入监控（Input Monitoring）已彻底移除：app 使用 .defaultTap 的
    /// CGEventTap，运行时只需要辅助功能权限（AX 是 IM 的超集，AX 授权后
    /// IM 自动通过）。IM 权限仅 .listenOnly tap 需要，app 未使用；
    /// 设置页也不再展示 IM 状态，避免误导用户追逐非必需权限。
    static var missingPermissions: [PermissionKind] {
        var missing: [PermissionKind] = []
        if !isTrusted { missing.append(.accessibility) }
        if !isScreenRecordingTrusted { missing.append(.screenRecording) }
        return missing
    }

    /// Triggers the system's NATIVE permission request flow for ALL missing
    /// permissions, opens EasyMacTool's settings window (to the 系统设置
    /// section so the user sees the permissions' green/red status), AND
    /// opens macOS System Settings to the FIRST missing permission's pane
    /// (one pane at a time to avoid opening multiple System Settings windows).
    ///
    /// On macOS 15+ (Sequoia), `CGRequestScreenCaptureAccess()` 常静默失败，
    /// 不会把 app 加入系统列表。辅助功能的 `AXIsProcessTrustedWithOptions`
    /// 会弹系统对话框所以能成功。修复：录屏请求时实际触发一次
    /// SCShareableContent.current（会触发 TCC 注册）。
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
                // 实际触发一次 SCShareableContent.current 会强制 TCC
                // 把 app 加入屏幕录制列表，用户在系统设置中可见。
                _ = CGRequestScreenCaptureAccess()
                triggerScreenCaptureRegistration()
            case .accessibility:
                let options: CFDictionary = [
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue(): kCFBooleanTrue
                ] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        }

        // Open macOS System Settings to the FIRST missing permission's pane.
        // Opening one pane at a time avoids multiple System Settings windows.
        // AX 缺失时系统对话框自带"打开系统设置"按钮，不重复跳转避免竞态。
        let order: [PermissionKind] = [.screenRecording, .accessibility]
        if let firstKind = order.first(where: { missing.contains($0) }), firstKind != .accessibility {
            let urlString = "x-apple.systempreferences:com.apple.settings.PrivacySecurity?Privacy_\(firstKind.paneAnchor)"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }

        // Open EasyMacTool's own settings window and switch to the 系统设置
        // section so the user can see the permissions' status icons.
        // .openSettings 触发 openWindow（异步），SettingsRootView 需时间挂载，
        // 延迟发送 .focusPermissionSection 避免通知丢失。
        NotificationCenter.default.post(name: .openSettings, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .focusPermissionSection, object: nil)
        }
        return true
    }

    /// 仅触发 TCC 注册副作用（不弹设置页、不打开系统设置）。
    /// 用于启动时权限检查的重试阶段：当 missingPermissions 非空时，
    /// 主动调用 SCShareableContent.current 让 TCC 把当前进程 cdhash
    /// 重新加入数据库。对 ad-hoc 签名下的 cdhash 失配有修复作用。
    ///
    /// 只触发屏幕录制注册：辅助功能通过 AXIsProcessTrustedWithOptions
    /// 弹对话框触发（已在 requestAllMissingPermissions 中处理）。
    static func triggerRegistrationOnly() {
        triggerScreenCaptureRegistration()
    }

    /// 用 SCShareableContent.current 触发 TCC 把 app 注册到屏幕录制列表。
    /// 在 macOS 15+，CGRequestScreenCaptureAccess() 经常静默失败，不会把
    /// app 加入系统列表。SCShareableContent.current 首次调用时会触发系统
    /// 注册 app 到 TCC 数据库（即使最终抛错），用户在系统设置中可见。
    ///
    /// 使用 Task.detached 异步触发——TCC 注册是异步副作用，不依赖主线程
    /// 同步等待。之前的 semaphore.wait(3s) 在主线程会冻结 UI 最长 3 秒
    /// （用户按 Cmd+Tab 缺权限时尤其严重）。
    private static func triggerScreenCaptureRegistration() {
        Task.detached {
            do {
                // 首次调用会触发系统注册 app 到 TCC 屏幕录制列表。
                _ = try await SCShareableContent.current
                print("[TCC] SCShareableContent.current succeeded — app should be in Screen Recording list")
            } catch {
                // 抛错是正常的（用户尚未授权），但 TCC 注册应该已发生。
                print("[TCC] SCShareableContent.current threw (expected if not authorized): \(error)")
            }
        }
    }

    enum PermissionKind: String {
        case accessibility
        case screenRecording

        var displayName: String {
            switch self {
            case .accessibility: return "辅助功能"
            case .screenRecording: return "屏幕录制"
            }
        }

        var paneAnchor: String {
            switch self {
            case .accessibility: return "Privacy_Accessibility"
            case .screenRecording: return "Privacy_ScreenCapture"
            }
        }
    }
}

extension Notification.Name {
    /// Posted when permissions are missing on launch/hotkey; SettingsRootView
    /// listens and switches its sidebar selection to the 系统设置 section so
    /// the user immediately sees the permissions' status icons.
    static let focusPermissionSection = Notification.Name("EasyMacToolFocusPermissionSection")
}

