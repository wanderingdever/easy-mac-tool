import AppKit
import Combine
import ScreenCaptureKit

/// 窗口生命周期状态，对应 macOS 窗口的 5 个生命周期阶段中的前 3 个
/// （closed/released 的窗口不创建 item，不需要枚举值）：
/// - visible: 可见窗口，当前存在于屏幕上
/// - minimized: 窗口最小化到 Dock（AX AXMinimized == true）
/// - hidden: app 被 Cmd+H 隐藏（app.isHidden == true）
enum WindowState {
    case visible
    case minimized
    case hidden
}

/// Represents a single window surfaced in the switcher.
@MainActor
final class WindowItem: ObservableObject, Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let bundleIdentifier: String?
    let appIcon: NSImage?
    let title: String
    let frame: CGRect             // for AX matching
    let scWindow: SCWindow?
    /// 窗口生命周期状态。
    let windowState: WindowState
    /// True when this is the currently active (frontmost) window.
    let isActiveWindow: Bool
    /// id 是否为系统分配的真实 windowID。false 表示 id 是哈希降级值
    ///（0xF0000000 高位标记），WindowActivator 对此类 item 必须跳过
    /// AXWindowID 精确匹配，直接走 frame 兜底匹配，防止误操作其他窗口。
    let hasRealWindowID: Bool
    @Published var latestImage: CGImage?

    /// True when the underlying window is minimized or hidden (no live stream).
    /// 计算属性：基于 windowState 推导，保持外部接口不变。
    var isOffScreen: Bool { windowState != .visible }

    init(id: CGWindowID,
         pid: pid_t,
         appName: String,
         bundleIdentifier: String? = nil,
         appIcon: NSImage?,
         title: String,
         frame: CGRect,
         scWindow: SCWindow?,
         windowState: WindowState = .visible,
         isActiveWindow: Bool = false,
         initialImage: CGImage? = nil,
         hasRealWindowID: Bool = true) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.appIcon = appIcon
        self.title = title
        self.frame = frame
        self.scWindow = scWindow
        self.windowState = windowState
        self.isActiveWindow = isActiveWindow
        self.hasRealWindowID = hasRealWindowID
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
