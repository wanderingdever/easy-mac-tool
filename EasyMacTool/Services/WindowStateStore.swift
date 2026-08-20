import AppKit
import Combine

/// Owns the switcher's live window list. The store loads the initial snapshot,
/// then reacts to public window/Space notifications with a debounced refresh.
/// It is deliberately small for now; reducer-based window mutation can be added
/// behind the same boundary later.
@MainActor
final class WindowStateStore: ObservableObject {
    @Published private(set) var items: [WindowItem] = []

    private let enumerator = WindowEnumerator()
    private let eventSource = WindowEventSource()
    private var activeFilter: ShortcutConfig?
    private var activeScreenFrame: CGRect?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private var onRefresh: (@MainActor () -> Void)?
    private var onEmpty: (@MainActor () -> Void)?
    private let debounceNanoseconds: UInt64 = 250_000_000

    func load(
        filter: ShortcutConfig,
        preferredScreenFrame: CGRect? = nil
    ) async -> [WindowItem] {
        let currentGeneration = generation
        let items = await enumerator.snapshot(
            filter: filter,
            preferredScreenFrame: preferredScreenFrame
        )
        guard currentGeneration == generation else { return [] }
        self.items = items
        return items
    }

    func startLiveUpdates(
        filter: ShortcutConfig,
        preferredScreenFrame: CGRect? = nil,
        onRefresh: @escaping @MainActor () -> Void,
        onEmpty: @escaping @MainActor () -> Void
    ) {
        activeFilter = filter
        activeScreenFrame = preferredScreenFrame
        self.onRefresh = onRefresh
        self.onEmpty = onEmpty
        eventSource.start { [weak self] in
            self?.scheduleRefresh()
        }
    }

    func stopLiveUpdates() {
        generation = UUID()
        activeFilter = nil
        activeScreenFrame = nil
        onRefresh = nil
        onEmpty = nil
        refreshTask?.cancel()
        refreshTask = nil
        eventSource.stop()
    }

    private func scheduleRefresh() {
        guard let filter = activeFilter else { return }
        refreshTask?.cancel()
        let currentGeneration = generation
        let delay = debounceNanoseconds
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  let self,
                  self.activeFilter?.id == filter.id else { return }

            let items = await self.enumerator.snapshot(
                filter: filter,
                preferredScreenFrame: self.activeScreenFrame,
                refreshFrontmost: false
            )
            guard !Task.isCancelled,
                  self.generation == currentGeneration,
                  self.activeFilter?.id == filter.id else { return }

            self.items = items
            if items.isEmpty {
                self.onEmpty?()
            } else {
                self.onRefresh?()
            }
        }
    }
}
