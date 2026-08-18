import AppKit
import Combine
import Darwin

/// Finds the files an app leaves around — caches, preferences, logs, support
/// folders, containers — and moves the ones the user picks to the Trash, then
/// reports the space recovered. Everything goes to the Trash (reversible), never
/// an unrecoverable delete.
final class AppUninstaller: ObservableObject {
    static let shared = AppUninstaller()

    enum Phase: Equatable {
        case empty
        case scanning
        case results
        case stopping
        case awaitingForceQuit
        case removing
        case awaitingFinderAuthorization(freed: Int64, pending: Int)
        case done(freed: Int64, failed: Int)
    }

    struct Target: Equatable {
        let name: String
        let bundleID: String?
        let url: URL
        let icon: NSImage

        static func == (lhs: Target, rhs: Target) -> Bool { lhs.url == rhs.url }
    }

    nonisolated enum Category: Int, CaseIterable, Sendable {
        case app, support, caches, preferences, containers, logs, state, other

        var sortRank: Int { rawValue }
    }

    nonisolated struct Leftover: Identifiable, Equatable, Sendable {
        let id = UUID()
        let url: URL
        let category: Category
        let size: Int64
        let identity: UninstallerSupport.FileIdentity
        var include: Bool = true

        var name: String { url.lastPathComponent }

        static func == (lhs: Leftover, rhs: Leftover) -> Bool {
            lhs.id == rhs.id && lhs.include == rhs.include
        }
    }

    nonisolated struct RemovalFailure: Identifiable, Sendable {
        let id = UUID()
        let url: URL
        let reason: String
    }

    nonisolated struct RunningComponent: Identifiable, Equatable, Sendable {
        let pid: pid_t
        let name: String
        let identity: UninstallerRuntimeSupport.ProcessIdentity
        let allowsExternalPath: Bool

        var id: pid_t { pid }
    }

    nonisolated private struct ScanResult: Sendable {
        let items: [Leftover]
        let bundleIDs: Set<String>
        let launchItems: [UninstallerRuntimeSupport.LaunchItem]
    }

    nonisolated private struct RemovalPlan: Sendable {
        let items: [Leftover]
        let allowedPaths: Set<String>
        let targetURL: URL
    }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var target: Target?
    @Published var items: [Leftover] = []
    @Published private(set) var removalFailures: [RemovalFailure] = []
    @Published private(set) var runningComponents: [RunningComponent] = []
    @Published private(set) var requiresRestart = false
    private var allowedRemovalPaths = Set<String>()
    private var relatedBundleIDs = Set<String>()
    private var relatedLaunchItems: [UninstallerRuntimeSupport.LaunchItem] = []
    private var stoppedLaunchItems: [UninstallerRuntimeSupport.LaunchItem] = []
    private var pendingRemovalPlan: RemovalPlan?
    private var pendingFinderItems: [Leftover] = []
    private var accumulatedFreed: Int64 = 0
    private var accumulatedFailures: [RemovalFailure] = []

    private init() {}

    var selectedSize: Int64 { items.filter(\.include).reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    // MARK: - Selection & scan

    func select(appURL: URL) {
        guard let bundle = Bundle(url: appURL) else { return }
        guard !InstalledApps.isSystemApplication(at: appURL) else { return }
        guard let bundleID = UninstallerSupport.verifiedBundleID(bundle.bundleIdentifier) else { return }
        let selectedURL = appURL.standardizedFileURL
        guard selectedURL == selectedURL.resolvingSymlinksInPath() else { return }
        guard selectedURL != Bundle.main.bundleURL.standardizedFileURL else { return }
        guard !Self.isSymbolicLink(appURL) else { return }
        var name = FileManager.default.displayName(atPath: appURL.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)

        target = Target(name: name, bundleID: bundleID, url: selectedURL, icon: icon)
        items = []
        removalFailures = []
        runningComponents = []
        allowedRemovalPaths = []
        relatedBundleIDs = []
        relatedLaunchItems = []
        stoppedLaunchItems = []
        pendingRemovalPlan = nil
        pendingFinderItems = []
        accumulatedFreed = 0
        accumulatedFailures = []
        requiresRestart = false
        phase = .scanning

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Self.collect(bundleID: bundleID, appURL: selectedURL)
            DispatchQueue.main.async {
                guard let self, self.phase == .scanning, self.target?.url == selectedURL else { return }
                self.items = found.items
                self.relatedBundleIDs = found.bundleIDs
                self.relatedLaunchItems = found.launchItems
                self.requiresRestart = found.launchItems.contains { $0.kind == .systemDaemon }
                self.allowedRemovalPaths = Set(found.items.map { $0.url.standardizedFileURL.path })
                self.phase = .results
            }
        }
    }

