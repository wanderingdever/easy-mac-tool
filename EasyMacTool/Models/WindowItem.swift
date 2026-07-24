import AppKit
import Combine
import ScreenCaptureKit

/// Represents a single window (or app placeholder) surfaced in the switcher.
@MainActor
final class WindowItem: ObservableObject, Identifiable {
    let id: CGWindowID            // SCWindow.windowID, or 0 for placeholder apps
    let pid: pid_t
    let appName: String
    let appIcon: NSImage?
    let title: String
    let frame: CGRect             // for AX matching
    let scWindow: SCWindow?       // nil for placeholder apps with no windows
    /// True when this item represents an app with no open windows (icon-only cell).
    let isPlaceholder: Bool
    /// True when the underlying window is minimized or hidden (no live stream).
    let isOffScreen: Bool
    /// True when this is the currently active (frontmost) window.
    let isActiveWindow: Bool
    @Published var latestImage: CGImage?

    init(id: CGWindowID,
         pid: pid_t,
         appName: String,
         appIcon: NSImage?,
         title: String,
         frame: CGRect,
         scWindow: SCWindow?,
         isPlaceholder: Bool = false,
         isOffScreen: Bool = false,
         isActiveWindow: Bool = false,
         initialImage: CGImage? = nil) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.appIcon = appIcon
        self.title = title
        self.frame = frame
        self.scWindow = scWindow
        self.isPlaceholder = isPlaceholder
        self.isOffScreen = isOffScreen
        self.isActiveWindow = isActiveWindow
        // 从 WindowPreviewCache 预填充：面板 present 时立即有图，避免
        // 显示 ProgressView 转圈。nil 表示缓存未命中（首次启动）。
        self.latestImage = initialImage
    }

    /// The window's aspect ratio (width / height). Used to size the thumbnail
    /// so it matches the real window shape — no extra borders or cropping.
    var aspectRatio: CGFloat {
        guard frame.height > 0 else { return 1.6 }
        return frame.width / frame.height
    }
}
