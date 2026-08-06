import AppKit
import SwiftUI

/// Design tokens aligned with `easymactool-ui.design/colors_and_type.css`.
/// Maps the design system's semantic tokens to macOS-native semantic colors
/// so dark mode adapts automatically. Explicit hex values are used only where
/// native semantic colors cannot express the design (gradients, fixed filter
/// dot colors, the about icon).
enum DesignTokens {
    // MARK: - Radii
    enum Radius {
        static let card: CGFloat = 12
        static let cell: CGFloat = 14
        static let control: CGFloat = 8
        static let small: CGFloat = 6
        static let pill: CGFloat = 999
        static let panel: CGFloat = 24
        static let dropdown: CGFloat = 8
    }

    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
    }

    // MARK: - Shadows
    /// Card-level shadow (raised slightly off the surface).
    static let cardShadow = (radius: CGFloat(4), y: CGFloat(2), opacity: Double(0.06))
    /// Hover/floating shadow.
    static let floatShadow = (radius: CGFloat(8), y: CGFloat(4), opacity: Double(0.08))
    /// Modal/overlay shadow.
    static let modalShadow = (radius: CGFloat(16), y: CGFloat(8), opacity: Double(0.12))

    // MARK: - Semantic colors
    /// Maps the design CSS semantic tokens to adaptive macOS colors.
    /// Light values follow the design (`colors_and_type.css`); dark values
    /// use the design's `.dark` overrides so both modes match the spec.
    enum Colors {
        /// `--apple-background` #ffffff / #000000 — page-level background.
        static let background = Color(nsColor: .textBackgroundColor)
        /// `--apple-card` #ffffff / #1c1c1e — card surface (same as background in light).
        static let card = Color(nsColor: .textBackgroundColor)
        /// `--apple-secondary` / `--apple-muted` / `--apple-sidebar` #f2f2f7 / #1c1c1e
        /// — grouped cards, sidebar, secondary surfaces.
        static let secondarySurface = dynamicColor(
            light: Color(red: 0.949, green: 0.949, blue: 0.969),    // #f2f2f7
            dark: Color(red: 0.110, green: 0.110, blue: 0.118)        // #1c1c1e
        )
        /// `--apple-sidebar` — sidebar background (same as secondarySurface).
        static let sidebar = secondarySurface
        /// `--apple-border` #e5e5ea / #3a3a3c — hairline borders & dividers.
        static let border = Color(nsColor: .separatorColor)
        /// `--apple-foreground` #1d1d1f / #f5f5f7 — primary text.
        static let foreground = Color.primary
        /// `--apple-muted-foreground` #8e8e93 — secondary descriptive text.
        static let mutedForeground = Color.secondary
        /// `--apple-primary` #007aff / #2e8dff — brand blue (selected nav, slider fill).
        static let primary = Color.accentColor
        /// `--apple-primary-foreground` #ffffff — text on primary fills.
        static let primaryForeground = Color.white
        /// `--state-success` #34c759 — granted status / toggle-on.
        static let success = Color.green
        /// `--state-error` #ff3b30 — denied status / destructive.
        static let error = Color.red
        /// `--state-error-surface` #ffecea — destructive hover background.
        static let errorSurface = dynamicColor(
            light: Color(red: 1.000, green: 0.925, blue: 0.918),     // #ffecea
            dark: Color(red: 0.290, green: 0.149, blue: 0.149)
        )
    }

    // MARK: - Settings typography (from `设置 · 剪切板.html` / `设置 · 权限.html`)
    enum SettingsTypography {
        /// Sidebar nav item — 13pt.
        static let navItem: CGFloat = 13
        /// Sidebar title (EasyMacTool) — 12pt semibold.
        static let sidebarTitle: CGFloat = 12
        /// Page title (权限设置) — 20pt semibold, -0.01em tracking.
        static let pageTitle: CGFloat = 20
        /// Section header (呼出快捷键 / 行为 / 历史) — 17pt semibold.
        static let sectionHeader: CGFloat = 17
        /// Group header (通用) — 13pt semibold.
        static let groupHeader: CGFloat = 13
        /// Sub-section header (权限) — 15pt semibold.
        static let subHeader: CGFloat = 15
        /// Section caption / footer / desc — 12pt.
        static let caption: CGFloat = 12
        /// Form label — 13pt.
        static let formLabel: CGFloat = 13
        /// Toggle title — 15pt medium.
        static let toggleTitle: CGFloat = 15
        /// Row label — 13pt.
        static let rowLabel: CGFloat = 13
        /// Slider range labels — 11pt.
        static let sliderRange: CGFloat = 11
        /// Slider value (mono) — 13pt.
        static let sliderValue: CGFloat = 13
        /// Key recorder kbd (mono) — 14pt.
        static let kbd: CGFloat = 14
        /// Permission title — 15pt semibold.
        static let permTitle: CGFloat = 15
        /// Small button — 12pt.
        static let buttonSmall: CGFloat = 12
    }

    // MARK: - Settings layout constants
    enum Settings {
        static let sidebarWidth: CGFloat = 180
        static let toolbarHeight: CGFloat = 40
        static let navItemHeight: CGFloat = 36
        static let navItemRadius: CGFloat = 6
        static let navItemHPadding: CGFloat = 10
        static let navItemVPadding: CGFloat = 0
        static let navItemIconSize: CGFloat = 16
        static let navItemGap: CGFloat = 8
        static let formRowMinHeight: CGFloat = 36
        static let formSectionRadius: CGFloat = 8
        static let splitRadius: CGFloat = 8
        static let contentPadding = EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24)
        static let contentSpacing: CGFloat = 20
        /// Section body margin-top + inter-row gap (design: mt 14, gap 12).
        static let sectionBodyTop: CGFloat = 14
        static let sectionBodyGap: CGFloat = 12
        /// Form row label width + row gap (design: label 80, gap 14).
        static let formLabelWidth: CGFloat = 80
        static let formRowGap: CGFloat = 14
        /// Group card padding/row metrics (design: row padding 10/14, min-h 34).
        static let groupCardRadius: CGFloat = 8
        static let groupRowHPadding: CGFloat = 14
        static let groupRowVPadding: CGFloat = 10
        /// Permission card metrics (design: padding 12, gap 12, status 20).
        static let permCardPadding: CGFloat = 12
        static let permCardGap: CGFloat = 12
        static let permStatusSize: CGFloat = 20
        static let permActionsGap: CGFloat = 6
        static let permActionsTop: CGFloat = 10
    }

    /// Builds an adaptive `Color` from explicit light/dark values.
    /// Used for design tokens that have no exact native semantic equivalent.
    static func dynamicColor(light: Color, dark: Color) -> Color {
        Color(NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [
                .darkAqua,
                .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark
            ]) != nil {
                return NSColor(dark)
            }
            return NSColor(light)
        } ?? NSColor(light))
    }

    // MARK: - Filter dot colors (fixed per design spec)
    enum FilterDot {
        static let all: Color    = Color(red: 0.557, green: 0.557, blue: 0.576) // #8e8e93
        static let text: Color   = Color(red: 0.000, green: 0.478, blue: 1.000)  // #007AFF
        static let link: Color   = Color(red: 0.204, green: 0.781, blue: 0.349)  // #34C759
        static let image: Color  = Color(red: 0.686, green: 0.322, blue: 0.871)  // #AF52DE
        static let file: Color   = Color(red: 1.000, green: 0.584, blue: 0.000)  // #FF9500
        static let color: Color  = Color(red: 1.000, green: 0.176, blue: 0.573)  // #FF2D92
    }

    // MARK: - About icon gradient (#2e8dff → #007aff → #004fad)
    static let aboutIconGradient = LinearGradient(
        colors: [
            Color(red: 0.180, green: 0.553, blue: 1.000), // #2e8dff
            Color(red: 0.000, green: 0.478, blue: 1.000),  // #007aff
            Color(red: 0.000, green: 0.310, blue: 0.678)   // #004fad
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Aurora 渐变设计体系（v2 现代化改版）
    //
    // 全应用统一的视觉语言：
    // - 品牌渐变：蓝 → 靛 → 紫（Apple 系统色系，和谐不刺眼），仅用于关键
    //   强调处（选中导航、主按钮、选中描边、品牌图标），克制使用避免杂乱。
    // - 玻璃质感：Material + 极光色调微光叠加层 + 白色发丝描边。
    // - 分层阴影：卡片浮起 / 悬浮 / 模态三级，全部明暗自适应。
    enum Aurora {
        // MARK: 品牌渐变色标（明暗自适应，浅色版 Apple 系统色系）
        /// Soft Blue — light #4C9FFF / dark #5CA9FF
        static let blue = dynamicColor(
            light: Color(red: 0.298, green: 0.624, blue: 1.000),
            dark: Color(red: 0.361, green: 0.663, blue: 1.000)
        )
        /// Soft Indigo — light #827FF0 / dark #918FF5
        static let indigo = dynamicColor(
            light: Color(red: 0.510, green: 0.498, blue: 0.941),
            dark: Color(red: 0.569, green: 0.561, blue: 0.961)
        )
        /// Soft Purple — light #C982F2 / dark #D18BF7
        static let violet = dynamicColor(
            light: Color(red: 0.788, green: 0.510, blue: 0.949),
            dark: Color(red: 0.820, green: 0.545, blue: 0.969)
        )

        /// 品牌主渐变（对角）：用于选中导航、主按钮、品牌图标。
        static let brandGradient = LinearGradient(
            stops: [
                .init(color: blue, location: 0.0),
                .init(color: indigo, location: 0.55),
                .init(color: violet, location: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// 品牌水平渐变：用于顶部装饰线、选中描边。
        static let brandHorizontal = LinearGradient(
            stops: [
                .init(color: blue, location: 0.0),
                .init(color: indigo, location: 0.55),
                .init(color: violet, location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )

        /// 控件统一 tint（Toggle / Slider / 链接按钮）：取渐变中段的浅靛蓝，
        /// 与渐变视觉同源但保证控件上可读性。
        static let tint = dynamicColor(
            light: Color(red: 0.427, green: 0.545, blue: 0.969),   // #6D8BF7
            dark: Color(red: 0.486, green: 0.608, blue: 1.000)      // #7C9BFF
        )

        /// 控件「开启/填充」态专用色：品牌蓝的**纯饱和**版本（即渐变蓝锚点
        /// #007AFF / #0A84FF）。开关/滑块的开启填充必须用足够饱和的色，否则
        /// 在浅色卡片上开启态会与关闭态的灰色几乎无法区分（用户反馈「没颜色变化」）。
        /// 仍与品牌渐变同源（取渐变蓝端），但保证清晰可读。
        static let controlOn = dynamicColor(
            light: Color(red: 0.000, green: 0.478, blue: 1.000),   // #007AFF system blue
            dark: Color(red: 0.039, green: 0.518, blue: 1.000)      // #0A84FF
        )

        // MARK: 玻璃面板微光叠加
        /// 毛玻璃面板上的极光微光：顶部一抹极淡的蓝→紫渐变，向下渐隐。
        /// 让 ultraThinMaterial 不再单调，同时不干扰内容可读性。
        static let glassSheen = LinearGradient(
            colors: [
                blue.opacity(0.10),
                indigo.opacity(0.05),
                Color.clear
            ],
            startPoint: .topLeading,
            endPoint: .bottom
        )

        /// 面板顶部发丝高光线（玻璃上边缘反光）。
        static let glassEdgeLight = LinearGradient(
            colors: [Color.white.opacity(0.55), Color.white.opacity(0.05)],
            startPoint: .leading,
            endPoint: .trailing
        )

        // MARK: 分组设置页表面（明暗自适应）
        /// 设置页背景（grouped）：light 冷调浅灰 #f4f5f9 / dark #17171b
        static let pageBackground = dynamicColor(
            light: Color(red: 0.957, green: 0.961, blue: 0.976),
            dark: Color(red: 0.090, green: 0.090, blue: 0.106)
        )
        /// 设置卡片表面：light 纯白 / dark #242429
        static let cardSurface = dynamicColor(
            light: Color(red: 1.000, green: 1.000, blue: 1.000),
            dark: Color(red: 0.141, green: 0.141, blue: 0.161)
        )
        /// 卡片发丝描边：light 黑 5% / dark 白 9%
        static let cardBorder = dynamicColor(
            light: Color.black.opacity(0.05),
            dark: Color.white.opacity(0.09)
        )
        /// 侧栏背景：与页面背景同族，略深一档形成层次。
        static let sidebarBackground = dynamicColor(
            light: Color(red: 0.929, green: 0.933, blue: 0.953),
            dark: Color(red: 0.118, green: 0.118, blue: 0.137)
        )
        /// 行内分隔线（卡片内部，非满宽）。
        static let insetSeparator = dynamicColor(
            light: Color.black.opacity(0.06),
            dark: Color.white.opacity(0.08)
        )

        // MARK: 阴影（明暗自适应的阴影颜色）
        /// 卡片浮起阴影：细腻、低透明度。
        static let cardShadowColor = dynamicColor(
            light: Color.black.opacity(0.05),
            dark: Color.black.opacity(0.35)
        )
        /// 悬浮元素阴影（菜单、筛选浮层、预览卡片）。
        static let floatShadowColor = dynamicColor(
            light: Color.black.opacity(0.14),
            dark: Color.black.opacity(0.50)
        )
        /// 品牌色外发光（选中态）：靛蓝 30%，明暗通用。
        static let brandGlow = indigo.opacity(0.32)

        // MARK: 动画曲线（全应用统一）
        /// 标准过渡：hover / 选中切换。
        static let standard = Animation.easeOut(duration: 0.16)
        /// 弹性入场：浮层、预览弹入。
        static let springy = Animation.spring(response: 0.35, dampingFraction: 0.82)
    }
}

// MARK: - Aurora 共享组件

/// 渐变图标 Chip：圆角方块内嵌 SF Symbol。
/// 两种形态：
/// - `subdued`（默认）：品牌渐变 12% 底 + 渐变字形，用于 section header、
///   菜单项、统计等辅助强调位。
/// - `solid`：品牌渐变实底 + 白色字形 + 品牌色投影，用于品牌头部、
///   选中态等核心强调位。
struct AuroraIconChip: View {
    let systemName: String
    var size: CGFloat = 26
    var solid: Bool = false

    var body: some View {
        let radius = size * 0.28
        ZStack {
            if solid {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(DesignTokens.Aurora.brandGradient)
                Image(systemName: systemName)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(DesignTokens.Aurora.brandGradient.opacity(0.14))
                Image(systemName: systemName)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(DesignTokens.Aurora.brandGradient)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: solid ? DesignTokens.Aurora.brandGlow : .clear,
                radius: solid ? 6 : 0, y: solid ? 3 : 0)
    }
}

/// kbd 快捷键胶囊：等宽字体 + 表面填充 + 发丝描边。
/// 用于菜单快捷键、切换器底部操作提示。
struct AuroraKbd: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(DesignTokens.Aurora.cardBorder, lineWidth: 1)
            )
    }
}

/// 品牌渐变主按钮样式：实底渐变 + 白字 + 品牌色投影，按下缩放 0.97。
struct AuroraPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DesignTokens.Aurora.brandGradient)
            )
            .shadow(color: DesignTokens.Aurora.brandGlow,
                    radius: configuration.isPressed ? 2 : 6,
                    y: configuration.isPressed ? 1 : 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(DesignTokens.Aurora.standard, value: configuration.isPressed)
    }
}

/// View 扩展：设置分组卡片容器样式（表面填充 + 发丝描边 + 浮起阴影）。
extension View {
    /// 应用统一的设置卡片视觉：cardSurface 底、1px 发丝描边、圆角 12、
    /// 低透明度浮起阴影。
    func auroraSettingsCard(cornerRadius: CGFloat = 12) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(DesignTokens.Aurora.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DesignTokens.Aurora.cardBorder, lineWidth: 1)
            )
            .shadow(color: DesignTokens.Aurora.cardShadowColor, radius: 8, y: 2)
    }

    /// 渐变描边：用于选中态（切换器缩略图、剪切板卡片）。
    func auroraGradientStroke(cornerRadius: CGFloat, lineWidth: CGFloat = 2.5) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(DesignTokens.Aurora.brandGradient, lineWidth: lineWidth)
        )
    }
}
