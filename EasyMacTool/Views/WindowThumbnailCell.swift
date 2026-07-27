import SwiftUI

/// A single live window preview cell. The cell's frame matches the window's
/// actual aspect ratio — no background padding or borders around the content.
/// The currently active window is marked with a subtle accent border.
///
/// Selection states (priority high→low):
/// 1. `isSelected` (keyboard Tab): strong accent border + fill — this is what
///    releasing the hotkey will activate.
/// 2. `isHover` (mouse aim): lighter accent border only — visual preview of
///    where a click would land. Does NOT override keyboard selection.
/// 3. neither: no border.
struct WindowThumbnailCell: View {
    @ObservedObject var item: WindowItem
    let isSelected: Bool
    let isHover: Bool
    let size: AppSettings.PreviewSize

    /// Compute the actual thumbnail dimensions from the window's aspect ratio,
    /// constrained by the configured preview size. For off-screen/placeholder
    /// apps (no usable frame), fall back to the full preview box so the icon
    /// card is a consistent size across all cells.
    private var thumbnailSize: CGSize {
        let maxWidth = size.thumbnailWidth
        let maxHeight = size.thumbnailHeight
        // Placeholder apps have frame .zero — use the full preview box.
        if item.isPlaceholder || item.frame == .zero {
            return CGSize(width: maxWidth, height: maxHeight)
        }
        let aspect = item.aspectRatio

        if aspect >= maxWidth / maxHeight {
            return CGSize(width: maxWidth, height: maxWidth / aspect)
        } else {
            return CGSize(width: maxHeight * aspect, height: maxHeight)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Title on top: all titles align at the top edge regardless of
            // the thumbnail's varying height (driven by per-window aspect
            // ratio). Previously the title sat below the thumbnail, causing
            // title rows to land at different vertical positions — "高低错落".
            HStack(spacing: 6) {
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .frame(width: thumbnailSize.width, alignment: .leading)

            thumbnail
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(item.isActiveWindow ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 2)
                )
        }
        .padding(10)
        .background(
            // 选中态（键盘 Tab）：accentColor 填充（macOS 原生高亮风格）。
            // 悬停态（鼠标预瞄）：极淡填充，比选中态浅很多，仅作视觉标记。
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25)
                      : (isHover ? Color.accentColor.opacity(0.08) : .clear))
        )
        .overlay(
            // 边框优先级：选中（强）> 悬停（浅）> 无。
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.9)
                    : (isHover ? Color.accentColor.opacity(0.45) : .clear),
                    lineWidth: isSelected ? 2 : 1.5
                )
        )
        // Disable animation so selection changes feel instant.
        .transaction { $0.animation = nil }
    }

    /// The thumbnail content, sized exactly to the window's aspect ratio.
    @ViewBuilder
    private var thumbnail: some View {
        if let image = item.latestImage {
            Image(decorative: image, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if item.isPlaceholder || item.isOffScreen {
            // Placeholder apps OR minimized/hidden windows: show a large app
            // icon on a subtle background. Capturing hidden windows via
            // ScreenCaptureKit fails or returns a black frame, so we never
            // attempt it — the icon is a clear, stable placeholder.
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(0.3))
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: thumbnailSize.width * 0.4,
                               height: thumbnailSize.height * 0.4)
                } else {
                    Image(systemName: "rectangle.slash")
                        .font(.system(size: min(thumbnailSize.width, thumbnailSize.height) * 0.3))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        } else {
            // 首次启动缓存为空时短暂显示淡色 app icon 占位。
            // 由于 WindowEnumerator 已从 WindowPreviewCache 预填充，此分支
            // 仅在缓存完全未命中时短暂可见——并行捕获完成后批量替换。
            // 不用 ProgressView 转圈，视觉上更接近系统原生切换器。
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(0.2))
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: thumbnailSize.width * 0.35,
                               height: thumbnailSize.height * 0.35)
                        .opacity(0.5)
                }
            }
            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        }
    }
}
