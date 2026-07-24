import SwiftUI

/// The visual switcher strip: a wrapping flow of live window thumbnails.
/// Implements Windows Alt+Tab interaction:
/// - Mouse hover over a cell moves the selection to that cell.
/// - Single click activates the window immediately.
/// No entrance animation — loads instantly like Windows.
///
/// Layout: thumbnails wrap to the next row when the current row is full.
/// There is NEVER a scroll bar — the panel grows vertically to fit all rows
/// (see OverlayPanelController.positionPanel). This works for any preview
/// size and any window count.
struct SwitcherOverlayView: View {
    @ObservedObject var controller: OverlayPanelController
    var onSelect: (Int) -> Void
    var onActivate: (Int) -> Void

    var body: some View {
        FlowLayout(spacing: 12) {
            ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                WindowThumbnailCell(
                    item: item,
                    isSelected: index == controller.selectedIndex,
                    size: controller.previewSize
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        onSelect(index)
                    }
                }
                .onTapGesture {
                    onSelect(index)
                    onActivate(index)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // macOS 原生 HUD/Spotlight 风格毛玻璃：ultraThinMaterial 最通透，
            // 叠加一层极淡白色让整体有玻璃质感。背景撑满 hosting.view，
            // 四角圆角由 hosting.view.layer cornerRadius=24 裁剪，完全一致。
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
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
    }
}
