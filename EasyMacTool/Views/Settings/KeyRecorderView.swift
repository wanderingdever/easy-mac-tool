import AppKit
import CoreGraphics
import SwiftUI

/// A control that displays the current key combo and, when "录制" is clicked,
/// captures the next key press and updates the bound `keyCode`/`modifiers`.
/// During recording, the global CGEventTap is disabled so key presses are not
/// intercepted by the switcher.
struct KeyRecorderView: View {
    @Binding var keyCode: CGKeyCode
    @Binding var modifiers: CGEventFlags

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if isRecording {
                Text("按下快捷键…")
                    .foregroundStyle(.secondary)
                Button("取消") { stopRecording() }
                    .buttonStyle(.borderless)
            } else {
                Text(KeyComboFormatter.format(keyCode: keyCode, modifiers: modifiers))
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                Button("录制") { startRecording() }
                    .buttonStyle(.borderless)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        // Disable the global event tap so it doesn't intercept the key being
        // recorded. The recorder needs to see the raw keypress.
        HotkeyManager.shared.isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Ignore bare modifier presses; wait for the actual key.
            if event.type == .flagsChanged { return event }
            guard event.type == .keyDown else { return event }

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
            keyCode = CGKeyCode(event.keyCode)
            modifiers = cgFlags
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        // Re-enable the global event tap.
        HotkeyManager.shared.isRecording = false
    }
}
