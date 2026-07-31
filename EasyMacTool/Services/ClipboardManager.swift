import AppKit
import Combine
import CoreGraphics
import Foundation

/// Monitors the system pasteboard and maintains a clipboard history list.
///
/// Strategy: poll `NSPasteboard.general.changeCount` on a 0.5s timer. When it
/// changes, snapshot the current contents into a `ClipboardItem` and prepend
/// to history. Dedupes consecutive identical entries. Skips items that this
/// manager itself just wrote (to avoid feedback loops when re-pasting).
@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    /// metadata.json 的 schema 版本号。结构变更时递增，并在 loadFromDisk
    /// 中提供迁移路径。v0 = 旧格式（裸 [ClipboardItem] 数组，无版本字段）；
    /// v1 = 当前格式（{ schemaVersion: 1, items: [...] }）。
    private static let currentSchemaVersion = 1

    /// metadata.json 的顶层容器结构。包裹 schemaVersion + items 数组，
    /// 未来 ClipboardItem 结构变更后可通过版本号判断并迁移，避免旧文件
    /// 解码失败导致历史数据全部丢失。
    private struct ClipboardMetadata: Codable {
        let schemaVersion: Int
        let items: [ClipboardItem]
    }

    /// Keep clipboard history bounded even when the user raises the item count
    /// to 1000. Images retain their original TIFF data, so a count-only limit
    /// is insufficient to protect the process from memory pressure.
    private static let maximumImagePayloadBytes = 20 * 1024 * 1024
    /// 文本条目单条大小上限：防止用户复制超大文本（如导出的 JSON、日志全选）
    /// 导致内存尖峰 + JSON 编码耗时（主线程）+ 搜索过滤卡顿。与图片上限对称。
    private static let maximumTextPayloadBytes = 5 * 1024 * 1024
    private static let maximumHistoryPayloadBytes = 150 * 1024 * 1024
    /// 热数据阈值：7 天内的 image 条目在启动时加载 data/thumbnail 到内存；
    /// 超过 7 天的 image 条目仅加载元数据，访问时通过 warmUp() 从磁盘恢复。
    private static let hotDataCutoff: TimeInterval = 7 * 24 * 60 * 60
    private static let sensitiveBundleIDFragments = [
        "1password", "bitwarden", "lastpass", "dashlane", "keepass",
        "enpass", "protonpass", "nordpass", "keepersecurity"
    ]
    /// 密码管理器等写入剪贴板时附带的"不应被记录"约定标记（1Password 等
    /// 均遵守）。比 bundleID 黑名单更可靠：浏览器自动填充复制的密码来源
    /// 是浏览器本身，黑名单无法覆盖，但约定标记会随内容一起写入。
    private static let sensitivePasteboardMarkers: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword")
    ]

    // MARK: - Persistence URLs

    /// Application Support 目录是否可用。获取失败时（极罕见）不持久化，
    /// 避免明文剪贴板历史落入 NSTemporaryDirectory（/var/folders）——
    /// 临时目录语义不适合持久化数据，且更易被系统清理导致数据丢失。
    private static var storageIsAvailable: Bool {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first != nil
    }

    /// 持久化根目录：~/Library/Application Support/EasyMacTool/Clipboard/
    /// 仅在 storageIsAvailable 为 true 时调用。
    private static var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("EasyMacTool/Clipboard", isDirectory: true)
    }
    private static var metadataURL: URL {
        storageDirectory.appendingPathComponent("metadata.json", isDirectory: false)
    }
    private static var imagesDirectoryURL: URL {
        storageDirectory.appendingPathComponent("images", isDirectory: true)
    }

    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var isCapturing = true

    /// Configured maximum history length. Older entries are dropped.
    /// 设置新值时若小于当前条数，立即裁剪尾部，避免降档后仍持有大量旧数据
    /// 占用内存（用户从 1000 降到 50 时无需等下次复制触发 removeLast）。
    /// didSet 中触发 trimHistoryToLimits + schedulePersist，保证设置变更
    /// 立即落盘（之前不持久化会导致重启后上限失效）。
    var historyLimit: Int = 100 {
        didSet {
            guard historyLimit < oldValue else { return }
            trimHistoryToLimits()
            schedulePersist()
        }
    }

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    /// 精确抑制 reapply write 引起的 changeCount 变化。
    /// 记录 write 后预期的 changeCount 值，poll 时精确比较：
    /// - current == suppressUntilChangeCount：是 write 引起的，抑制
    /// - current > suppressUntilChangeCount：用户在 write 后又复制了，不抑制，正常捕获
    /// - current < suppressUntilChangeCount：不可能（changeCount 单调递增）
    /// 这比布尔标志更精确，避免误抑制用户在 write 后立即复制的内容。
    private var suppressUntilChangeCount: Int?
    /// 当前正在执行的 reapply Task。reapply 时先 cancel 前一个，防止
    /// 快速连续选择多个条目时并发写入 pasteboard 和多次 simulatePaste。
    private var currentReapplyTask: Task<Void, Never>?
    /// reapply 竞态防护 token：每次 reapply 生成新 token，旧 Task 在 write 前
    /// 检查 token 是否仍是最新，否则放弃 write。Task.cancel 只在 await 点生效，
    /// 旧 Task 过 await 后的同步 write 不可中断，需要 token 防护。
    private var reapplyToken = UUID()
    /// 防抖保存计时器：合并短时间内的多次变更为一次磁盘写入。
    private var saveTimer: Timer?
    /// 串行保存队列：确保 saveToDisk（异步）与 saveToDiskSync（同步退出 flush）
    /// 不会并发写 metadata.json。saveToDiskSync 用 sync 派发，等待所有 pending
    /// 异步保存完成后再执行自己的写入，避免退出时旧 Task 覆盖最新数据。
    private let saveQueue = DispatchQueue(label: "com.easymactool.clipboardSave")
    /// 待删除的磁盘图片文件路径集合。
    /// remove/clearHistory/removeOlderThan/trimHistoryToLimits 将待清理的
    /// imageFileURL 收集到此集合，saveToDisk 在后台 IO 时统一删除，
    /// 避免删除条目后 images/{uuid}.tiff 残留导致磁盘无限膨胀。
    private var pendingImageDeletions: Set<String> = []
    /// 系统内存压力源。收到 .warning/.critical 事件时对所有 item 调用
    /// coolDown() 释放懒加载缓存（_cachedFullImage 等），避免 1000 张图
    /// 的 fullImage 永久持有导致内存爆炸。macOS 用 DispatchSource 而非
    /// NotificationCenter（didReceiveMemoryWarningNotification 是 iOS API）。
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        // 重新同步 changeCount：init 到 start 之间若用户复制了内容，
        // poll 会误把这段内容当作新条目加入历史。ClipboardManager.shared
        // 是单例，可能在 AppCoordinator.init 之前被其他视图（如设置页）访问，
        // 间隔虽短但存在窗口。
        lastChangeCount = NSPasteboard.general.changeCount
        // 启动时从磁盘加载历史，恢复上次会话的剪贴板内容。
        loadFromDisk()
        // loadFromDisk 后立即裁剪：磁盘上的条目可能超过当前 historyLimit
        // （如用户在设置中降低了上限后重启），保证启动后内存与上限一致。
        trimHistoryToLimits()
        let instance = self
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in instance.poll() }
        }
        // 监听系统内存压力：收到 .warning/.critical 时对所有 item 调用
        // coolDown() 释放懒加载缓存（_cachedFullImage / _cachedAttributedString 等）。
        // 这些缓存可在下次访问时重新生成，释放它们不会丢失数据。
        // macOS 用 DispatchSource.makeMemoryPressureSource（NotificationCenter
        // 的 didReceiveMemoryWarningNotification 是 iOS UIKit API，macOS 不可用）。
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.items.forEach { $0.coolDown() }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // 取消内存压力源
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        // 停止时刷新未写入的变更：取消防抖 timer，立即同步落盘。
        // saveToDiskSync 是同步实现，确保 app 退出前数据已写入磁盘
        // （之前用异步 DispatchQueue.global().async 派发，app 退出时
        // 主 run loop 停止后后台任务可能未完成就被终止，导致数据丢失）。
        saveTimer?.invalidate()
        saveTimer = nil
        saveToDiskSync()
    }

    /// 同步保存版本：用于 app 退出时的强制 flush。
    /// 在主线程完成 JSON 编码后，通过 saveQueue.sync 同步写入磁盘。
    /// sync 会等待所有 pending 的异步 saveToDisk 完成，再执行自己的写入，
    /// 避免旧异步 Task 覆盖最新数据。牺牲几十毫秒的主线程时间换取数据安全。
    private func saveToDiskSync() {
        guard Self.storageIsAvailable else { return }
        let dir = Self.storageDirectory
        let imgDir = Self.imagesDirectoryURL
        let metaURL = Self.metadataURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var imagesToWrite: [(URL, Data)] = []
        for item in items {
            guard case .image(let data, _) = item.kind, let data else { continue }
            if item.imageFileURL == nil {
                item.imageFileURL = imgDir.appendingPathComponent("\(item.id.uuidString).tiff")
            }
            guard let url = item.imageFileURL else { continue }
            if !FileManager.default.fileExists(atPath: url.path) {
                imagesToWrite.append((url, data))
            }
        }
        guard let jsonData = try? encoder.encode(ClipboardMetadata(
            schemaVersion: Self.currentSchemaVersion,
            items: items
        )) else {
            print("[ClipboardManager] JSON encode failed (sync)")
            return
        }
        let deletions = pendingImageDeletions
        pendingImageDeletions.removeAll()
        // sync 派发：等待所有 pending 异步保存完成后再执行，确保最终写入的是最新数据
        saveQueue.sync {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
                // 收紧权限：剪贴板历史属敏感数据，目录 0700、文件 0600，
                // 避免同机其他用户/进程读取明文历史。
                Self.applyProtectivePermissions(directory: dir, imagesDirectory: imgDir)
                for (url, data) in imagesToWrite {
                    // .atomic：写临时文件后 rename，进程中途被杀不会留下
                    // 半截 TIFF（否则 warmUp 静默失败，图片条目永久空白）。
                    try data.write(to: url, options: .atomic)
                    // TIFF 文件同样收紧为 0600，与 metadata.json 保持一致
                    //（.atomic 写入继承 umask 通常为 0644，纵深防御补齐）。
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                           ofItemAtPath: url.path)
                }
                try jsonData.write(to: metaURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: metaURL.path)
                // 清理已删除条目对应的磁盘图片文件
                for path in deletions {
                    try? FileManager.default.removeItem(atPath: path)
                }
            } catch {
                print("[ClipboardManager] Save failed (sync): \(error)")
                // 删除清单并回集合：本轮清理失败，待下轮保存重试，
                // 避免 images/ 目录因清单丢失而缓慢膨胀。
                // saveQueue.sync 在主线程上同步执行，可直接访问 @MainActor 状态。
                pendingImageDeletions.formUnion(deletions)
            }
        }
    }

    /// 收紧持久化目录权限为 0700（仅本人可读写进入）。
    /// FileManager.createDirectory 不会覆盖已存在目录的权限，需显式设置。
    /// 在 saveQueue（串行后台队列）或主线程 saveQueue.sync 块内调用。
    nonisolated private static func applyProtectivePermissions(directory: URL, imagesDirectory: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: imagesDirectory.path)
    }

    func setCapturing(_ enabled: Bool) {
        isCapturing = enabled
        // Forget the current change count so content copied while paused is
        // never retrospectively added when the user resumes observation.
        lastChangeCount = NSPasteboard.general.changeCount
    }

    /// Re-pastes the given item: writes it to the pasteboard and (optionally)
    /// simulates Cmd+V into the previously frontmost app.
    ///
    /// 冷数据图片（>7天）需先异步 warmUp 从磁盘加载 TIFF Data，避免
    /// write(to:) 内部同步 warmUp() 阻塞主线程（30MB TIFF 同步读盘
    /// 可能造成几十毫秒卡顿，刚好是模拟 Cmd+V 前的关键时刻）。
    ///
    /// suppressUntilChangeCount 在 Task 内、write 之后立即设置，记录 write
    /// 引起的最终 changeCount 作为抑制值。write 调用 pasteboard.clearContents()
    /// 使 changeCount +1，然后写入内容使 changeCount 再 +1（取决于写入类型数）。
    /// 在 write 之后设置能精确记录实际 changeCount，避免预估不准。
    ///
    /// 竞态防护：用 token 标识最新 reapply。Task.cancel 只在 await 点生效，
    /// 旧 Task 过 await 后的同步 write 不可中断；旧 Task 在 write 前检查 token
    /// 是否仍是最新，否则放弃，避免 pasteboard 内容/items 顺序/persist 错乱。
    func reapply(_ item: ClipboardItem, autoPaste: Bool) {
        let token = UUID()
        reapplyToken = token
        currentReapplyTask?.cancel()
        currentReapplyTask = Task {
            // 冷数据图片：先异步 warmUp 加载 TIFF Data
            if case .image(let data, _) = item.kind, data == nil {
                await item.warmUpAsync()
            }
            // token 检查：若期间有新 reapply 进入，旧 Task 放弃 write。
            // Task.isCancelled 也检查（双保险）。
            guard !Task.isCancelled, token == reapplyToken else { return }
            // 在 write 之前记录 changeCount，write 后读取实际 changeCount 作为抑制值。
            let beforeWrite = NSPasteboard.general.changeCount
            item.write(to: .general)
            suppressUntilChangeCount = NSPasteboard.general.changeCount
            // 如果 write 前后 changeCount 没变（理论上不可能），回退到旧逻辑
            if suppressUntilChangeCount == beforeWrite {
                suppressUntilChangeCount = nil
            }
            // Move the item to the top so it's most-recently-used.
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                let moved = items.remove(at: idx)
                items.insert(moved, at: 0)
            }
            schedulePersist()
            if autoPaste {
                // 用 Task.sleep 代替 DispatchQueue.main.asyncAfter，
                // 这样 Task.cancel 能取消未执行的 simulatePaste。
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                guard !Task.isCancelled, token == reapplyToken else { return }
                self.simulatePaste()
            }
        }
    }

    func clearHistory() {
        // 收集所有 image 条目的磁盘文件路径，待 saveToDisk 时清理
        for item in items {
            if let path = item.imageFileURL?.path {
                pendingImageDeletions.insert(path)
            }
        }
        items.removeAll()
        schedulePersist()
    }

    func remove(_ item: ClipboardItem) {
        // 收集被删除 image 条目的磁盘文件路径
        if let path = item.imageFileURL?.path {
            pendingImageDeletions.insert(path)
        }
        items.removeAll { $0.id == item.id }
        schedulePersist()
    }

    /// Removes entries whose `createdAt` is older than the given number of
    /// days. Used by the settings page's "删除7天前记录" action.
    func removeOlderThan(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        // 收集被删除 image 条目的磁盘文件路径
        for item in items where item.createdAt < cutoff {
            if let path = item.imageFileURL?.path {
                pendingImageDeletions.insert(path)
            }
        }
        items.removeAll { $0.createdAt < cutoff }
        schedulePersist()
    }

    // MARK: - Polling

    private func poll() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard isCapturing else { return }

        // 精确抑制：只抑制 reapply write 引起的 changeCount 变化。
        // - current == suppressUntilChangeCount：是 write 引起的，抑制
        // - current > suppressUntilChangeCount：用户在 write 后又复制了，不抑制
        // 这避免了布尔标志误抑制用户在 write 后立即复制的内容。
        if let suppress = suppressUntilChangeCount, current == suppress {
            suppressUntilChangeCount = nil
            return
        }
        // current > suppress 或 suppress 为 nil：正常捕获
        suppressUntilChangeCount = nil

        // Quick type check before expensive readObjects call.
        guard let types = pb.types, !types.isEmpty else { return }
        // 遵守 concealed/transient 约定：密码管理器等写入剪贴板时附带这些
        // 类型标记表示"不应被记录"。比 bundleID 黑名单更可靠（浏览器自动
        // 填充复制的密码来源是浏览器，黑名单覆盖不到）。检查优先级最高。
        if types.contains(where: { Self.sensitivePasteboardMarkers.contains($0) }) { return }
        let hasURL = types.contains(.URL)
        let hasString = types.contains(.string)
        let hasTIFF = types.contains(.tiff)
        let hasFileURL = types.contains(.fileURL)
        guard hasURL || hasString || hasTIFF || hasFileURL else { return }

        guard let item = snapshot() else { return }
        // 去重：遍历全部历史，若已有相同 payload 的条目，把旧条目移到第一位，
        // 不创建新副本。这比"只检查第一项 + 丢弃"更合理：
        // - 解决 A→B→A 场景下 A 不被去重的问题（旧逻辑只查 items.first）
        // - 重复时提升旧条目到顶部（MRU 语义），而非保留旧位置
        // - 节省内存：不重复创建 ClipboardItem 和图片副本
        // 保留旧条目的 id 和 createdAt（稳定标识 + 原始创建时间），
        // 来源信息保留旧的——避免因"最近从 app Y 复制了相同内容"而丢失
        // 原始来源 X 的记录，原始来源对用户追溯更有意义。
        if let existingIndex = items.firstIndex(where: { isSamePayload($0, item) }) {
            let existing = items.remove(at: existingIndex)
            items.insert(existing, at: 0)
            schedulePersist()
            return
        }
        items.insert(item, at: 0)
        trimHistoryToLimits()
        schedulePersist()
    }

    /// Snapshots whatever is currently on the pasteboard into a ClipboardItem.
    /// Also captures the frontmost app's bundleID/name/tint so the card header
    /// can show its origin.
    private func snapshot() -> ClipboardItem? {
        let pb = NSPasteboard.general
        let (appName, appBundleID, appIcon, appTint) = captureSourceApp()
        guard !isSensitiveSource(bundleID: appBundleID) else { return nil }

        // File URLs take priority — copy/paste of Finder selections.
        // 必须过滤 isFileURL：readObjects([NSURL.self], options: nil) 同时
        // 接受 public.url（网页链接），不过滤的话浏览器复制的链接会被误
        // 归类为 .file（显示"1 个文件"卡片），后续 .url 分支成为死代码。
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty,
           urls.allSatisfy({ $0.isFileURL }) {
            return ClipboardItem(kind: .file(URLs: urls),
                                 sourceAppBundleID: appBundleID,
                                 sourceAppName: appName,
                                 sourceAppTint: appTint)
        }

        // Images. Keep the original TIFF only within a strict per-item budget;
        // otherwise a single pasted bitmap could make the history unusable.
        if let tiff = pb.data(forType: .tiff),
           tiff.count <= Self.maximumImagePayloadBytes,
           let thumbnail = ClipboardItem.makeThumbnail(from: tiff, max: 256) {
            // Prewarm AppIconCache 以避免后续访问时扫描 runningApplications
            if let appIcon, let appBundleID {
                AppIconCache.prewarm(appIcon, for: appBundleID)
            }
            let item = ClipboardItem(kind: .image(tiff, thumbnail: thumbnail),
                                     sourceAppBundleID: appBundleID,
                                     sourceAppName: appName,
                                     sourceAppTint: appTint)
            // 设置图片文件 URL，saveToDisk() 会将 TIFF Data 写入此路径。
            item.imageFileURL = Self.imagesDirectoryURL.appendingPathComponent("\(item.id.uuidString).tiff")
            // 捕获时填充像素尺寸缓存：footerText 直接读缓存，搜索过滤时
            // 不再对每个图片条目重复做 ImageIO 元数据解析。
            item.imagePixelSize = ClipboardItem.readPixelSize(from: tiff)
            return item
        }

        // URLs with a string companion.
        if let urlStr = pb.string(forType: .URL),
           let url = URL(string: urlStr) {
            return ClipboardItem(kind: .url(url, title: url.host),
                                 sourceAppBundleID: appBundleID,
                                 sourceAppName: appName,
                                 sourceAppTint: appTint)
        }

        // Plain text (also catches URLs copied as plain text).
        if let text = pb.string(forType: .string) {
            // 单条文本大小上限：超大文本（如导出的 JSON、日志全选复制）会
            // 导致内存尖峰 + JSON 编码耗时 + 搜索卡顿，跳过记录。
            // 颜色/URL 启发式判断在大小检查之前，短字符串不受影响。
            let rtfData = pb.data(forType: .rtf)
            // Heuristic: looks like a color string (#RRGGBB / rgb() / hsl()) —
            // render as a color card.
            if let (color, hex) = ColorStringParser.parse(text) {
                return ClipboardItem(kind: .color(color, hex: hex),
                                     sourceAppBundleID: appBundleID,
                                     sourceAppName: appName,
                                     sourceAppTint: appTint)
            }
            // Heuristic: looks like a URL — render as a URL card.
            if let url = URL(string: text),
               let scheme = url.scheme,
               scheme == "http" || scheme == "https" {
                return ClipboardItem(kind: .url(url, title: url.host),
                                     sourceAppBundleID: appBundleID,
                                     sourceAppName: appName,
                                     sourceAppTint: appTint)
            }
            // 文本单条大小上限：超过 maximumTextPayloadBytes 的巨型文本跳过记录，
            // 避免内存尖峰 + JSON 编码耗时 + 搜索卡顿。
            guard text.utf8.count <= Self.maximumTextPayloadBytes else { return nil }
            return ClipboardItem(kind: .text(text),
                                 sourceAppBundleID: appBundleID,
                                 sourceAppName: appName,
                                 sourceAppTint: appTint,
                                 rtfData: rtfData)
        }

        return nil
    }

    /// Captures the currently frontmost app's bundleID, name, icon, and tint
    /// so the card header can show the source. icon 用于 prewarm AppIconCache
    /// 后即丢弃——ClipboardItem 只持有 bundleID，后续通过缓存查询。
    private func captureSourceApp() -> (String?, String?, NSImage?, NSColor) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let name = frontmost?.localizedName
        let bundleID = frontmost?.bundleIdentifier
        // Safe sRGB fallback — avoids catalog-color component crashes.
        var icon: NSImage?
        var tint: NSColor = NSColor(red: 0x0A/255.0, green: 0x84/255.0, blue: 0xFF/255.0, alpha: 1.0)
        if let app = frontmost, let appIcon = app.icon {
            icon = appIcon
            tint = AppTintExtractor.tint(from: appIcon, bundleIdentifier: app.bundleIdentifier)
        }
        return (name, bundleID, icon, tint)
    }

    private func trimHistoryToLimits() {
        // 增量维护 totalBytes：之前每次循环迭代都全量 reduce 重算字节数，
        // 当历史接近 150MB 上限需移除多条时复杂度退化为 O(n²)。
        // 现在循环外计算一次，每次移除时减去对应字节数，整体 O(n)。
        var totalBytes = items.reduce(0) { $0 + $1.estimatedMemoryBytes }
        while items.count > historyLimit || totalBytes > Self.maximumHistoryPayloadBytes {
            guard !items.isEmpty else { return }
            let removed = items.removeLast()
            totalBytes -= removed.estimatedMemoryBytes
            // 收集被裁剪 image 条目的磁盘文件路径
            if let path = removed.imageFileURL?.path {
                pendingImageDeletions.insert(path)
            }
        }
    }

    // MARK: - Persistence

    /// 防抖保存：合并短时间内的多次变更为一次磁盘写入。
    /// 防抖窗口 0.3 秒（之前 1 秒过长，连续复制时崩溃丢数据风险大）。
    /// 关键操作（clearHistory/remove/removeOlderThan）仍走此路径，
    /// 但 0.3 秒窗口已足够短，用户感知不到延迟且数据丢失风险大幅降低。
    /// app 退出时由 stop() → saveToDiskSync() 强制同步 flush。
    private func schedulePersist() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.saveToDisk() }
        }
    }

    /// 将剪贴板历史持久化到磁盘。
    /// - 元数据写入 metadata.json（JSON 编码，image data 不包含在其中）
    /// - 图片 TIFF Data 写入 images/\(id).tiff 独立文件
    /// - 清理已删除条目对应的磁盘图片文件（pendingImageDeletions）
    /// 文件 I/O 在后台队列执行，避免阻塞主线程。
    private func saveToDisk() {
        guard Self.storageIsAvailable else { return }
        let dir = Self.storageDirectory
        let imgDir = Self.imagesDirectoryURL
        let metaURL = Self.metadataURL
        // 在主线程准备数据（ClipboardItem 是 @MainActor，编码必须在主线程）
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 为每个 image item 确保有 imageFileURL；收集需要写入的图片
        var imagesToWrite: [(URL, Data)] = []
        for item in items {
            guard case .image(let data, _) = item.kind, let data else { continue }
            if item.imageFileURL == nil {
                item.imageFileURL = imgDir.appendingPathComponent("\(item.id.uuidString).tiff")
            }
            // 仅当文件不存在时才写入（避免每次保存都重写所有图片）
            guard let url = item.imageFileURL else { continue }
            if !FileManager.default.fileExists(atPath: url.path) {
                imagesToWrite.append((url, data))
            }
        }
        // 在主线程编码 JSON（@MainActor 约束）
        guard let jsonData = try? encoder.encode(ClipboardMetadata(
            schemaVersion: Self.currentSchemaVersion,
            items: items
        )) else {
            print("[ClipboardManager] JSON encode failed")
            return
        }
        // 取出待删除文件路径清单，清空集合（后台 IO 完成后这些文件即被清理）
        let deletions = pendingImageDeletions
        pendingImageDeletions.removeAll()
        // 文件 I/O 在串行保存队列执行，避免与 saveToDiskSync 并发写 metadata.json
        saveQueue.async {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
                Self.applyProtectivePermissions(directory: dir, imagesDirectory: imgDir)
                // 写入图片文件（.atomic：避免进程被杀留下半截 TIFF）
                for (url, data) in imagesToWrite {
                    try data.write(to: url, options: .atomic)
                    // TIFF 文件同样收紧为 0600，与 metadata.json 保持一致。
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                           ofItemAtPath: url.path)
                }
                // 写入元数据 JSON
                try jsonData.write(to: metaURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: metaURL.path)
                // 清理已删除条目对应的磁盘图片文件
                for path in deletions {
                    try? FileManager.default.removeItem(atPath: path)
                }
            } catch {
                print("[ClipboardManager] Save failed: \(error)")
                // 删除清单并回集合（回主线程修改 @MainActor 状态），
                // 待下轮保存重试，避免 images/ 目录因清单丢失而膨胀。
                Task { @MainActor in
                    self.pendingImageDeletions.formUnion(deletions)
                }
            }
        }
    }

    /// 从磁盘加载剪贴板历史。
    /// - 读取 metadata.json 解码所有条目
    /// - image 条目：设置 imageFileURL 为绝对路径
    /// - 热数据（≤7天）：异步 warmUp() 加载 data + thumbnail 到内存
    /// - 冷数据（>7天）：仅保留元数据，访问时按需 warmUp()
    ///
    /// 异步化策略：
    /// 1. 后台队列读取 JSON 文件数据（避免主线程同步文件 IO）
    /// 2. 主线程解码 JSON（ClipboardItem 是 @MainActor，init(from:) 必须在主线程）
    /// 3. 热数据用 Task { await warmUpAsync() } 异步加载图片，不阻塞主线程
    ///
    /// 之前所有 IO 在主线程同步执行：1000 条 JSON + 100 张热图（每张 ~5MB）
    /// 可导致 app 启动时主线程冻结数百毫秒到数秒。现在 JSON 读取在后台，
    /// 解码后立即设置 items（UI 瞬时显示卡片占位），热图异步加载填入。
    private func loadFromDisk() {
        guard Self.storageIsAvailable else { return }
        let metaURL = Self.metadataURL
        let imgDir = Self.imagesDirectoryURL
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return }
        // Step 1: 后台读取 JSON 文件数据（纯 Data，无 @MainActor 依赖）
        DispatchQueue.global(qos: .userInitiated).async {
            guard let fileData = try? Data(contentsOf: metaURL) else {
                Task { @MainActor in self.items = [] }
                return
            }
            // Step 2: 回主线程解码 JSON（ClipboardItem 是 @MainActor 隔离）
            Task { @MainActor in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                // 优先尝试 v1+ 格式（带 schemaVersion 的 ClipboardMetadata 容器）
                // 失败则回退到 v0 旧格式（裸 [ClipboardItem] 数组），保证
                // 升级后首次启动不丢失历史数据。未来结构变更在此添加迁移逻辑。
                let loaded: [ClipboardItem]
                if let metadata = try? decoder.decode(ClipboardMetadata.self, from: fileData) {
                    loaded = metadata.items
                } else if let legacy = try? decoder.decode([ClipboardItem].self, from: fileData) {
                    // v0 旧格式：裸数组，无 schemaVersion 字段
                    loaded = legacy
                } else {
                    print("[ClipboardManager] Load failed: decode error")
                    self.items = []
                    return
                }
                let hotCutoff = Date().addingTimeInterval(-Self.hotDataCutoff)
                for item in loaded {
                    guard case .image = item.kind else { continue }
                    // 解码时 imageFileURL 存的是文件名（相对路径），解析为绝对路径
                    let fileName = item.imageFileURL?.lastPathComponent ?? "\(item.id.uuidString).tiff"
                    item.imageFileURL = imgDir.appendingPathComponent(fileName)
                    // 热数据：异步 warmUp，避免阻塞主线程。
                    // items 先设置（UI 显示占位），图片数据后台加载后自动填入。
                    if item.createdAt > hotCutoff {
                        Task { await item.warmUpAsync() }
                    }
                }
                // 合并 poll 期间新增的条目到 loaded 头部，然后一次性赋值。
                // 之前分两步（先 self.items = loaded，再逐条 insert），SwiftUI
                // 会观察到中间态导致卡片闪烁/选中错位。现在构建完整数组后
                // 单次 @Published 变更，避免中间态。
                let pendingNew = self.items
                let loadedIDs = Set(loaded.map { $0.id })
                var merged = loaded
                for item in pendingNew where !loadedIDs.contains(item.id) {
                    merged.insert(item, at: 0)
                }
                self.items = merged
            }
        }
    }

    private func isSensitiveSource(bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return Self.sensitiveBundleIDFragments.contains { bundleID.contains($0) }
    }

    private func isSamePayload(_ a: ClipboardItem, _ b: ClipboardItem) -> Bool {
        // 快速短路：类型不同直接 false，避免进入 switch。
        // 遍历全部历史时（最多 1000 条），绝大多数条目类型不同（如文本 vs 图片），
        // contentKind 检查 O(1) 排除，避免无意义的 switch 匹配。
        if a.contentKind != b.contentKind { return false }
        switch (a.kind, b.kind) {
        case (.text(let x), .text(let y)): return x == y
        case (.url(let x, _), .url(let y, _)): return x == y
        case (.image(let x, _), .image(let y, _)):
            // 冷数据 data=nil 不参与去重（无法可靠比较，随过期清理淘汰）
            guard let x, let y else { return false }
            // count 不同直接 false，避免大图（20MB）逐字节 memcmp
            guard x.count == y.count else { return false }
            // 快速通道：首尾各 4KB 采样不等直接 false。连续复制同一张
            // 20MB 大图时全量 == 比较需上百毫秒（主线程），采样先排除
            // 绝大多数"不同图同大小"的情况，相等再走全量比较。
            let sampleSize = min(4096, x.count)
            if x.prefix(sampleSize) != y.prefix(sampleSize) { return false }
            if x.suffix(sampleSize) != y.suffix(sampleSize) { return false }
            return x == y
        case (.file(let x), .file(let y)):
            return x == y
        case (.color(_, let h1), .color(_, let h2)):
            return h1 == h2
        default: return false
        }
    }

    /// Simulates Cmd+V into the previously frontmost app. The clipboard panel
    /// must be dismissed BEFORE calling this so the target app receives focus.
    fileprivate func simulatePaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)  // V
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        cmdUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
        // 合成事件经过自己的 .cgSessionEventTap 可能触发 tap 被系统临时禁用
        // （tapDisabledByTimeout）。派发独立 Task 在 50ms 后检查 tap 健康，
        // 失效则立即 restart() 恢复，不等 0.5s hotkeyRetryTimer。
        // 用独立 Task（非 Task.detached）而非关联到 reapply Task，
        // 这样 reapply 被 cancel 时不影响此健康检查。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)  // 等 50ms 让系统处理 tap 禁用回调
            guard AccessibilityChecker.isTrusted else { return }
            if !HotkeyManager.shared.isTapHealthy {
                HotkeyManager.shared.restart()
            }
        }
    }
}
