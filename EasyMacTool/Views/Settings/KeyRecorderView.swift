import AppKit
import CoreGraphics
import SwiftUI

/// A single button-like key-combo recorder matching `设置 · 剪切板.html`'s
/// `.key-recorder`: bordered box, mono font, inset shadow, shows the current
/// combo (e.g. ⌘⇧V); click to start recording, click again / Esc / 10s
/// timeout to cancel. While recording, the global CGEventTap is disabled so
/// key presses are not intercepted by the switcher.
struct KeyRecorderView: View {
    @Binding var keyCode: CGKeyCode
    @Binding var modifiers: CGEventFlags
    /// Return a user-facing reason to reject a recorded combination.
    var validationMessage: (CGKeyCode, CGEventFlags) -> String? = { _, _ in nil }
    /// Shared mutex so only ONE recorder on screen can be recording at a time.
    var isGlobalRecording: Binding<Bool> = .constant(false)

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejectionMessage: String?
    /// 录制超时 timer：10 秒后自动取消录制，防止 isRecording 卡住
    /// （如设置窗口在录制期间被非正常关闭，.onDisappear 未触发）。
    /// isRecording 卡住会导致 HotkeyManager 所有按键 pass through，
    /// 包括 Cmd+Shift+V 呼出剪切板快捷键。
    @State private var recordingTimeout: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            button
            if let rejectionMessage {
                Text(rejectionMessage)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Colors.error)
            }
        }
        .onDisappear { stopRecording() }
    }

    private var button: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            Group {
                if isRecording {
                    Text("按下快捷键…")
                        .font(.system(size: DesignTokens.SettingsTypography.kbd, design: .monospaced))
                        .foregroundStyle(DesignTokens.Aurora.tint)
                } else {
                    // kbd: 14pt mono, 0.04em letter-spacing (~0.6 tracking).
                    // 与录制态同字号（DesignTokens.SettingsTypography.kbd），
                    // 避免录制/非录制切换时字号跳变。
                    Text(KeyComboFormatter.format(keyCode: keyCode, modifiers: modifiers))
                        .font(.system(size: DesignTokens.SettingsTypography.kbd, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(DesignTokens.Colors.foreground)
                }
            }
            .frame(minWidth: 90)
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Settings.navItemRadius + 2, style: .continuous)
                    .fill(DesignTokens.Aurora.cardSurface)
            )
            .overlay(
                // Aurora v2：常态发丝描边；录制中品牌渐变描边 + 外发光。
                RoundedRectangle(cornerRadius: DesignTokens.Settings.navItemRadius + 2, style: .continuous)
                    .strokeBorder(
                        isRecording
                        ? AnyShapeStyle(DesignTokens.Aurora.brandGradient)
                        : AnyShapeStyle(DesignTokens.Aurora.cardBorder),
                        lineWidth: isRecording ? 1.5 : 1
                    )
            )
            .shadow(color: isRecording ? DesignTokens.Aurora.brandGlow : .clear,
                    radius: 5, y: 2)
            .animation(DesignTokens.Aurora.standard, value: isRecording)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onExitCommand {
            // Esc cancels recording (only meaningful while recording).
            if isRecording { stopRecording() }
        }
    }

    private func startRecording() {
        // 防重入守卫：SwiftUI 重绘是异步的，用户在按钮变为「取消」前可能连点
        // 两次，导致旧 monitor 引用被覆盖而永久泄漏。泄漏的 monitor 会持续
        // 拦截按键并悄悄修改快捷键，用户难以察觉。
        guard monitor == nil else { return }
        // 全局互斥：已有其他录制器在录制时，本录制器不介入。
        if isGlobalRecording.wrappedValue { return }
        rejectionMessage = nil
        isRecording = true
        isGlobalRecording.wrappedValue = true
        // Disable the global event tap so it doesn't intercept the key being
        // recorded. The recorder needs to see the raw keypress.
        // 引用计数语义：多个录制器同时处于录制态时互不干扰。
        HotkeyManager.shared.beginRecording()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Ignore bare modifier presses; wait for the actual key.
            if event.type == .flagsChanged { return event }
            guard event.type == .keyDown else { return event }

            // Esc cancels recording without recording a combo.
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            let nsFlags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            // Require at least one modifier (otherwise it's a normal keypress).
            guard !nsFlags.isEmpty else {
                NSSound.beep()
                return nil
            }
            // Convert NSEvent.ModifierFlags → CGEventFlags.
            var cgFlags: CGEventFlags = []
            if nsFlags.contains(.command) { cgFlags.insert(.maskCommand) }
            if nsFlags.contains(.option)  { cgFlags.insert(.maskAlternate) }
            if nsFlags.contains(.shift)  { cgFlags.insert(.maskShift) }
            if nsFlags.contains(.control) { cgFlags.insert(.maskControl) }
            let keyCode = CGKeyCode(event.keyCode)
            if let message = validationMessage(keyCode, cgFlags) {
                rejectionMessage = message
                NSSound.beep()
                return nil
            }
            self.keyCode = keyCode
            modifiers = cgFlags
            stopRecording()
            return nil
        }
        // 10 秒超时自动取消录制。防止设置窗口在录制期间被 Cmd+W 关闭、
        // .onDisappear 未触发导致 isRecording 永久为 true、所有快捷键失效。
        // 用 Timer + RunLoop.main.add(.common) 替代 Timer.scheduledTimer：
        // 后者仅加入 .default 模式，若录制期间有 NSMenu 模态会话（如右键菜单），
        // 定时器不触发会导致 isRecording 永久卡住。
        let t = Timer(timeInterval: 10, repeats: false) { _ in
            stopRecording()
        }
        RunLoop.main.add(t, forMode: .common)
        recordingTimeout = t
    }

    private func stopRecording() {
        recordingTimeout?.invalidate()
        recordingTimeout = nil
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        // 配对守卫：只有本录制器确实 beginRecording 过（isRecording == true）
        // 才调用 endRecording。否则两种场景会触发 HotkeyManager 的
        // "beginRecording/endRecording not paired" 断言：
        // 1. .onDisappear 在视图销毁时调用 stopRecording，但用户从未开始录制；
        // 2. 录制中按 Esc，本地 monitor 与 .onExitCommand 各触发一次 stopRecording。
        guard isRecording else { return }
        isRecording = false
        isGlobalRecording.wrappedValue = false
        // Re-enable the global event tap（引用计数 -1，归零才恢复拦截）。
        HotkeyManager.shared.endRecording()
    }
}
