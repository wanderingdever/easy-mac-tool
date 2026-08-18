import SwiftUI

/// 关于页（Aurora v2）：品牌渐变图标 + 名称 + 版本胶囊 + 描述 +
/// 三个功能 chip。图标使用全应用统一的 Aurora 品牌渐变，
/// 与侧栏头部、菜单栏弹窗的品牌头部一致。
struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // 品牌图标：Aurora 渐变实底圆角方块 + 白色闪电字形 + 外发光。
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(DesignTokens.Aurora.brandGradient)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 96, height: 96)
            .shadow(color: DesignTokens.Aurora.brandGlow, radius: 18, y: 8)
            .padding(.bottom, 18)

            Text("EasyMacTool")
                .scaledSystemFont(22, weight: .bold, relativeTo: .title2)

            // 版本胶囊：品牌渐变淡底 + 渐变文字。
            Text("版本 \(appVersion)")
                .scaledSystemFont(11, weight: .medium, relativeTo: .caption)
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Aurora.brandGradient)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(DesignTokens.Aurora.brandGradient.opacity(0.12))
                )
                .padding(.top, 8)

            Text("让您轻松使用 Mac")
                .scaledSystemFont(14)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(EdgeInsets(top: 32, leading: 48, bottom: 36, trailing: 48))
        .background(DesignTokens.Aurora.pageBackground)
    }

    private func featureChip(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.Aurora.brandGradient)
            Text(title)
                .scaledSystemFont(12, weight: .medium, relativeTo: .caption)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DesignTokens.Aurora.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(DesignTokens.Aurora.cardBorder, lineWidth: 1)
        )
        .shadow(color: DesignTokens.Aurora.cardShadowColor, radius: 6, y: 2)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "\(version)"
    }
}
