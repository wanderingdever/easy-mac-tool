import AppKit

/// Public-API event source for live switcher refreshes. It does not replace a
/// full WindowServer state model, but it gives the open switcher a debounced
/// re-snapshot trigger on the system changes users actually see.
@MainActor
final class WindowEventSource {
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var onChange: (@MainActor () -> Void)?
    private var isActive = false
    private let debounceNanoseconds: UInt64 = 250_000_000

    var isRunning: Bool { isActive }

    func start(onChange: @escaping @MainActor () -> Void) {
        stop()
        self.onChange = onChange
        isActive = true

        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh()
                }
            }
            observers.append(observer)
        }
    }

    func stop() {
        isActive = false
        onChange = nil
        refreshTask?.cancel()
        refreshTask = nil

        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    private func scheduleRefresh() {
        guard isActive else { return }
        refreshTask?.cancel()
        let delay = debounceNanoseconds
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.onChange?()
        }
    }
}
