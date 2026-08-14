import AppKit
import Combine
import SwiftUI

/// Drives the Loop-style radial window-layout interaction. The menu can be
/// summoned by either:
///   - holding the configured mouse button (default: middle button), or
///   - holding a configured modifier-hold shortcut (e.g. right Command).
/// While held, moving the mouse picks a sector (or the center for full screen);
/// releasing applies the layout.
///
/// Uses **global** event monitors so it works while the app is in the
/// background (this is a menu bar app). The monitors stay installed while the
/// feature is enabled but only react once a trigger is held.
@MainActor
final class RadialLayoutController: ObservableObject {
    static let shared = RadialLayoutController()

    /// Whether the radial overlay is currently on screen.
    @Published private(set) var isActive = false
    /// The currently highlighted layout action (nil = nothing selected).
    @Published private(set) var activeAction: WindowLayoutAction? = nil

    /// 呼出径向菜单的固定鼠标按键（中键）。
    private let triggerButton = 2
    /// 径向菜单面板尺寸：外环 56 半径拨盘 + 阴影留白。
    private let panelSize = CGSize(width: 150, height: 150)
    private var keyTrigger: RadialKeyTrigger = .none
    private var monitors: [Any] = []
    private var armed = false
    /// 仅供全局监视器线程裸读的门控标志：armed 时（主线程写）为 true。
    /// 监视器闭包先读此标志，未 armed 时直接 return，避免系统每个鼠标
    /// 事件都产生一次主线程 hop（Bool 单字节写天然原子，误读窗口可忽略）。
    private nonisolated(unsafe) var armedFlag = false
    /// Whether the mouse left the center region during this session; a plain
    /// press without movement must not apply any layout.
    private var didMove = false
    private var globalCenter: CGPoint = .zero
    /// 呼出时鼠标所在屏幕；径向布局作用到此屏幕（与菜单同屏）。
    private var activeScreen: NSScreen?
    private var panelFrame: CGRect = .zero
    private var panel: NSPanel?
    private var hostingView: NSHostingView<RadialOverlayView>?

    private init() {}

    /// Installs the global monitors. Called when the feature is enabled.
    func start(keyTrigger: RadialKeyTrigger) {
        stop()
        self.keyTrigger = keyTrigger
        installMonitors()
    }

    /// Removes the monitors and any active session.
    func stop() {
        tearDown()
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
    }

    /// Called by AppCoordinator before a discrete layout shortcut fires, so a
    /// held radial session doesn't also apply a stale sector on release.
    func clearActiveAction() {
        activeAction = nil
    }

    // MARK: - Monitor installation

