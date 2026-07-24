import SwiftUI

/// 关于 view: app 名称、版本、图标、简单描述。
struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Text("EasyMacTool")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("版本 \(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("macOS 窗口切换管理工具")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
