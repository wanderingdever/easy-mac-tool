import Foundation

/// Actions exposed by the switcher's hover window-control buttons.
enum WindowControlAction: String, CaseIterable, Identifiable {
    case close
    case minimize
    case fullscreen

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .close: return "xmark"
        case .minimize: return "minus"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .close: return "关闭窗口"
        case .minimize: return "最小化窗口"
        case .fullscreen: return "切换全屏"
        }
    }
}
