import AppKit
import SwiftUI

/// 菜单栏下拉弹窗（Aurora v2 改版）。
///
/// 结构：品牌头部（渐变图标 + 名称 + 版本）→ 渐变发丝分隔线 → 菜单项。
/// 菜单项统一为「渐变图标 chip + 标题 + kbd 快捷键胶囊」三段式，
/// hover 时整行填充品牌渐变、文字与 chip 反白，与全应用 Aurora 语言一致。
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            gradientDivider
                .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 2) {
                MenuItemRow(icon: "gearshape",
                            title: "设置",
                            shortcut: "⌘ ,",
                            action: openSettings)
                MenuItemRow(icon: "power",
                            title: "退出",
                            shortcut: "⌘ Q",
                            action: { NSApp.terminate(nil) })
            }
        }
        .padding(8)
        .frame(width: 200)
    }

    // MARK: - 品牌头部

    private var header: some View {
        HStack(spacing: 10) {
            AuroraIconChip(systemName: "bolt.fill", size: 18, solid: true)
            VStack(alignment: .leading, spacing: 1) {
                Text("EasyMacTool")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// 渐变发丝分隔线：品牌渐变白中心向两端渐隐，替代生硬的 Divider。
    private var gradientDivider: some View {
        DesignTokens.Aurora.brandHorizontal
            .opacity(0.35)
            .frame(height: 1)
            .mask(
                LinearGradient(
                    colors: [.clear, .black, .black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .padding(.horizontal, 10)
    }

    /// 直接调用 openWindow 打开设置窗口，不再发送 .openSettings 通知——
    /// 通知会被 BlackEMenuBarIcon 接收再次调 openWindow，形成递归。
    private func openSettings() {
        openWindow(id: "settings")
        DispatchQueue.main.async {
            NSApp.activate()
        }
    }
}

/// 菜单项：图标 chip + 标题 + 右侧快捷键胶囊。
/// hover：整行品牌渐变实底 + 白字白图标 + 品牌色微投影；
/// 非 hover：渐变淡底 chip + 主文字 + 灰色 kbd 胶囊。
/// 过渡动画统一 Aurora.standard，按下缩放 0.98 提供触感反馈。
/// 用自定义 ButtonStyle 暴露 isPressed 状态——之前用 DragGesture(minimumDistance: 0)
/// 模拟按压检测，但 DragGesture.onEnded 对静止 tap 可能不触发，导致 scaleEffect
/// 罕见生效。ButtonStyle.configuration.isPressed 由 SwiftUI 按钮事件原生驱动，
/// 可靠性更高。
private struct MenuItemRow: View {
    let icon: String
    let title: String
    let shortcut: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // 图标 chip：hover 反白（白色 20% 底 + 白字形），
                // 非 hover 品牌渐变淡底 + 渐变字形。
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered
                              ? AnyShapeStyle(.white.opacity(0.22))
                              : AnyShapeStyle(DesignTokens.Aurora.brandGradient.opacity(0.14)))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isHovered
                                         ? AnyShapeStyle(.white)
                                         : AnyShapeStyle(DesignTokens.Aurora.brandGradient))
                }
                .frame(width: 22, height: 22)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHovered ? Color.white : Color.primary)

                Spacer(minLength: 0)

                // 快捷键胶囊：hover 时变为半透明白底白字。
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isHovered ? Color.white.opacity(0.9) : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isHovered ? Color.white.opacity(0.18) : Color.primary.opacity(0.05))
                    )
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered
                          ? AnyShapeStyle(DesignTokens.Aurora.brandGradient)
                          : AnyShapeStyle(.clear))
            )
            .shadow(color: isHovered ? DesignTokens.Aurora.brandGlow : .clear,
                    radius: 6, y: 2)
        }
        .buttonStyle(MenuItemRowButtonStyle())
        .onHover { hovering in
            withAnimation(DesignTokens.Aurora.standard) { isHovered = hovering }
        }
    }
}

/// MenuItemRow 专用 ButtonStyle：按下时缩放 0.98 提供触感反馈。
/// 替代之前的 DragGesture(minimumDistance: 0) 模拟按压检测——onEnded 对静止
/// tap 可能不触发。configuration.isPressed 由 SwiftUI 按钮事件原生驱动。
private struct MenuItemRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(DesignTokens.Aurora.standard, value: configuration.isPressed)
    }
}
