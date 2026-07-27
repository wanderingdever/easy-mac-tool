import AppKit
import Combine
import ScreenCaptureKit
import ServiceManagement
import SwiftUI

/// 权限设置 view: 权限管理 + 开机启动开关。原 SystemSettingsView 改名，
/// 内容不变——只调整标题与文件结构对应「权限设置」Tab。
struct PermissionsSettingsView: View {
    @State private var launchAtLogin = false
    // 权限状态本地缓存：每 2 秒定时刷新，让用户授权后回到设置窗口能看到
    // 状态图标变绿。直接读 AccessibilityChecker 的静态计算属性不会触发
    // SwiftUI 重绘，所以用 @State 显式持有并定时更新。
    @State private var accessibilityGranted = AccessibilityChecker.isTrusted
    @State private var screenRecordingGranted = AccessibilityChecker.isScreenRecordingTrusted
    @State private var inputMonitoringGranted = AccessibilityChecker.isInputMonitoringTrusted

    // 2 秒定时器，刷新权限状态。系统对话框关闭后用户回到设置窗口，
    // 状态应自动变绿。
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("权限设置").font(.title2).fontWeight(.semibold)

            // MARK: - 开机启动
            Section {
                Toggle("开机时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(enabled: newValue)
                    }
            } header: {
                Label("通用", systemImage: "gear")
            } footer: {
                Text("登录时自动启动 EasyMacTool。")
                    .font(.caption)
            }
            .padding(.vertical, 4)

            Divider()

            // MARK: - 权限
            VStack(alignment: .leading, spacing: 12) {
                Label("权限", systemImage: "checkmark.shield")
                    .font(.headline)
                Text("EasyMacTool 需要以下权限才能正常运行。点击「请求权限」后会同时调用系统 API 并打开系统设置，让应用出现在列表中，再开启开关。授权后约 2 秒状态自动刷新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                permissionRow(
                    title: "辅助功能",
                    description: "拦截 ⌘⇥ 并切换窗口。",
                    granted: accessibilityGranted,
                    onRequest: requestAccessibility,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )

                permissionRow(
                    title: "屏幕录制",
                    description: "显示窗口实时预览。",
                    granted: screenRecordingGranted,
                    onRequest: requestScreenRecording,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )

                permissionRow(
                    title: "输入监控",
                    description: "读取键盘事件以触发快捷键。",
                    granted: inputMonitoringGranted,
                    onRequest: requestInputMonitoring,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
                )
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loadLaunchAtLoginStatus() }
        .onReceive(permissionTimer) { _ in
            // 定时刷新权限状态，让用户授权后回到设置窗口看到变绿。
            accessibilityGranted = AccessibilityChecker.isTrusted
            screenRecordingGranted = AccessibilityChecker.isScreenRecordingTrusted
            inputMonitoringGranted = AccessibilityChecker.isInputMonitoringTrusted
        }
    }

    // MARK: - Launch at login

    private func loadLaunchAtLoginStatus() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private func toggleLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert on failure.
            launchAtLogin = !enabled
        }
    }

    // MARK: - Permission requests

    private func requestAccessibility() {
        let options: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): kCFBooleanTrue
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func requestScreenRecording() {
        // CGRequestScreenCaptureAccess 在 macOS 15+ 常静默失败，不会把 app
        // 加入系统列表。SCShareableContent.current 首次调用会触发 TCC 注册。
        _ = CGRequestScreenCaptureAccess()
        // 用信号量同步等待 async 调用完成，确保 TCC 注册在打开系统设置前完成。
        // Task.detached 不依赖主 actor，可在主线程被信号量阻塞时运行。
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            do {
                _ = try await SCShareableContent.current
                print("[TCC] SCShareableContent.current succeeded — app registered for Screen Recording")
            } catch {
                print("[TCC] SCShareableContent.current threw (expected if not authorized): \(error)")
            }
        }
        _ = semaphore.wait(timeout: .now() + 1.5)
    }

    private func requestInputMonitoring() {
        // IOHIDRequestAccess 在 macOS 15+ 常静默失败。实际创建一次
        // CGEventTap（.listenOnly）会强制 TCC 把 app 加入输入监控列表。
        _ = IOHIDRequestAccess(IOHIDRequestType(rawValue: 1))
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                       place: .headInsertEventTap,
                                       options: .listenOnly,
                                       eventsOfInterest: CGEventMask(eventMask),
                                       callback: { _, _, _, _ in nil },
                                       userInfo: nil) {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            print("[TCC] CGEventTap created — app registered for Input Monitoring")
        } else {
            // CGEventTap 创建失败通常意味着辅助功能权限未授权。
            print("[TCC] CGEventTap creation failed — needs Accessibility permission first")
        }
    }

    // MARK: - Row

    private func permissionRow(title: String, description: String, granted: Bool?, onRequest: @escaping () -> Void, settingsURL: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(granted)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(description).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    // 「请求权限」按钮：同时调请求 API + 跳转系统设置。
                    // 之前只调 API 不跳转，用户感知"没反应"（尤其屏幕录制在
                    // macOS 15+ 静默失败时）。现在点击后立即打开系统设置
                    // 对应面板，让用户看到可见反馈并手动开启开关。
                    Button("请求权限") {
                        onRequest()
                        openSystemSettings(settingsURL)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("打开系统设置") {
                        openSystemSettings(settingsURL)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// 打开 macOS 系统设置到指定隐私面板。延迟 0.3s 让系统 API 先注册
    /// 应用到列表（如 CGRequestScreenCaptureAccess），再跳转让用户看到。
    private func openSystemSettings(_ settingsURL: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let url = URL(string: settingsURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func statusIcon(_ granted: Bool?) -> some View {
        let name: String
        let color: Color
        switch granted {
        case .some(true):  name = "checkmark.circle.fill"; color = .green
        case .some(false): name = "xmark.circle.fill"; color = .red
        case .none:        name = "questionmark.circle.fill"; color = .gray
        }
        return Image(systemName: name)
            .foregroundStyle(color)
            .font(.title3)
    }
}
