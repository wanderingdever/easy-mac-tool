import CoreGraphics
import Foundation

/// A window layout action the user can apply to the frontmost window.
/// Covers four halves, full screen, and the four corners.
enum WindowLayoutAction: String, Codable, CaseIterable, Identifiable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case fullScreen
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftHalf: return "左半屏"
        case .rightHalf: return "右半屏"
        case .topHalf: return "上半屏"
        case .bottomHalf: return "下半屏"
        case .fullScreen: return "全屏"
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        }
    }

    var systemImage: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .fullScreen: return "rectangle.fill"
        case .topLeft: return "square.topleft.arrow.triangle.swap"
        case .topRight: return "square.topright.arrow.triangle.swap"
        case .bottomLeft: return "arrowtriangle.down.left.square"
        case .bottomRight: return "arrowtriangle.down.right.square"
        }
    }

    /// The radial-menu sector this action maps to. `nil` means the center
    /// (full screen) slot.
    var radialSector: RadialSector? {
        switch self {
        case .topHalf: return .top
        case .topRight: return .topRight
        case .rightHalf: return .right
        case .bottomRight: return .bottomRight
        case .bottomHalf: return .bottom
        case .bottomLeft: return .bottomLeft
        case .leftHalf: return .left
        case .topLeft: return .topLeft
        case .fullScreen: return nil
        }
    }

    /// 默认无快捷键；用户可在设置中自行指定。
    static let defaultShortcuts: [LayoutShortcut] = []
}

/// The eight directional sectors of the radial menu, ordered clockwise.
/// `nil` primary action occupies the center slot (full screen).
enum RadialSector: Int, CaseIterable {
    case top, topRight, right, bottomRight, bottom, bottomLeft, left, topLeft

    /// The action this sector maps to.
    var action: WindowLayoutAction {
        switch self {
        case .top: return .topHalf
        case .topRight: return .topRight
        case .right: return .rightHalf
        case .bottomRight: return .bottomRight
        case .bottom: return .bottomHalf
        case .bottomLeft: return .bottomLeft
        case .left: return .leftHalf
        case .topLeft: return .topLeft
        }
    }

    /// Maps a mouse displacement angle (in degrees, 0 = pointing right,
    /// counter-clockwise positive) to the nearest of the 8 radial sectors.
    nonisolated static func sector(forAngleDegrees degrees: CGFloat) -> RadialSector {
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let step: CGFloat = 45
        let idx = Int((positive + step / 2) / step) % 8
        switch idx {
        case 0: return .right
        case 1: return .topRight
        case 2: return .top
        case 3: return .topLeft
        case 4: return .left
        case 5: return .bottomLeft
        case 6: return .bottom
        default: return .bottomRight
        }
    }
}

/// A user-configurable shortcut bound to a window layout action.
struct LayoutShortcut: Codable, Identifiable, Hashable {
    let action: WindowLayoutAction
    var keyCode: CGKeyCode
    var modifiersRaw: UInt64

    var id: String { action.rawValue }

    var modifiers: CGEventFlags {
        get { CGEventFlags(rawValue: modifiersRaw) }
        set { modifiersRaw = newValue.rawValue }
    }

    init(action: WindowLayoutAction,
         keyCode: CGKeyCode,
         modifiers: CGEventFlags) {
        self.action = action
        self.keyCode = keyCode
        self.modifiersRaw = modifiers.rawValue
    }

    var displayString: String {
        KeyComboFormatter.format(keyCode: keyCode, modifiers: modifiers)
    }
}
