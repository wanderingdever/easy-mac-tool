import SwiftUI

/// 关于 view: 渐变品牌图标 + app 名称 + 版本 + 简单描述。
/// 设计稿：96×96 蓝色渐变圆角方块内嵌白色 "E"，标题 22pt bold，
/// 版本 12pt，描述 14pt。
struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            // 渐变品牌图标（设计稿：linear-gradient(160deg, #2e8dff, #007aff 55%, #004fad)）
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(DesignTokens.aboutIconGradient)
                Text("E")
                    .font(.system(size: 86, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 96, height: 96)
            .shadow(color: Color.accentColor.opacity(0.5), radius: 12, x: 0, y: 8)
            .padding(.bottom, 18)

            Text("EasyMacTool")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.01)

            Text("版本 \(appVersion)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            Text("让您轻松使用Mac")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 16)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(EdgeInsets(top: 32, leading: 48, bottom: 36, trailing: 48))
        .background(DesignTokens.Colors.card)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "\(version)"
    }
}
