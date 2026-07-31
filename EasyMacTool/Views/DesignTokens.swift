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
}
