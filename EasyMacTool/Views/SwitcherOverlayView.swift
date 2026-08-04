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
/// Layout: header (indicator + title + count) → wrapping thumbnail grid →
/// footer (keyboard hint bar). The panel grows vertically to fit all rows
/// (see OverlayPanelController.positionPanel).
struct SwitcherOverlayView: View {
    @ObservedObject var controller: OverlayPanelController
    /// Called on mouse hover to set the visual aim index (lighter border).
    var onHoverChange: (Int?) -> Void
    /// Called on click to select + activate the clicked window.
    var onActivate: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            FlowLayout(spacing: DesignTokens.Spacing.md) {
                ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                    WindowThumbnailCell(
                        item: item,
                        isSelected: index == controller.selectedIndex,
                        isHover: index == controller.hoverIndex,
                        size: controller.previewSize
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        // Hover only sets the visual aim — does NOT change
                        // selectedIndex or trigger the live stream. Click is
                        // required to commit the selection.
                        onHoverChange(hovering ? index : nil)
                    }
                    .onTapGesture {
                        // Click promotes hover→selection AND activates the window.
                        onActivate(index)
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // macOS 原生 HUD/Spotlight 风格毛玻璃：ultraThinMaterial 最通透，
            // 可加一层极淡白色让整体有玻璃质感。背景撑满 hosting.view，
            // 四角圆角由 hosting.view.layer cornerRadius=24 裁剪，完全一致。
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                        .fill(.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
        )
        // 外阴影由 NSPanel.hasShadow 提供——SwiftUI .shadow 会被
        // masksToBounds 裁掉，所以不在这里加。
        // Disable ALL animations — switcher appears instantly and selection
        // changes don't trigger layout transitions that cause flicker.
        .transaction { $0.animation = nil }
        .animation(nil, value: controller.items.count)
        .animation(nil, value: controller.selectedIndex)
        .animation(nil, value: controller.hoverIndex)
    }

}
