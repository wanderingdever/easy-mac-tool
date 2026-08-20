import AppKit
import SwiftUI

/// The visual switcher strip: a wrapping flow of live window thumbnails.
/// Implements Windows Alt+Tab interaction:
/// - Mouse hover over a cell shows a LIGHTER "aim" border (preview only).
///   Hover does NOT select — keyboard Tab/Shift+Tab has higher priority.
/// - Single click promotes the hovered cell to selection AND activates it.
/// - Releasing the hotkey activates the keyboard-selected cell, not the
///   hovered one.
/// No entrance animation — loads instantly like Windows.
///
/// Layout: header (gradient chip + title + count capsule) → wrapping
/// thumbnail grid → footer (keyboard hint bar). The panel grows vertically
/// to fit all rows (see OverlayPanelController.positionPanel).
///
/// Aurora v2：毛玻璃底 + 极光微光 + 顶部反光高线，选中态品牌渐变描边 +
/// 外发光。header/footer 的固定高度必须与
/// OverlayPanelController.positionPanel 的 headerBlock/footerBlock 一致。
struct SwitcherOverlayView: View {
    @ObservedObject var controller: OverlayPanelController
    /// Called on click to select + activate the clicked window.
    var onActivate: (Int) -> Void
    /// Called when hover auto-select should move the keyboard selection.
    var onSelect: (Int) -> Void
    var onWindowAction: (WindowItem, WindowControlAction) -> Void

    // MARK: - 固定布局常量（与 positionPanel 同步）
    /// 切换器不再包含搜索栏，顶部固定块为 0。
    static let headerBlock: CGFloat = 0
    /// footer 提示条高度（18）+ 与网格的间距（12）。
    static let footerBlock: CGFloat = 18 + 12
    /// 面板最小宽度：保证 footer 内容不拥挤。
    static let minPanelWidth: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            FlowLayout(spacing: DesignTokens.Spacing.md) {
                ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                    SwitcherThumbnailEntry(
                        item: item,
                        isSelected: index == controller.selectedIndex,
                        selectionIndex: controller.selectedIndex,
                        size: controller.previewSize,
                        style: controller.switcherStyle,
                        hoverSelects: controller.mouseHoverSelects,
                        onActivate: { onActivate(index) },
                        onHoverSelect: { onSelect(index) },
                        onWindowAction: { action in
                            onWindowAction(item, action)
                        })
                }
            }
            footer
                .padding(.top, 12)
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // Aurora v2 玻璃面板：ultraThinMaterial 底 + 极光微光 sheen +
            // 白色发丝描边 + 顶部反光高线。背景撑满 hosting.view，
            // 四角圆角由 hosting.view.layer cornerRadius=24 裁剪，完全一致。
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                            .fill(DesignTokens.Aurora.glassSheen)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                            .strokeBorder(DesignTokens.Aurora.cardBorder, lineWidth: 1)
                    )
                // 顶部发丝高光线（玻璃上缘反光），两端渐隐。
                DesignTokens.Aurora.glassEdgeLight
                    .frame(height: 1)
                    .mask(
                        LinearGradient(colors: [.clear, .black, .black, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .padding(.horizontal, 32)
                    .padding(.top, 0.5)
            }
        )	
        // 外阴影由 NSPanel.hasShadow 提供——SwiftUI .shadow 会被
        // masksToBounds 裁掉，所以不在这里加。
        // Disable ALL animations — switcher appears instantly and selection
        // changes don't trigger layout transitions that cause flicker.
        .transaction { $0.animation = nil }
        .animation(nil, value: controller.items.count)
        .animation(nil, value: controller.selectedIndex)
    }

    // MARK: - Footer 键盘提示条（高度 18，与 footerBlock 同步）

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            hint(keys: "⇥", action: "切换")
            hint(keys: "⏎", action: "打开")
            hint(keys: "⌘Q", action: "关闭窗口")
            hint(keys: "esc", action: "取消")
            Spacer(minLength: 0)
        }
        .frame(height: 18)
    }

    private func hint(keys: String, action: String) -> some View {
        HStack(spacing: 5) {
            AuroraKbd(text: keys)
            Text(action)
                .scaledSystemFont(11, relativeTo: .caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Keeps hover state inside one thumbnail so pointer movement does not publish
/// through the controller and diff the entire switcher tree.
private struct SwitcherThumbnailEntry: View {
    let item: WindowItem
    let isSelected: Bool
    let selectionIndex: Int
    let size: AppSettings.PreviewSize
    let style: AppSettings.SwitcherStyle
    let hoverSelects: Bool
    let onActivate: () -> Void
    let onHoverSelect: () -> Void
    let onWindowAction: (WindowControlAction) -> Void
    @State private var isHovered = false

    var body: some View {
        WindowThumbnailCell(item: item, isSelected: isSelected,
                            isHover: isHovered, size: size, style: style,
                            controlsOverlay: (isHovered || isSelected)
                                ? AnyView(windowControlButtons)
                                : nil)
            .contentShape(Rectangle())
            .auroraHover($isHovered, animated: false) { hovering in
                if hovering, hoverSelects { onHoverSelect() }
            }
            .onTapGesture(perform: onActivate)
            .onChange(of: selectionIndex) { _, _ in isHovered = false }
    }

    private var windowControlButtons: some View {
        HStack(spacing: 5) {
            TrafficLightButton(
                color: Color(nsColor: .systemRed),
                systemImage: WindowControlAction.close.systemImage,
                accessibilityLabel: WindowControlAction.close.accessibilityLabel
            ) {
                onWindowAction(.close)
            }
            TrafficLightButton(
                color: Color(nsColor: .systemYellow),
                systemImage: WindowControlAction.minimize.systemImage,
                accessibilityLabel: WindowControlAction.minimize.accessibilityLabel
            ) {
                onWindowAction(.minimize)
            }
            TrafficLightButton(
                color: Color(nsColor: .systemGreen),
                systemImage: WindowControlAction.fullscreen.systemImage,
                accessibilityLabel: WindowControlAction.fullscreen.accessibilityLabel
            ) {
                onWindowAction(.fullscreen)
            }
        }
        .padding(5)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

/// A compact macOS traffic-light style button shown on thumbnail hover.
private struct TrafficLightButton: View {
    let color: Color
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color)
                if isHovered {
                    Image(systemName: systemImage)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black.opacity(0.6))
                }
            }
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
