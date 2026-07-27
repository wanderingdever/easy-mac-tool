import AppKit
import SwiftUI

/// Top-level settings window: a `NavigationSplitView` with a sidebar of sections
/// on the left and the selected section's content on the right.
struct SettingsRootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case windowSwitcher = "窗口切换"
        case clipboard = "剪切板"
        case systemInfo = "系统信息"
        case permissions = "权限设置"
        case about = "关于"
        var id: String { rawValue }
    }

    @State private var selection: Section? = .windowSwitcher

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: iconName(for: section))
                    .tag(section)
            }
            .navigationTitle("EasyMacTool")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch selection {
            case .windowSwitcher:
                WindowSwitcherSettingsView()
            case .clipboard:
                ClipboardSettingsView()
            case .systemInfo:
                SystemInfoSettingsView()
            case .permissions:
                PermissionsSettingsView()
            case .about:
                AboutView()
            case .none:
                Text("选择一个分类").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { activateAndBringToFront() }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            activateAndBringToFront()
        }
        // 权限缺失时跳转到「权限设置」section，让用户立即看到三项权限状态。
        .onReceive(NotificationCenter.default.publisher(for: .focusPermissionSection)) { _ in
            selection = .permissions
        }
    }

    private func iconName(for section: Section) -> String {
        switch section {
        case .windowSwitcher: return "rectangle.3.offgrid"
        case .clipboard: return "doc.on.clipboard"
        case .systemInfo: return "speedometer"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }

    /// Activates the app and brings the settings window to the front.
    private func activateAndBringToFront() {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.title.contains("EasyMacTool 设置") {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