    func setInclude(_ include: Bool, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].include = include
    }

    func reset() {
        target = nil
        items = []
        removalFailures = []
        runningComponents = []
        allowedRemovalPaths = []
        relatedBundleIDs = []
        relatedLaunchItems = []
        stoppedLaunchItems = []
        pendingRemovalPlan = nil
        pendingFinderItems = []
        accumulatedFreed = 0
        accumulatedFailures = []
        requiresRestart = false
        phase = .empty
    }

    // MARK: - Removal

    func removeSelected() {
        let chosen = items.filter(\.include)
        guard !chosen.isEmpty, let targetURL = target?.url else { return }
        phase = .stopping

        let initiallySafe = chosen.filter {
            Self.removalIsStillSafe($0,
                                    allowedPaths: allowedRemovalPaths,
                                    targetURL: targetURL)
        }
        let initiallySafeIDs = Set(initiallySafe.map(\.id))
        let initialFailures = chosen.filter { candidate in
            !initiallySafeIDs.contains(candidate.id)
        }.map {
            RemovalFailure(url: $0.url, reason: "文件身份或路径在确认后发生变化")
        }

        guard !initiallySafe.isEmpty else {
            removalFailures = initialFailures
            phase = .done(freed: 0, failed: initialFailures.count)
            return
        }

        let plan = RemovalPlan(items: initiallySafe,
                               allowedPaths: allowedRemovalPaths,
                               targetURL: targetURL)
        pendingRemovalPlan = plan
        accumulatedFreed = 0
        accumulatedFailures = initialFailures
        pendingFinderItems = []
        removalFailures = []
        Task { @MainActor [weak self] in
            await self?.prepareForRemoval(plan)
        }
    }

    func confirmForceQuit() {
        guard phase == .awaitingForceQuit, let plan = pendingRemovalPlan else { return }
        phase = .stopping
        let components = runningComponents
        Task { @MainActor [weak self] in
            guard let self else { return }
            Self.forceTerminate(components, appURL: plan.targetURL)
            let remaining = await Self.waitForExit(components,
                                                   appURL: plan.targetURL,
                                                   timeout: 2)
            guard self.phase == .stopping else { return }
            if remaining.isEmpty {
                self.runningComponents = []
                self.performRemoval(plan)
            } else {
                self.runningComponents = remaining
                self.accumulatedFailures.append(contentsOf: remaining.map {
                    RemovalFailure(
                        url: URL(fileURLWithPath: $0.identity.executablePath),
                        reason: "强制退出后进程仍在运行，已停止卸载"
                    )
                })
                await self.restoreStoppedLaunchItemsIfNeeded(appStillExists: true)
                self.finishRemoval(targetURL: plan.targetURL)
            }
        }
    }

    func cancelForceQuit() {
        guard phase == .awaitingForceQuit, let plan = pendingRemovalPlan else { return }
        phase = .stopping
        accumulatedFailures.append(contentsOf: runningComponents.map {
            RemovalFailure(
                url: URL(fileURLWithPath: $0.identity.executablePath),
                reason: "应用仍在运行，用户取消了强制退出"
            )
        })
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreStoppedLaunchItemsIfNeeded(appStillExists: true)
            self.finishRemoval(targetURL: plan.targetURL)
        }
    }

    func retryFinderRemoval() {
        guard case .awaitingFinderAuthorization = phase,
              let plan = pendingRemovalPlan,
              !pendingFinderItems.isEmpty else { return }
        phase = .removing
        Task { @MainActor [weak self] in
            await self?.performFinderRemoval(plan: plan, candidates: self?.pendingFinderItems ?? [])
        }
    }

    func finishWithoutFinderRetry() {
        guard case .awaitingFinderAuthorization = phase,
              let plan = pendingRemovalPlan else { return }
        accumulatedFailures.append(contentsOf: pendingFinderItems.map {
            RemovalFailure(url: $0.url, reason: "未授予 Finder 自动化权限，项目未移除")
        })
        pendingFinderItems = []
        Task { @MainActor [weak self] in
            guard let self else { return }
            let appStillExists = FileManager.default.fileExists(atPath: plan.targetURL.path)
            await self.restoreStoppedLaunchItemsIfNeeded(appStillExists: appStillExists)
            self.finishRemoval(targetURL: plan.targetURL)
        }
    }

    private func prepareForRemoval(_ plan: RemovalPlan) async {
        guard phase == .stopping else { return }
        let launchItems = relatedLaunchItems
        let uid = getuid()
        let stopResults = await Task.detached(priority: .userInitiated) {
            launchItems.compactMap { item -> (
                UninstallerRuntimeSupport.LaunchItem,
                UninstallerRuntimeSupport.BootoutDisposition,
                String
            )? in
                guard let arguments = UninstallerRuntimeSupport.bootoutArguments(for: item, uid: uid),
                      UninstallerSupport.fileIdentity(at: item.url) == item.identity else {
                    return nil
                }
                let result = UninstallerRuntimeSupport.runLaunchctl(arguments: arguments)
                return (item,
                        UninstallerRuntimeSupport.bootoutDisposition(result),
                        result.errorText)
            }
        }.value
        guard phase == .stopping else { return }
        stoppedLaunchItems = stopResults.filter { $0.1 == .stopped }.map(\.0)
        accumulatedFailures.append(contentsOf: stopResults.filter { $0.1 == .failed }.map {
            RemovalFailure(url: $0.0.url,
                           reason: "无法停止启动项：\($0.2.isEmpty ? "launchctl 返回错误" : $0.2)")
        })

        let components = Self.runningComponents(
            appURL: plan.targetURL,
            relatedBundleIDs: relatedBundleIDs
        )
        Self.requestGracefulTermination(components, appURL: plan.targetURL)
        let remaining = await Self.waitForExit(components,
                                               appURL: plan.targetURL,
                                               timeout: 3)
        guard phase == .stopping else { return }
        if remaining.isEmpty {
            runningComponents = []
            performRemoval(plan)
        } else {
            runningComponents = remaining
            phase = .awaitingForceQuit
        }
    }

    private func performRemoval(_ plan: RemovalPlan) {
        phase = .removing
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Self.moveDirectlyToTrash(plan: plan)
            }.value
            guard self.phase == .removing else { return }
            self.accumulatedFreed += result.freed
            self.accumulatedFailures.append(contentsOf: result.failures)
            if result.finderCandidates.isEmpty {
                let appStillExists = FileManager.default.fileExists(atPath: plan.targetURL.path)
                await self.restoreStoppedLaunchItemsIfNeeded(appStillExists: appStillExists)
                self.finishRemoval(targetURL: plan.targetURL)
            } else {
                await self.performFinderRemoval(plan: plan, candidates: result.finderCandidates)
            }
        }
    }

    nonisolated private static func moveDirectlyToTrash(plan: RemovalPlan) -> (
        freed: Int64,
        finderCandidates: [Leftover],
        failures: [RemovalFailure]
    ) {
        let fm = FileManager.default
        var freed: Int64 = 0
        var stubborn: [Leftover] = []
        var failures: [RemovalFailure] = []
        for item in plan.items {
            guard Self.removalIsStillSafe(item,
                                          allowedPaths: plan.allowedPaths,
                                          targetURL: plan.targetURL) else {
                failures.append(RemovalFailure(url: item.url,
                                               reason: "删除前文件身份或路径发生变化"))
                continue
            }
            do {
                try fm.trashItem(at: item.url, resultingItemURL: nil)
                freed += item.size
            } catch {
                if requiresFinderAuthorization(for: error) {
                    stubborn.append(item)
                } else {
                    failures.append(RemovalFailure(
                        url: item.url,
                        reason: removalErrorMessage(error)
                    ))
                }
            }
        }

        // Items we lack rights for go through Finder, which shows the
        // administrator prompt and moves them to the Trash like a drag.
        let finderCandidates = stubborn.filter {
            Self.removalIsStillSafe($0,
                                    allowedPaths: plan.allowedPaths,
                                    targetURL: plan.targetURL)
        }
        let finderCandidateIDs = Set(finderCandidates.map(\.id))
        for item in stubborn where !finderCandidateIDs.contains(item.id) {
            failures.append(RemovalFailure(url: item.url,
                                           reason: "请求 Finder 前文件身份或路径发生变化"))
        }
        return (freed, finderCandidates, failures)
    }

    /// Finder is only an escalation path for an explicit permission failure.
    /// Treating every `trashItem` error as an Apple Event problem hides useful
    /// diagnostics such as a missing path or a file that changed underneath us.
    nonisolated static func requiresFinderAuthorization(for error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == CocoaError.Code.fileWriteNoPermission.rawValue
                || nsError.code == CocoaError.Code.fileReadNoPermission.rawValue
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        return false
    }

    nonisolated private static func removalErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case CocoaError.Code.fileNoSuchFile.rawValue:
                return "项目已不存在"
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EBUSY) {
            return "项目正在使用，无法移至废纸篓"
        }
        return "移至废纸篓失败：\(nsError.localizedDescription)"
    }

    private func performFinderRemoval(plan: RemovalPlan, candidates: [Leftover]) async {
        let validCandidates = candidates.filter {
            Self.removalIsStillSafe($0,
                                    allowedPaths: plan.allowedPaths,
                                    targetURL: plan.targetURL)
        }
        let validIDs = Set(validCandidates.map(\.id))
        accumulatedFailures.append(contentsOf: candidates.filter { !validIDs.contains($0.id) }.map {
            RemovalFailure(url: $0.url, reason: "重试前文件身份或路径发生变化")
        })
        guard !validCandidates.isEmpty else {
            pendingFinderItems = []
            let appStillExists = FileManager.default.fileExists(atPath: plan.targetURL.path)
            await restoreStoppedLaunchItemsIfNeeded(appStillExists: appStillExists)
            finishRemoval(targetURL: plan.targetURL)
            return
        }

        let authorization = await FinderAutomationAuthorization.requestPermission()
        guard phase == .removing else { return }
        guard authorization == .granted else {
            pendingFinderItems = validCandidates
            phase = .awaitingFinderAuthorization(
                freed: accumulatedFreed,
                pending: validCandidates.count
            )
            return
        }

        let finderError = await Task.detached(priority: .userInitiated) {
            Self.trashViaFinder(validCandidates.map(\.url))
        }.value
        guard phase == .removing else { return }
        let fm = FileManager.default
        var remaining: [Leftover] = []
        for item in validCandidates {
            if fm.fileExists(atPath: item.url.path) {
                remaining.append(item)
            } else {
                accumulatedFreed += item.size
            }
        }

        if !remaining.isEmpty, finderError?.number == Int(errAEEventNotPermitted) {
            pendingFinderItems = remaining
            phase = .awaitingFinderAuthorization(
                freed: accumulatedFreed,
                pending: remaining.count
            )
            return
        }
        accumulatedFailures.append(contentsOf: remaining.map {
            RemovalFailure(
                url: $0.url,
                reason: finderError?.message ?? "Finder 未移动该项目，可能已取消管理员验证"
            )
        })
        pendingFinderItems = []
        let appStillExists = fm.fileExists(atPath: plan.targetURL.path)
        await restoreStoppedLaunchItemsIfNeeded(appStillExists: appStillExists)
        finishRemoval(targetURL: plan.targetURL)
    }

    private static func runningComponents(
        appURL: URL,
        relatedBundleIDs: Set<String>
    ) -> [RunningComponent] {
        let workspaceApps = NSWorkspace.shared.runningApplications
        let workspaceByPID = Dictionary(
            workspaceApps.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var componentsByPID = Dictionary(
            UninstallerRuntimeSupport.allProcesses()
                .filter { UninstallerRuntimeSupport.isEligibleProcess($0, appURL: appURL) }
                .map { identity in
                    let fallback = URL(fileURLWithPath: identity.executablePath).lastPathComponent
                    return (identity.pid,
                            RunningComponent(pid: identity.pid,
                                             name: fallback,
                                             identity: identity,
                                             allowsExternalPath: false))
                },
            uniquingKeysWith: { first, _ in first }
        )
        for app in workspaceApps where
            relatedBundleIDs.contains(app.bundleIdentifier ?? "")
                || UninstallerSupport.isNestedBundle(app.bundleURL, in: appURL) {
            guard let identity = UninstallerRuntimeSupport.processIdentity(app.processIdentifier),
                  identity.uid == getuid(), identity.pid != getpid() else {
                continue
            }
            let isInsideApp = UninstallerRuntimeSupport.isEligibleProcess(identity, appURL: appURL)
            componentsByPID[identity.pid] = RunningComponent(
                pid: identity.pid,
                name: app.localizedName
                    ?? URL(fileURLWithPath: identity.executablePath).lastPathComponent,
                identity: identity,
                allowsExternalPath: !isInsideApp
            )
        }

        return componentsByPID.values.map { component in
            guard let name = workspaceByPID[component.pid]?.localizedName else { return component }
            return RunningComponent(pid: component.pid,
                                    name: name,
                                    identity: component.identity,
                                    allowsExternalPath: component.allowsExternalPath)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func requestGracefulTermination(_ components: [RunningComponent],
                                                   appURL: URL) {
        for component in components {
            guard UninstallerRuntimeSupport.isSameProcess(
                component.identity,
                current: UninstallerRuntimeSupport.processIdentity(component.pid),
                appURL: appURL,
                allowsExternalPath: component.allowsExternalPath
            ) else { continue }
            if let app = NSRunningApplication(processIdentifier: component.pid) {
                _ = app.terminate()
            } else {
                _ = Darwin.kill(component.pid, SIGTERM)
            }
        }
    }

    private static func forceTerminate(_ components: [RunningComponent], appURL: URL) {
        for component in components {
            guard UninstallerRuntimeSupport.isSameProcess(
                component.identity,
                current: UninstallerRuntimeSupport.processIdentity(component.pid),
                appURL: appURL,
                allowsExternalPath: component.allowsExternalPath
            ) else { continue }
            if let app = NSRunningApplication(processIdentifier: component.pid) {
                _ = app.forceTerminate()
            } else {
                _ = Darwin.kill(component.pid, SIGKILL)
            }
        }
    }

    private static func waitForExit(_ components: [RunningComponent],
                                    appURL: URL,
                                    timeout: TimeInterval) async -> [RunningComponent] {
        guard !components.isEmpty else { return [] }
        let deadline = Date().addingTimeInterval(timeout)
        var remaining = components
        while Date() < deadline {
            remaining = await Task.detached(priority: .utility) {
                components.filter {
                    UninstallerRuntimeSupport.isSameProcess(
                        $0.identity,
                        current: UninstallerRuntimeSupport.processIdentity($0.pid),
                        appURL: appURL,
                        allowsExternalPath: $0.allowsExternalPath
                    )
                }
            }.value
            if remaining.isEmpty { return [] }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return remaining
            }
        }
        return remaining
    }

    private func restoreStoppedLaunchItemsIfNeeded(appStillExists: Bool) async {
        guard appStillExists, !stoppedLaunchItems.isEmpty else {
            stoppedLaunchItems = []
            return
        }
        let itemsToRestore = stoppedLaunchItems
        stoppedLaunchItems = []
        let uid = getuid()
        let failures = await Task.detached(priority: .utility) {
            itemsToRestore.compactMap { item -> RemovalFailure? in
                guard UninstallerSupport.fileIdentity(at: item.url) == item.identity,
                      let arguments = UninstallerRuntimeSupport.bootstrapArguments(for: item,
                                                                                   uid: uid) else {
                    return nil
                }
                let result = UninstallerRuntimeSupport.runLaunchctl(arguments: arguments)
                guard !result.succeeded else { return nil }
                return RemovalFailure(
                    url: item.url,
                    reason: "卸载未完成，且无法重新启动原启动项：\(result.errorText)"
                )
            }
        }.value
        accumulatedFailures.append(contentsOf: failures)
    }

    private func finishRemoval(targetURL: URL) {
        let applicationWasRemoved = !FileManager.default.fileExists(atPath: targetURL.path)
        items = []
        pendingFinderItems = []
        runningComponents = []
        removalFailures = accumulatedFailures
        phase = .done(freed: accumulatedFreed, failed: accumulatedFailures.count)
        pendingRemovalPlan = nil
        if applicationWasRemoved {
            InstalledAppsCatalog.shared.removeApplication(at: targetURL)
        }
    }

    /// Asks Finder to trash `urls` in one batch via in-process Apple Events.
    /// Finder owns the privilege elevation (the administrator prompt); a cancel
    /// simply leaves the items in place.
    nonisolated private struct FinderError: Sendable {
        let number: Int?
        let message: String
    }

    nonisolated private static func trashViaFinder(_ urls: [URL]) -> FinderError? {
        guard !urls.isEmpty else { return nil }
        let targets = urls
            .map { "set end of targets to POSIX file \(literal($0.path))" }
            .joined(separator: "\n")
        let source = """
        set targets to {}
        \(targets)
        tell application "Finder" to delete targets
        """
        guard let script = NSAppleScript(source: source) else {
            return FinderError(number: nil, message: "无法创建 Finder 删除请求")
        }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }
        let message = errorInfo[NSAppleScript.errorMessage] as? String
        let number = errorInfo[NSAppleScript.errorNumber] as? Int
        return FinderError(number: number,
                           message: message.map { "Finder 错误 \(number ?? 0)：\($0)" }
                               ?? "Finder 拒绝了删除请求")
    }

    nonisolated private static func literal(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Scanning

    nonisolated private static func collect(bundleID: String, appURL: URL) -> ScanResult {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let lib = home + "/Library"
        var paths: [(URL, Category)] = [(appURL, .app)]
        // One traversal collects nested bundle IDs and allocated size. Large
        // application bundles (Xcode, games) previously walked every file twice.
        let appScan = scanAppBundle(appURL, primaryBundleID: bundleID, fm: fm)
        let bundleIDs = appScan.bundleIDs

        func add(_ path: String, _ category: Category) {
            let url = URL(fileURLWithPath: path)
            if fm.fileExists(atPath: url.path) { paths.append((url, category)) }
        }
        func addMatches(in dir: String, _ category: Category, where matches: (String) -> Bool) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for entry in entries where matches(entry) {
                paths.append((URL(fileURLWithPath: dir).appendingPathComponent(entry), category))
            }
        }

        for id in bundleIDs {
            add("\(lib)/Application Support/\(id)", .support)
            add("\(lib)/Containers/\(id)", .containers)
            add("\(lib)/Caches/\(id)", .caches)
            add("\(lib)/Preferences/\(id).plist", .preferences)
            add("\(lib)/Saved Application State/\(id).savedState", .state)
            add("\(lib)/HTTPStorages/\(id)", .caches)
            add("\(lib)/HTTPStorages/\(id).binarycookies", .caches)
            add("\(lib)/WebKit/\(id)", .caches)
            add("\(lib)/Application Scripts/\(id)", .containers)
            add("\(lib)/Cookies/\(id).binarycookies", .caches)
            add("\(lib)/Logs/\(id)", .logs)
            add("/Library/Application Support/\(id)", .support)
            add("/Library/Caches/\(id)", .caches)
            add("/Library/Preferences/\(id).plist", .preferences)
            add("/Library/PrivilegedHelperTools/\(id)", .other)
        }

        addMatches(in: "\(lib)/Preferences/ByHost", .preferences) {
            UninstallerSupport.matchesByHostPreference($0, bundleIDs: bundleIDs)
        }
        addMatches(in: "\(lib)/Group Containers", .containers) {
            UninstallerSupport.matchesGroupContainer($0, bundleIDs: bundleIDs)
        }
        for directory in ["\(lib)/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            addMatches(in: directory, .other) {
                UninstallerSupport.matchesLaunchItem($0, bundleIDs: bundleIDs)
            }
        }

        let deepCandidates = UninstallerSupport.exactDeepCandidates(
            home: URL(fileURLWithPath: home, isDirectory: true),
            bundleIDs: bundleIDs,
            darwinCache: darwinUserDirectory(_CS_DARWIN_USER_CACHE_DIR),
            darwinTemp: darwinUserDirectory(_CS_DARWIN_USER_TEMP_DIR)
        )
        for candidate in deepCandidates {
            add(candidate.url.path, candidate.kind == .support ? .support : .caches)
        }

        let appPath = appURL.standardizedFileURL.path
        let allowedRoots = scanRoots(home: home)
        let safe = dedupe(paths).filter { url, _ in
            let path = url.standardizedFileURL.path
            if path == appPath { return true }
            guard let root = allowedRoots.first(where: { path.hasPrefix($0.path + "/") }) else { return false }
            return !hasSymbolicLinkInParents(of: url, through: root)
        }
        let items: [Leftover] = safe
            .compactMap { url, category in
                guard let identity = UninstallerSupport.fileIdentity(at: url) else { return nil }
                let size = url.standardizedFileURL.path == appPath
                    ? appScan.allocatedSize
                    : directorySize(of: url, fm: fm)
                return Leftover(url: url,
                                category: category,
                                size: size,
                                identity: identity)
            }
            .sorted {
                if $0.category.sortRank != $1.category.sortRank {
                    return $0.category.sortRank < $1.category.sortRank
                }
                return $0.size > $1.size
            }
        let launchItems: [UninstallerRuntimeSupport.LaunchItem] = items.compactMap {
            guard let launchItem = UninstallerRuntimeSupport.launchItem(at: $0.url),
                  bundleIDs.contains(launchItem.label) else {
                return nil
            }
            return launchItem
        }
        return ScanResult(items: items,
                          bundleIDs: bundleIDs,
                          launchItems: launchItems)
    }

    nonisolated private static func removalIsStillSafe(_ item: Leftover,
                                           allowedPaths: Set<String>,
                                           targetURL: URL?) -> Bool {
        let url = item.url
        let path = url.standardizedFileURL.path
        guard allowedPaths.contains(path),
              let targetURL,
              UninstallerSupport.fileIdentity(at: url) == item.identity else { return false }
        if path == targetURL.standardizedFileURL.path { return !isSymbolicLink(url) }
        guard let root = scanRoots(home: NSHomeDirectory()).first(where: {
            path.hasPrefix($0.path + "/")
        }) else { return false }
        return !hasSymbolicLinkInParents(of: url, through: root)
    }

    private struct AppBundleScan {
        var bundleIDs: Set<String>
        var allocatedSize: Int64
    }

    nonisolated private static func scanAppBundle(_ appURL: URL,
                                                  primaryBundleID: String,
                                                  fm: FileManager) -> AppBundleScan {
        var result = AppBundleScan(bundleIDs: [primaryBundleID], allocatedSize: 0)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        guard let enumerator = fm.enumerator(at: appURL,
                                             includingPropertiesForKeys: Array(keys),
                                             options: [],
                                             errorHandler: nil) else { return result }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            result.allocatedSize += Int64(
                values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            )
            guard values?.isDirectory == true,
                  ["app", "appex", "xpc", "plugin", "bundle"].contains(url.pathExtension.lowercased()),
                  let id = UninstallerSupport.verifiedBundleID(Bundle(url: url)?.bundleIdentifier),
                  id.hasPrefix(primaryBundleID + ".") else { continue }
            result.bundleIDs.insert(id)
        }
        return result
    }

    nonisolated private static func scanRoots(home: String) -> [URL] {
        var roots = [
            URL(fileURLWithPath: home + "/Library", isDirectory: true),
            URL(fileURLWithPath: "/Library", isDirectory: true),
            URL(fileURLWithPath: home + "/.config", isDirectory: true),
            URL(fileURLWithPath: home + "/.cache", isDirectory: true),
            URL(fileURLWithPath: home + "/.local/share", isDirectory: true),
        ]
        if let cache = darwinUserDirectory(_CS_DARWIN_USER_CACHE_DIR) { roots.append(cache) }
        if let temp = darwinUserDirectory(_CS_DARWIN_USER_TEMP_DIR) { roots.append(temp) }
        return roots.map(\.standardizedFileURL)
    }

    nonisolated private static func darwinUserDirectory(_ name: Int32) -> URL? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    nonisolated private static func hasSymbolicLinkInParents(of url: URL, through root: URL) -> Bool {
        var current = url.deletingLastPathComponent().standardizedFileURL
        let root = root.standardizedFileURL
        while current.path.count >= root.path.count {
            if isSymbolicLink(current) { return true }
            if current.path == root.path { return false }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return true }
            current = parent
        }
        return true
    }

    nonisolated private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    nonisolated private static func dedupe(_ paths: [(URL, Category)]) -> [(URL, Category)] {
        var seen = Set<String>()
        var roots: [String] = []
        var out: [(URL, Category)] = []
        for (url, category) in paths.sorted(by: { $0.0.path.count < $1.0.path.count }) {
            let path = url.standardizedFileURL.path
            if seen.contains(path) { continue }
            if roots.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            seen.insert(path)
            roots.append(path)
            out.append((url, category))
        }
        return out
    }

    nonisolated private static func directorySize(of url: URL, fm: FileManager) -> Int64 {
        if isSymbolicLink(url) { return fileSize(url) }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return fileSize(url) }

        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: url,
                                          includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                                          options: [], errorHandler: nil) {
            for case let item as URL in enumerator {
                if isSymbolicLink(item) { continue }
                total += fileSize(item)
            }
        }
        return total
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }
}
