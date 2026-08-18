import AppKit
import Combine
import ScreenCaptureKit
import ServiceManagement
import SwiftUI
import os

/// 权限设置（Aurora v2）：通用卡片 + 权限卡片列表。
/// 权限卡片带状态胶囊（已授权 = 绿渐变 / 未授权 = 红），
/// 「请求权限」为品牌渐变主按钮，与全应用 Aurora 语言一致。
struct PermissionsSettingsView: View {
    nonisolated private static let logger = Logger(subsystem: "com.easymactool", category: "PermissionsSettings")
    @State private var launchAtLogin = false
    // 权限状态本地缓存：每 2 秒定时刷新，让用户授权后回到设置窗口能看到
    // 状态图标变绿。直接读 AccessibilityChecker 的静态计算属性不会触发
    // SwiftUI 重绘，所以用 @State 显式持有并定时更新。
    @State private var accessibilityGranted = AccessibilityChecker.isTrusted
    @State private var screenRecordingGranted = AccessibilityChecker.isScreenRecordingTrusted
    @State private var finderAutomationStatus: FinderAutomationAuthorization.Status = .unavailable

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Settings.contentSpacing) {
                generalSection
                permissionsSection
            }
            .padding(DesignTokens.Settings.contentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignTokens.Aurora.pageBackground)
        .onAppear {
            loadLaunchAtLoginStatus()
            refreshPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Returning from System Settings is the meaningful refresh point;
            // avoid a permanent two-second polling wakeup.
            refreshPermissionStatus()
        }
    }

    // MARK: - General group-card

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "通用", systemImage: "gear")
            SettingsCard(spacing: 0) {
                HStack {
                    Text("开机时自动启动")
                        .scaledSystemFont(DesignTokens.SettingsTypography.rowLabel)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .accessibilityLabel("开机时自动启动")
                        .toggleStyle(.switch)
                        .tint(DesignTokens.Aurora.controlOn)
                        .controlSize(.small)
                        .onChange(of: launchAtLogin) { _, newValue in
                            toggleLaunchAtLogin(enabled: newValue)
                        }
                }
            }
        }
    }

    // MARK: - Permissions cards

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "权限", systemImage: "checkmark.shield")
            Text("需要以下权限才能正常运行，点击「请求权限」后会同时调用系统 API 并打开系统设置，让应用出现在列表中，再开启开关。授权后约 2 秒状态自动刷新。")
                .scaledSystemFont(DesignTokens.SettingsTypography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 4)

            permissionRow(
                icon: "hand.point.up.left",
                title: "辅助功能",
                description: "拦截 ⌘⇥ 并切换窗口。",
                granted: accessibilityGranted,
                onRequest: requestAccessibility,
                settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity?Privacy_Accessibility"
            )
            permissionRow(
                icon: "rectangle.dashed.badge.record",
                title: "屏幕录制",
                description: "显示窗口实时预览。",
                granted: screenRecordingGranted,
                onRequest: requestScreenRecording,
                settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity?Privacy_ScreenCapture"
            )
            finderAutomationRow
            keychainInformationRow
            // 输入监控（Input Monitoring）已移除：app 使用 .defaultTap 的
            // CGEventTap，运行时只需辅助功能权限（AX 是 IM 的超集，AX 授权
            // 后 IM 自动通过）。展示 IM 状态反而可能误导用户去追逐一个
            // 非必需的权限项。
        }
    }

    private func permissionRow(icon: String, title: String, description: String, granted: Bool?, onRequest: @escaping () -> Void, settingsURL: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Settings.permCardGap) {
            // 权限图标：渐变淡底 chip，统一品牌语言。
            AuroraIconChip(systemName: icon, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .scaledSystemFont(DesignTokens.SettingsTypography.permTitle, weight: .semibold)
                        .foregroundStyle(.primary)
                    statusPill(granted)
                }
                Text(description)
                    .scaledSystemFont(DesignTokens.SettingsTypography.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: DesignTokens.Settings.permActionsGap + 2) {
                    // 「请求权限」：品牌渐变主按钮，同时调请求 API + 跳转系统设置。
                    Button("请求权限") {
                        onRequest()
                        openSystemSettings(settingsURL)
                    }
                    .buttonStyle(AuroraPrimaryButtonStyle())
                    borderlessLinkButton("打开系统设置") {
                        openSystemSettings(settingsURL)
                    }
                }
                .padding(.top, DesignTokens.Settings.permActionsTop)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .auroraSettingsCard()
    }

    private var keychainInformationRow: some View {
        let description = "用于保存本机生成的剪贴板历史 AES-GCM 加密密钥；不会读取其他应用、网站或账户密码；密钥仅限本设备使用且不通过 iCloud 同步。"
        return HStack(alignment: .top, spacing: DesignTokens.Settings.permCardGap) {
            AuroraIconChip(systemName: "key.fill", size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("钥匙串")
                        .scaledSystemFont(DesignTokens.SettingsTypography.permTitle, weight: .semibold)
                        .foregroundStyle(.primary)
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                        Text("自动使用")
                            .scaledSystemFont(10, weight: .semibold, relativeTo: .caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DesignTokens.Colors.success))
                }
                Text(description)
                    .scaledSystemFont(DesignTokens.SettingsTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .auroraSettingsCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("钥匙串，自动使用")
        .accessibilityHint(description)
    }

    private var finderAutomationRow: some View {
        HStack(alignment: .top, spacing: DesignTokens.Settings.permCardGap) {
            AuroraIconChip(systemName: "folder.badge.gearshape", size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Finder 自动化")
                        .scaledSystemFont(DesignTokens.SettingsTypography.permTitle,
                                          weight: .semibold)
                        .foregroundStyle(.primary)
                    statusPill(finderAutomationGranted)
                }
                Text("仅在卸载需要管理员权限的应用或残留文件时，让 Finder 将已确认项目移至废纸篓。")
                    .scaledSystemFont(DesignTokens.SettingsTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DesignTokens.Settings.permActionsGap + 2) {
                    Button("请求权限") {
                        requestFinderAutomation()
                    }
                    .buttonStyle(AuroraPrimaryButtonStyle())
                    borderlessLinkButton("打开系统设置") {
                        NSWorkspace.shared.open(FinderAutomationAuthorization.settingsURL)
                    }
                }
                .padding(.top, DesignTokens.Settings.permActionsTop)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .auroraSettingsCard()
    }

    private var finderAutomationGranted: Bool? {
        switch finderAutomationStatus {
        case .granted: true
        case .denied: false
        case .notDetermined, .unavailable: nil
        }
    }

    /// 状态胶囊：已授权 = 绿底白字 check；未授权 = 红底白字叹号；
    /// 未知 = 灰底问号。替代原来孤立的 20pt 状态图标，语义更明确。
    private func statusPill(_ granted: Bool?) -> some View {
        let text: String
        let icon: String
        let bg: Color
        switch granted {
        case .some(true):
            text = "已授权"; icon = "checkmark"; bg = DesignTokens.Colors.success
        case .some(false):
            text = "未授权"; icon = "exclamationmark"; bg = DesignTokens.Colors.error
        case .none:
            text = "未知"; icon = "questionmark"; bg = Color(nsColor: .secondaryLabelColor)
        }
        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .scaledSystemFont(10, weight: .semibold, relativeTo: .caption2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(bg))
    }

    /// Borderless link button: 12pt 品牌 tint 色 + external-link icon。
    private func borderlessLinkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .regular))
            }
            .scaledSystemFont(DesignTokens.SettingsTypography.buttonSmall, weight: .medium)
            .foregroundStyle(DesignTokens.Aurora.tint)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
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

    private func refreshPermissionStatus() {
        accessibilityGranted = AccessibilityChecker.isTrusted
        screenRecordingGranted = AccessibilityChecker.isScreenRecordingTrusted
        Task {
            finderAutomationStatus = await Task.detached(priority: .utility) {
                FinderAutomationAuthorization.currentStatus()
            }.value
        }
    }

    private func requestAccessibility() {
        let options: CFDictionary = [
            "AXTrustedCheckOptionPrompt" as CFString: kCFBooleanTrue
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func requestScreenRecording() {
        // CGRequestScreenCaptureAccess 在 macOS 15+ 常静默失败，不会把 app
        // 加入系统列表。SCShareableContent.current 首次调用会触发 TCC 注册。
        _ = CGRequestScreenCaptureAccess()
        // 完全异步：不阻塞主线程。之前的 semaphore.wait(1.5) 会冻结 UI，
        // 触发 Thread Performance Checker priority inversion 警告。
        Task.detached {
            do {
                _ = try await SCShareableContent.current
                Self.logger.info("SCShareableContent.current succeeded — app registered for Screen Recording")
            } catch {
                Self.logger.info("SCShareableContent.current threw (expected if not authorized): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func requestFinderAutomation() {
        Task {
            finderAutomationStatus = await FinderAutomationAuthorization.requestPermission()
            if finderAutomationStatus == .denied {
                NSWorkspace.shared.open(FinderAutomationAuthorization.settingsURL)
            }
        }
    }

    // MARK: - Helpers

    /// 打开 macOS 系统设置到指定隐私面板。延迟 0.3s 让系统 API 先注册
    /// 应用到列表（如 CGRequestScreenCaptureAccess），再跳转让用户看到。
    private func openSystemSettings(_ settingsURL: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let url = URL(string: settingsURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
