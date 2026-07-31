import AppKit
import Combine
import ScreenCaptureKit
import ServiceManagement
import SwiftUI

/// 权限设置 view: 通用 group-card + 权限卡片列表。对应「权限设置」Tab。
/// 布局遵循 `设置 · 权限.html`：20pt 页面标题，group-card（secondary bg /
/// 8pt radius / 1px border）承载开关行，权限卡片用 secondary bg + 12pt
/// padding + 20pt 状态图标。
struct PermissionsSettingsView: View {
    @State private var launchAtLogin = false
    // 权限状态本地缓存：每 2 秒定时刷新，让用户授权后回到设置窗口能看到
    // 状态图标变绿。直接读 AccessibilityChecker 的静态计算属性不会触发
    // SwiftUI 重绘，所以用 @State 显式持有并定时更新。
    @State private var accessibilityGranted = AccessibilityChecker.isTrusted
    @State private var screenRecordingGranted = AccessibilityChecker.isScreenRecordingTrusted

    // 2 秒定时器，刷新权限状态。系统对话框关闭后用户回到设置窗口，
    // 状态应自动变绿。
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Settings.contentSpacing) {
            generalSection
            Divider()
            permissionsSection
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Settings.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignTokens.Colors.card)
        .onAppear { loadLaunchAtLoginStatus() }
        .onReceive(permissionTimer) { _ in
            // 定时刷新权限状态，让用户授权后回到设置窗口看到变绿。
            accessibilityGranted = AccessibilityChecker.isTrusted
            screenRecordingGranted = AccessibilityChecker.isScreenRecordingTrusted
        }
    }

    // MARK: - General group-card

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupHeader("通用", systemImage: "gear")
            // group-card: secondary bg, 8pt radius, 1px border, overflow hidden.
            VStack(spacing: 0) {
                HStack {
                    Text("开机时自动启动")
                        .font(.system(size: DesignTokens.SettingsTypography.rowLabel))
                        .foregroundStyle(DesignTokens.Colors.foreground)
                    Spacer(minLength: 0)
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: launchAtLogin) { _, newValue in
                            toggleLaunchAtLogin(enabled: newValue)
                        }
                }
                .padding(.vertical, DesignTokens.Settings.groupRowVPadding)
                .padding(.horizontal, DesignTokens.Settings.groupRowHPadding)
                .frame(minHeight: DesignTokens.Settings.formRowMinHeight)
            }
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Settings.groupCardRadius, style: .continuous)
                    .fill(DesignTokens.Colors.secondarySurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Settings.groupCardRadius, style: .continuous)
                    .strokeBorder(DesignTokens.Colors.border, lineWidth: 1)
            )
            Text("登录时自动启动")
                .font(.system(size: DesignTokens.SettingsTypography.caption))
                .foregroundStyle(DesignTokens.Colors.mutedForeground)
                .padding(.horizontal, 4)
        }
    }

    /// Group header: 13pt semibold + 14pt muted-foreground icon, gap 6.
    private func groupHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.mutedForeground)
            Text(title)
                .font(.system(size: DesignTokens.SettingsTypography.groupHeader, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.foreground)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    // MARK: - Permissions cards

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(DesignTokens.Colors.mutedForeground)
                Text("权限")
                    .font(.system(size: DesignTokens.SettingsTypography.subHeader, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.foreground)
            }
            Text("EasyMacTool 需要以下权限才能正常运行。点击「请求权限」后会同时调用系统 API 并打开系统设置，让应用出现在列表中，再开启开关。授权后约 2 秒状态自动刷新。")
                .font(.system(size: DesignTokens.SettingsTypography.caption))
                .foregroundStyle(DesignTokens.Colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)

            permissionRow(
                title: "辅助功能",
                description: "拦截 ⌘⇥ 并切换窗口。",
                granted: accessibilityGranted,
                onRequest: requestAccessibility,
                settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity?Privacy_Accessibility"
            )
            permissionRow(
                title: "屏幕录制",
                description: "显示窗口实时预览。",
                granted: screenRecordingGranted,
                onRequest: requestScreenRecording,
                settingsURL: "x-apple.systempreferences:com.apple.settings.PrivacySecurity?Privacy_ScreenCapture"
            )
            // 输入监控（Input Monitoring）已移除：app 使用 .defaultTap 的
            // CGEventTap，运行时只需辅助功能权限（AX 是 IM 的超集，AX 授权
            // 后 IM 自动通过）。展示 IM 状态反而可能误导用户去追逐一个
            // 非必需的权限项。
        }
    }

    private func permissionRow(title: String, description: String, granted: Bool?, onRequest: @escaping () -> Void, settingsURL: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Settings.permCardGap) {
            statusIcon(granted)
                .frame(width: DesignTokens.Settings.permStatusSize, height: DesignTokens.Settings.permStatusSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: DesignTokens.SettingsTypography.permTitle, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.foreground)
                Text(description)
                    .font(.system(size: DesignTokens.SettingsTypography.caption))
                    .foregroundStyle(DesignTokens.Colors.mutedForeground)
                HStack(spacing: DesignTokens.Settings.permActionsGap) {
                    // 「请求权限」按钮：同时调请求 API + 跳转系统设置。
                    borderedButton("请求权限") {
                        onRequest()
                        openSystemSettings(settingsURL)
                    }
                    borderlessLinkButton("打开系统设置") {
                        openSystemSettings(settingsURL)
                    }
                }
                .padding(.top, DesignTokens.Settings.permActionsTop)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Settings.permCardPadding)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Settings.groupCardRadius, style: .continuous)
                .fill(DesignTokens.Colors.secondarySurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Settings.groupCardRadius, style: .continuous)
                .strokeBorder(DesignTokens.Colors.border, lineWidth: 1)
        )
    }

    /// Bordered button: 12pt, 4×10 padding, 6pt radius, 1px border, card bg.
    private func borderedButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: DesignTokens.SettingsTypography.buttonSmall))
                .foregroundStyle(DesignTokens.Colors.foreground)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Settings.navItemRadius, style: .continuous)
                        .fill(DesignTokens.Colors.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Settings.navItemRadius, style: .continuous)
                        .strokeBorder(DesignTokens.Colors.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// Borderless link button: 12pt primary color with external-link icon.
    private func borderlessLinkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .regular))
            }
            .font(.system(size: DesignTokens.SettingsTypography.buttonSmall))
            .foregroundStyle(DesignTokens.Colors.primary)
            .padding(.vertical, 4)
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
        // 完全异步：不阻塞主线程。之前的 semaphore.wait(1.5) 会冻结 UI，
        // 触发 Thread Performance Checker priority inversion 警告。
        Task.detached {
            do {
                _ = try await SCShareableContent.current
                print("[TCC] SCShareableContent.current succeeded — app registered for Screen Recording")
            } catch {
                print("[TCC] SCShareableContent.current threw (expected if not authorized): \(error)")
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

    private func statusIcon(_ granted: Bool?) -> some View {
        let name: String
        let color: Color
        switch granted {
        case .some(true):  name = "checkmark.circle.fill"; color = DesignTokens.Colors.success
        case .some(false): name = "exclamationmark.circle.fill"; color = DesignTokens.Colors.error
        case .none:        name = "questionmark.circle.fill"; color = Color(nsColor: .secondaryLabelColor)
        }
        return Image(systemName: name)
            .foregroundStyle(color)
            .font(.system(size: DesignTokens.Settings.permStatusSize, weight: .regular))
    }
}
