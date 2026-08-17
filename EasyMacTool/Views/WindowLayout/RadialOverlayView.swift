import AppKit
import SwiftUI

/// The radial menu shown while a layout trigger is held. It appears centered on
/// the mouse position. A center circle with the app logo (full screen) is
/// surrounded by 8 sectors; the sector matching the current mouse direction is
/// highlighted. Purely visual (the panel is click-through).
struct RadialOverlayView: View {
    @ObservedObject var controller: RadialLayoutController

    var body: some View {
        GeometryReader { geo in
            // 面板以鼠标为中心，拨盘绘制在面板几何中心即鼠标位置。
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Color.clear
                RadialDial(center: center,
                           activeAction: controller.activeAction)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

/// Draws the compact radial dial: 8 directional wedges around a center circle
/// that shows the app logo.
private struct RadialDial: View {
    let center: CGPoint
    let activeAction: WindowLayoutAction?

    private let outerRadius: CGFloat = 56
    private let innerRadius: CGFloat = 20
    private let wedgeHalfSpan: Double = 22.5
    private static let appIcon = NSImage(named: "AppIcon")

    /// 拨盘直径（外圈直径）。
    private var dialDiameter: CGFloat { outerRadius * 2 }
    /// 拨盘几何中心（相对拨盘 frame 的原点，即 frame 的中点）。
    private var dialCenter: CGPoint { CGPoint(x: outerRadius, y: outerRadius) }

    var body: some View {
        ZStack {
            ForEach(RadialSector.allCases, id: \.self) { sector in
                wedge(for: sector)
            }
            centerCircle
        }
        .frame(width: dialDiameter, height: dialDiameter)
        .position(center)
    }

    private func wedge(for sector: RadialSector) -> some View {
        let action = sector.action
        let isActive = activeAction == action
        let centerAngle = Self.swiftUIAngle(for: sector)
        let c = dialCenter
        let path = wedgePath(center: c, centerAngle: centerAngle)
        return ZStack {
            path
            .fill(isActive ? AnyShapeStyle(DesignTokens.Aurora.brandGradient)
                           : AnyShapeStyle(Color.primary.opacity(0.10)))
            .overlay(
                path.stroke(DesignTokens.Aurora.cardBorder, lineWidth: 1)
            )
            .shadow(color: isActive ? DesignTokens.Aurora.brandGlow : .clear, radius: 8)
            .animation(DesignTokens.Aurora.standard, value: isActive)
        }
    }

    private func wedgePath(center: CGPoint, centerAngle: Double) -> Path {
        Path { path in
            path.addArc(center: center,
                        radius: outerRadius,
                        startAngle: .degrees(centerAngle - wedgeHalfSpan),
                        endAngle: .degrees(centerAngle + wedgeHalfSpan),
                        clockwise: false)
            path.addLine(to: CGPoint(
                x: center.x + innerRadius * cos(radians(centerAngle + wedgeHalfSpan)),
                y: center.y + innerRadius * sin(radians(centerAngle + wedgeHalfSpan))
            ))
            path.addArc(center: center,
                        radius: innerRadius,
                        startAngle: .degrees(centerAngle + wedgeHalfSpan),
                        endAngle: .degrees(centerAngle - wedgeHalfSpan),
                        clockwise: true)
            path.closeSubpath()
        }
    }

    private var centerCircle: some View {
        let isActive = activeAction == .fullScreen
        return ZStack {
            Circle()
                .fill(isActive ? AnyShapeStyle(DesignTokens.Aurora.brandGradient)
                               : AnyShapeStyle(Color.primary.opacity(0.12)))
                .overlay(
                    Circle().strokeBorder(DesignTokens.Aurora.cardBorder, lineWidth: 1)
                )
                .frame(width: innerRadius * 2, height: innerRadius * 2)
                .shadow(color: isActive ? DesignTokens.Aurora.brandGlow : .clear, radius: 8)
                .animation(DesignTokens.Aurora.standard, value: isActive)
            if let logo = Self.appIcon {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: innerRadius * 1.4, height: innerRadius * 1.4)
                    .clipShape(Circle())
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? .white : Color.primary.opacity(0.6))
            }
        }
    }

    /// Visual (y-down) center angle in degrees for each sector.
    private static func swiftUIAngle(for sector: RadialSector) -> Double {
        switch sector {
        case .top: return -90
        case .topRight: return -45
        case .right: return 0
        case .bottomRight: return 45
        case .bottom: return 90
        case .bottomLeft: return 135
        case .left: return 180
        case .topLeft: return -135
        }
    }

    private func radians(_ degrees: Double) -> CGFloat {
        CGFloat(degrees * .pi / 180)
    }
}