    private func installMonitors() {
        let trigger = triggerButton
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let button = event.buttonNumber
            // 未 armed 且非触发键时不跳主线程（避免全局每个鼠标点击都产生 main hop）。
            guard let self, button == trigger || self.armedFlag else { return }
            Task { @MainActor [weak self] in
                self?.handleMouseButtonDown(button)
            }
        }
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] event in
            let button = event.buttonNumber
            // 释放处理仅在 armed 且为触发键时才有意义。
            guard let self, self.armedFlag, button == trigger else { return }
            Task { @MainActor [weak self] in
                self?.handleMouseButtonUp(button)
            }
        }
        let moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
            // 移动事件最高频：未 armed 时直接 return，不做主线程 hop。
            guard let self, self.armedFlag else { return }
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleMouseMove(to: location)
            }
        }
        let flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = UInt64(event.modifierFlags.rawValue) & ModifierBits.deviceMask
            Task { @MainActor [weak self] in
                self?.handleModifiersHeld(held)
            }
        }
        if let downMonitor { monitors.append(downMonitor) }
        if let upMonitor { monitors.append(upMonitor) }
        if let moveMonitor { monitors.append(moveMonitor) }
        if let flagsMonitor { monitors.append(flagsMonitor) }
    }

    // MARK: - Event handling

    private func handleMouseButtonDown(_ button: Int) {
        guard !armed, button == triggerButton else { return }
        arm()
    }

    private func handleMouseButtonUp(_ button: Int) {
        guard armed, button == triggerButton else { return }
        commit()
    }

    /// Modifier-hold trigger: arm when the exact configured modifier set is
    /// held, commit when it is no longer held.
    private func handleModifiersHeld(_ held: UInt64) {
        let target = keyTrigger.modifiersRaw
        guard target != 0 else { return }
        if held == target {
            if !armed { arm() }
        } else if armed {
            commit()
        }
    }

    private func handleMouseMove(to location: CGPoint) {
        guard armed, isActive else { return }
        let dx = location.x - globalCenter.x
        let dy = location.y - globalCenter.y
        let distance = hypot(dx, dy)
        let innerRadius: CGFloat = 20
        if distance < innerRadius {
            activeAction = .fullScreen
        } else {
            didMove = true
            let degrees = atan2(dy, dx) * 180 / .pi
            activeAction = RadialSector.sector(forAngleDegrees: degrees).action
        }
    }

    /// Opens the radial menu in a small panel centered on the current mouse
    /// position, clamped to screen bounds.
    private func arm() {
        armed = true
        armedFlag = true
        didMove = false
        activeAction = .fullScreen
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) })
            ?? nearestScreen(to: location)
            ?? NSScreen.main else {
            armed = false
            armedFlag = false
            return
        }
        globalCenter = location
        activeScreen = screen
        // 以鼠标为几何中心，夹紧在屏幕内
        let half = CGPoint(x: panelSize.width / 2, y: panelSize.height / 2)
        var origin = CGPoint(x: location.x - half.x, y: location.y - half.y)
        origin.x = min(max(origin.x, screen.frame.minX), screen.frame.maxX - panelSize.width)
        origin.y = min(max(origin.y, screen.frame.minY), screen.frame.maxY - panelSize.height)
        panelFrame = CGRect(origin: origin, size: panelSize)
        setupPanel()
        present()
    }

    private func commit() {
        guard isActive else {
            armed = false
            armedFlag = false
            return
        }
        let action = didMove ? activeAction : nil
        tearDown()
        if let action, let screen = activeScreen {
            _ = WindowLayoutManager.shared.apply(action, screen: screen)
        }
    }

    /// 鼠标在屏幕缝隙（dead zone，两屏交界处）时，按距离选最近的屏，
    /// 避免误落到主屏（与切换器/剪贴板的多屏兜底策略一致）。
    private func nearestScreen(to point: CGPoint) -> NSScreen? {
        guard !NSScreen.screens.isEmpty else { return nil }
        var best: (screen: NSScreen, distance: CGFloat)?
        for screen in NSScreen.screens {
            let rect = screen.frame
            // 鼠点到 rect 最近点的距离（在 rect 内则距离为 0）
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = sqrt(dx * dx + dy * dy)
            if best == nil || distance < best!.distance {
                best = (screen, distance)
            }
        }
        return best?.screen
    }

    // MARK: - Panel lifecycle

    private func setupPanel() {
        if panel == nil {
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.hidesOnDeactivate = false
            p.worksWhenModal = true
            p.isReleasedWhenClosed = false
            p.ignoresMouseEvents = true
            panel = p
        }
        panel?.setFrame(panelFrame, display: false)
    }

    private func present() {
        guard let panel else { return }
        if hostingView == nil {
            let hosting = NSHostingView(rootView: RadialOverlayView(controller: self))
            hosting.wantsLayer = true
            hosting.layer?.isOpaque = false
            hosting.layer?.backgroundColor = nil
            hosting.autoresizingMask = [.width, .height]  // 跟随面板尺寸变化
            hostingView = hosting
            panel.contentView = hosting
        }
        // 确保面板始终是我们期望的小面板 frame（夹紧在屏幕内、以鼠标为中心）。
        panel.setFrame(panelFrame, display: true)
        panel.orderFrontRegardless()
        isActive = true
    }

    private func tearDown() {
        armed = false
        armedFlag = false
        isActive = false
        activeAction = nil
        panel?.orderOut(nil)
    }
}