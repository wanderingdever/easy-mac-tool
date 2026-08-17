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
        if item.frame == .zero {
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
            HStack(spacing: DesignTokens.Spacing.sm) {
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Text(item.title)
                    .scaledSystemFont(13, weight: .medium)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .frame(width: thumbnailSize.width, alignment: .leading)

            thumbnail
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    // 当前活跃窗口标记：品牌渐变描边（Aurora v2），
                    // 与选中态的单色层级区分。
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(item.isActiveWindow
                                      ? AnyShapeStyle(DesignTokens.Aurora.brandGradient.opacity(0.65))
                                      : AnyShapeStyle(.clear),
                                      lineWidth: 2)
                )
        }
        // Padding compensation: selected state uses 2pt border vs default 1pt,
        // so reduce padding by 1pt to keep the cell's total size constant
        // (design spec: .is-selected padding 10→9). This prevents layout shift.
        .padding(isSelected ? 9 : 10)
        .background(
            // Aurora v2：选中态（键盘 Tab）= 品牌渐变淡填充；
            // 悬停态（鼠标预瞄）= 更浅的渐变填充，仅作视觉标记。
            RoundedRectangle(cornerRadius: DesignTokens.Radius.cell, style: .continuous)
                .fill(isSelected
                      ? AnyShapeStyle(DesignTokens.Aurora.brandGradient.opacity(0.18))
                      : (isHover
                         ? AnyShapeStyle(DesignTokens.Aurora.brandGradient.opacity(0.07))
                         : AnyShapeStyle(.clear)))
        )
        .overlay(
            // 边框优先级：选中（品牌渐变 2pt，强）> 悬停（渐变 55% 1.5pt，浅）> 无。
            RoundedRectangle(cornerRadius: DesignTokens.Radius.cell, style: .continuous)
                .strokeBorder(
                    isSelected
                    ? AnyShapeStyle(DesignTokens.Aurora.brandGradient)
                    : (isHover
                       ? AnyShapeStyle(DesignTokens.Aurora.brandGradient.opacity(0.55))
                       : AnyShapeStyle(.clear)),
                    lineWidth: isSelected ? 2 : 1.5
                )
        )
        // 选中态品牌色外发光，让释放快捷键将激活的目标一目了然。
        .shadow(color: isSelected ? DesignTokens.Aurora.brandGlow : .clear,
                radius: isSelected ? 10 : 0, y: isSelected ? 2 : 0)
        .overlay(
            // Default (non-selected, non-hover) subtle border: foreground 7%.
            RoundedRectangle(cornerRadius: DesignTokens.Radius.cell, style: .continuous)
                .strokeBorder(
                    (!isSelected && !isHover) ? Color.primary.opacity(0.07) : .clear,
                    lineWidth: 1
                )
        )
        // Disable animation so selection changes feel instant.
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var accessibilityValue: String {
        var values: [String] = []
        switch item.windowState {
        case .visible: values.append("可见窗口")
        case .minimized: values.append("已最小化")
        case .hidden: values.append("已隐藏")
        }
        if item.isActiveWindow { values.append("当前窗口") }
        if isSelected { values.append("已选择") }
        return values.joined(separator: "，")
    }

    /// The thumbnail content, sized exactly to the window's aspect ratio.
    ///
    /// 呈现策略：
    /// - visible 窗口有捕获图：显示实时/缓存预览（无角标）
    /// - minimized/hidden/placeholder：统一显示 app icon + 状态角标
    ///   ScreenCaptureKit 无法实时捕获离屏窗口，缓存预览可能过时误导用户，
    ///   因此离屏窗口一律显示 app icon（与 placeholder 一致）。
    ///   用户通过窗口标题和状态角标区分各离屏窗口。
    @ViewBuilder
    private var thumbnail: some View {
        if !item.isOffScreen, let image = item.latestImage {
            // visible 窗口有捕获图：显示实时/缓存预览
            Image(decorative: image, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if item.isOffScreen {
            // placeholder / minimized / hidden：统一 app icon 占位 + 状态角标
            // Capturing hidden/minimized windows via ScreenCaptureKit fails or
            // returns a black frame, so we never attempt it — the icon is a
            // clear, stable placeholder. 不显示缓存预览，避免过时画面误导用户。
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
            .overlay(alignment: .bottomTrailing) {
                stateBadge
            }
        } else {
            // visible 窗口首次启动缓存为空时短暂显示淡色 app icon 占位。
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

    /// 状态角标：minimized/hidden 窗口显示对应 SF Symbol，让用户一眼区分窗口状态。
    /// visible 窗口和 placeholder 不显示角标。
    /// 设计稿：22×22 圆形徽标，位于缩略图右下角 (right:8, bottom:8)，内部图标 13×13。
    @ViewBuilder
    private var stateBadge: some View {
        switch item.windowState {
        case .visible:
            EmptyView()
        case .minimized:
            stateBadgeContent(systemName: "minus.rectangle.fill")
        case .hidden:
            stateBadgeContent(systemName: "eye.slash.fill")
        }
    }

    /// 共用的徽标视图：13pt 图标 + 4.5pt padding → 22pt 圆形，背景半透明材质 + 细边框。
    @ViewBuilder
    private func stateBadgeContent(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.regularMaterial))
            .overlay(
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .padding(8)
    }
}
