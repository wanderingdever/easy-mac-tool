import AppKit
import Combine
import CoreGraphics
import Foundation
import os

/// Monitors the system pasteboard and maintains a clipboard history list.
///
/// Strategy: poll `NSPasteboard.general.changeCount` on a 0.5s timer. When it
/// changes, snapshot the current contents into a `ClipboardItem` and prepend
/// to history. Dedupes consecutive identical entries. Skips items that this
/// manager itself just wrote (to avoid feedback loops when re-pasting).
@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()
    nonisolated private static let logger = Logger(subsystem: "com.easymactool", category: "ClipboardManager")

    /// metadata.json 的 schema 版本号。结构变更时递增，并在 loadFromDisk
    /// 中提供迁移路径。v0 = 旧格式（裸 [ClipboardItem] 数组，无版本字段）；
    /// v1 = { schemaVersion: 1, items: [...] }；v2 = 增加 groups（分组取代置顶）。
    nonisolated private static let currentSchemaVersion = 2

    /// metadata.json 的顶层容器结构。包裹 schemaVersion + items + groups。
    private struct ClipboardMetadata: Codable {
        let schemaVersion: Int
        let items: [ClipboardItem]
        /// 分组列表（v2 新增）。groups 为可选，v1 旧文件无此字段 → 解码为 []。
        let groups: [ClipboardGroup]?

        enum CodingKeys: String, CodingKey {
            case schemaVersion, items, groups
        }
    }

    /// 磁盘快照 DTO（Sendable）：主线程从 ClipboardItem 提取，后台 JSONEncoder
    /// 编码，避免 @MainActor 的 ClipboardItem.encode(to:) 在主线程阻塞。
    /// CodingKeys 与 ClipboardItem 完全一致，保证磁盘格式不变（向后兼容）。
    nonisolated private struct ClipboardHistorySnapshot: Codable, Sendable {
        let schemaVersion: Int
        let items: [ItemSnapshot]
        let groups: [GroupSnapshot]
    }
    nonisolated private struct GroupSnapshot: Codable, Sendable {
        let id: UUID
        let name: String
        let createdAt: Date
    }
    nonisolated private struct ItemSnapshot: Codable, Sendable {
        let id: UUID
        let createdAt: Date
        let sourceAppBundleID: String?
        let sourceAppName: String?
        let sourceAppTintR: Double
        let sourceAppTintG: Double
        let sourceAppTintB: Double
        let sourceAppTintA: Double
        let rtfData: Data?
        let imageFileName: String?
        let kindType: String
        let textValue: String?
        let urlValue: URL?
        let urlTitle: String?
        let fileURLs: [URL]?
        let colorHex: String?
        let groupID: UUID?

        enum CodingKeys: String, CodingKey {
            case id, createdAt, sourceAppBundleID, sourceAppName
            case sourceAppTintR, sourceAppTintG, sourceAppTintB, sourceAppTintA
            case rtfData, imageFileName, kindType
            case textValue, urlValue, urlTitle, fileURLs, colorHex
            case groupID
        }
    }

    nonisolated private enum SnapshotPayload: Sendable {
        case text(String)
        case url(URL, String?)
        case image(String)
        case file([URL])
        case color(String)
    }

    nonisolated private struct ItemSnapshotSeed: Sendable {
        let id: UUID
        let createdAt: Date
        let sourceAppBundleID: String?
        let sourceAppName: String?
        let tint: (Double, Double, Double, Double)
        let rtfData: Data?
        let payload: SnapshotPayload
        let groupID: UUID?
    }

    /// 主线程只读取 actor 隔离字段并生成 Sendable seed；DTO 数组分配与组装
    /// 在 saveQueue 完成，避免历史接近上限时在 UI actor 做完整快照构建。
    private func snapshotSeeds() -> (items: [ItemSnapshotSeed], groups: [GroupSnapshot]) {
        let seeds = items.map { item -> ItemSnapshotSeed in
            let srgb = item.sourceAppTint.usingColorSpace(.sRGB) ?? item.sourceAppTint
            let payload: SnapshotPayload
            switch item.kind {
            case .text(let s):
                payload = .text(s)
            case .url(let u, let t):
                payload = .url(u, t)
            case .image:
                payload = .image(item.imageFileURL?.lastPathComponent ?? "\(item.id.uuidString).tiff")
            case .file(let urls):
                payload = .file(urls)
            case .color(_, let hex):
                payload = .color(hex)
            }
            return ItemSnapshotSeed(
                id: item.id, createdAt: item.createdAt,
                sourceAppBundleID: item.sourceAppBundleID,
                sourceAppName: item.sourceAppName,
                tint: (Double(srgb.redComponent), Double(srgb.greenComponent),
                       Double(srgb.blueComponent), Double(srgb.alphaComponent)),
                rtfData: item.rtfData,
                payload: payload,
                groupID: item.groupID
            )
        }
        let groupSnapshots = groups.map { GroupSnapshot(id: $0.id, name: $0.name, createdAt: $0.createdAt) }
        return (seeds, groupSnapshots)
    }

    nonisolated private static func buildSnapshot(
        seeds: [ItemSnapshotSeed], groups: [GroupSnapshot]
    ) -> ClipboardHistorySnapshot {
        let snapshots = seeds.map { seed -> ItemSnapshot in
            var imageFileName: String?
            var kindType = ""
            var textValue: String?
            var urlValue: URL?
            var urlTitle: String?
            var fileURLs: [URL]?
            var colorHex: String?
            switch seed.payload {
            case .text(let value): kindType = "text"; textValue = value
            case .url(let url, let title): kindType = "url"; urlValue = url; urlTitle = title
            case .image(let name): kindType = "image"; imageFileName = name
            case .file(let urls): kindType = "file"; fileURLs = urls
            case .color(let hex): kindType = "color"; colorHex = hex
            }
            return ItemSnapshot(
                id: seed.id, createdAt: seed.createdAt,
                sourceAppBundleID: seed.sourceAppBundleID, sourceAppName: seed.sourceAppName,
                sourceAppTintR: seed.tint.0, sourceAppTintG: seed.tint.1,
                sourceAppTintB: seed.tint.2, sourceAppTintA: seed.tint.3,
                rtfData: seed.rtfData, imageFileName: imageFileName, kindType: kindType,
                textValue: textValue, urlValue: urlValue, urlTitle: urlTitle,
                fileURLs: fileURLs, colorHex: colorHex, groupID: seed.groupID
            )
        }
        return ClipboardHistorySnapshot(schemaVersion: currentSchemaVersion,
                                        items: snapshots, groups: groups)
    }

    /// Keep clipboard history bounded even when the user raises the item count
    /// to 1000. Images retain their original TIFF data, so a count-only limit
    /// is insufficient to protect the process from memory pressure.
    private static let maximumImagePayloadBytes = 20 * 1024 * 1024
    /// 文本条目单条大小上限：防止用户复制超大文本（如导出的 JSON、日志全选）
    /// 导致内存尖峰 + JSON 编码耗时（主线程）+ 搜索过滤卡顿。与图片上限对称。
    private static let maximumTextPayloadBytes = 5 * 1024 * 1024
    private static var maximumHistoryPayloadBytes: Int {
        ImageMemoryBudget.adjusted(ImageMemoryBudget.clipboardHistoryBytes)
    }
    /// 热数据阈值：3 天内的 image 条目在启动时加载 data/thumbnail 到内存；
    /// 超过 3 天的 image 条目仅加载元数据，访问时通过 warmUp() 从磁盘恢复。
    private static let hotDataCutoff: TimeInterval = 3 * 24 * 60 * 60
    /// Full directory scans recover orphaned image files left by crashes. They
    /// are intentionally infrequent because normal deletions use the explicit
    /// `pendingImageDeletions` set and do not need to enumerate the directory.
    private static let orphanImageCleanupInterval: TimeInterval = 6 * 60 * 60
    nonisolated private static let sensitiveBundleIDFragments = [
        "1password", "bitwarden", "lastpass", "dashlane", "keepass",
        "enpass", "protonpass", "nordpass", "keepersecurity"
    ]
    /// 密码管理器等写入剪贴板时附带的"不应被记录"约定标记（1Password 等
    /// 均遵守）。比 bundleID 黑名单更可靠：浏览器自动填充复制的密码来源
    /// 是浏览器本身，黑名单无法覆盖，但约定标记会随内容一起写入。
    /// - `org.nspasteboard.ConcealedType`：社区标准"隐藏内容"标记，1Password/
    ///   Bitwarden 等写入密码时设置，Safari 从密码输入框复制时也会设置。
    /// - `org.nspasteboard.TransientType`：临时内容（如 KeePassXC 的"清除后 N 秒"）。
    /// - `com.agilebits.onepassword`：1Password 旧版专属标记。
    /// - `com.apple.security.passwords`：Apple 密码管理器 / Safari 密码字段复制
    ///   时设置的标记（macOS 14+）。覆盖 Safari 自动填充密码复制的场景。
    nonisolated private static let sensitivePasteboardMarkers: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword"),
        NSPasteboard.PasteboardType("com.apple.security.passwords")
    ]
    /// 已知浏览器 bundleID，用于启发式密码检测：浏览器自动填充的密码
    /// 复制时通常不设置 ConcealedType（仅 Safari 在 macOS 14+ 设置
    /// com.apple.security.passwords）。Chrome/Firefox/Edge 等浏览器从
    /// 自动填充字段复制密码时无任何标记，需启发式检测。
    /// 检测条件（全部满足才跳过）：
    /// 1. 来源 app 是已知浏览器
    /// 2. 剪贴板仅含 string 类型（无 URL/file/image，排除正常文本复制）
    /// 3. 字符串无空格（密码通常无空格，正常句子含空格）
    /// 4. 长度 6-64（密码长度范围）
    /// 5. 含字母且含数字/符号（排除纯数字/纯字母的普通词）
    /// 此启发式有误报可能（跳过符合条件的正常文本复制），但安全优先——
    /// 误报代价是用户需重新复制，漏报代价是密码被明文持久化到磁盘。
    nonisolated private static let browserBundleIDs: Set<String> = [
        "com.apple.safari",         // Safari
        "com.google.chrome",        // Chrome
        "org.mozilla.firefox",      // Firefox
        "com.microsoft.edgemac",    // Edge
        "company.thebrowser.brave", // Brave
        "com.brave.Browser",       // Brave (旧 ID)
        "com.operasoftware.Opera"   // Opera
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
    /// 防御性编程：极端沙盒/容器环境下 urls 可能返回空数组，回退到临时目录。
    private static var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("EasyMacTool/Clipboard", isDirectory: true)
    }
    private static var metadataURL: URL {
        storageDirectory.appendingPathComponent("metadata.json", isDirectory: false)
    }
    private static var imagesDirectoryURL: URL {
        storageDirectory.appendingPathComponent("images", isDirectory: true)
    }

    @Published private(set) var items: [ClipboardItem] = [] {
        didSet { itemsStamp &+= 1 }
    }
    @Published private(set) var isCapturing = true
    /// Whether history crosses the process boundary. Disabled mode keeps the
    /// current session in memory but removes existing disk history.
    private(set) var persistentHistoryEnabled = true
    /// 历史数据是否已从磁盘加载完成。loadFromDisk 是异步的，初次打开剪切板
    /// 面板时可能尚未加载完——视图据此显示加载态而非误判为空历史。
    @Published private(set) var isLoaded = false
    /// 剪贴板分组（v2）。条目通过 `ClipboardItem.groupID` 归属到某一分组。
    @Published private(set) var groups: [ClipboardGroup] = []
    /// 数据代次：items 每次变化 +1。供搜索过滤结果缓存判定失效（避免 1000 条
    /// 历史在每次击键时全量重扫）。
    private var itemsStamp = 0
    /// 只读暴露给视图层做结果级缓存。
    var dataStamp: Int { itemsStamp }

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
    /// app 活跃状态：面板打开时 true（0.5s 高频），关闭时 false（1.5s 低频）。
    /// 菜单栏 app 大部分时间面板关闭，默认 false 让启动即进入低频轮询，
    /// 降低常驻期间的 CPU 唤醒。由 setActivePolling() 在面板开关时切换。
    private var isActive = false
    private static let activePollInterval: TimeInterval = 0.5
    private static let inactivePollInterval: TimeInterval = 1.5
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
    /// 串行后台读取队列：所有 pasteboard 读取在此执行，避免 pasteboard server
    /// 阻塞（如密码提示弹窗）时冻结主线程/UI/事件。与 saveQueue 分开，读不等待写。
    private let readQueue = DispatchQueue(label: "com.easymactool.clipboardRead")
    /// 同一时刻只允许一个读取在途（pasteboard server 卡住时不堆积并发读）。
    private var captureInFlight = false
    /// 读取期间观察到的新 changeCount。只保留最新值，因为 pasteboard 本身只
    /// 暴露当前内容；旧的中间值在下一次 poll 前已不可恢复。
    private var pendingCaptureChangeCount: Int?
    /// 读取代次：每次派发读取 +1，后台读取完成后用 generation 校验是否过期，
    /// 过期读取直接丢弃（避免卡住的读恢复后污染历史）。
    private var captureGeneration = 0
    /// Cancellable timeout for the current capture generation.
    private var captureTimeoutTimer: Timer?
    /// 待删除的磁盘图片文件路径集合。
    /// remove/clearHistory/removeOlderThan/trimHistoryToLimits 将待清理的
    /// imageFileURL 收集到此集合，saveToDisk 在后台 IO 时统一删除，
    /// 避免删除条目后 images/{uuid}.tiff 残留导致磁盘无限膨胀。
    private var pendingImageDeletions: Set<String> = []
    /// Updated when a cleanup is queued, preventing rapid saves from each
    /// scheduling the same full directory scan before the save queue catches up.
    private var lastOrphanImageCleanupAt: Date?
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
        // Only load history when disk persistence is enabled.
        if persistentHistoryEnabled {
            loadFromDisk()
        } else {
            isLoaded = true
        }
        rescheduleTimer()
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

    /// 根据 isActive 重建轮询定时器：活跃 0.5s / 非活跃 1.5s。
    /// 菜单栏 app 大部分时间面板关闭（非活跃），拉长间隔降低 CPU 唤醒。
    /// 由 start() 首次调用，setActivePolling() 在面板开关时调用切换频率。
    private func rescheduleTimer() {
        timer?.invalidate()
        let interval = isActive ? Self.activePollInterval : Self.inactivePollInterval
        // 用 Timer(timeInterval:repeats:block:) + RunLoop.main.add(.common) 替代
        // Timer.scheduledTimer：后者仅加入 .default 模式，NSMenu 模态会话期间
        // 不触发，导致右键菜单打开时剪贴板变更不被捕获。.common 模式确保所有
        // run loop 状态下都正常触发。同时用 [weak self] 替代 let instance = self，
        // 避免强引用循环（虽然单例下无害，但符合规范便于未来测试）。
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 更新轮询活跃状态并自适应调整频率。
    /// 由 ClipboardPanelController.present/dismiss 调用：面板打开时切到
    /// 0.5s 高频（用户正在看历史，复制后应立即出现新条目）；
    /// 面板关闭时切到 1.5s 低频（后台捕获，延迟 1.5s 检测不影响 UX）。
    /// 状态未变化时跳过重建，避免不必要的定时器抖动。
    /// 仅在 start() 已执行（timer 非空）时重建定时器；start() 前调用只
    /// 更新 isActive，start() → rescheduleTimer() 会用最新值创建定时器。
    func setActivePolling(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if timer != nil {
            rescheduleTimer()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        captureTimeoutTimer?.invalidate()
        captureTimeoutTimer = nil
        // 取消内存压力源
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        // 停止时刷新未写入的变更：取消防抖 timer，立即同步落盘。
        // saveToDiskSync 是同步实现，确保 app 退出前数据已写入磁盘
        // （之前用异步 DispatchQueue.global().async 派发，app 退出时
        // 主 run loop 停止后后台任务可能未完成就被终止，导致数据丢失）。
        saveTimer?.invalidate()
        saveTimer = nil
        if persistentHistoryEnabled {
            saveToDiskSync()
        }
    }

    /// 同步保存版本：用于 app 退出时的强制 flush。
    /// 在主线程完成 JSON 编码后，通过 saveQueue.sync 同步写入磁盘。
    /// sync 会等待所有 pending 的异步 saveToDisk 完成，再执行自己的写入，
    /// 避免旧异步 Task 覆盖最新数据。牺牲几十毫秒的主线程时间换取数据安全。
    private func saveToDiskSync() {
        guard persistentHistoryEnabled, Self.storageIsAvailable else { return }
        let dir = Self.storageDirectory
        let imgDir = Self.imagesDirectoryURL
        let metaURL = Self.metadataURL
        var imagesToWrite: [(URL, Data)] = []
        for item in items {
            guard case .image(let data, _) = item.kind, let data else { continue }
            if item.imageFileURL == nil {
                item.imageFileURL = imgDir.appendingPathComponent("\(item.id.uuidString).tiff")
            }
            guard let url = item.imageFileURL else { continue }
            imagesToWrite.append((url, data))
        }
        let deletions = pendingImageDeletions
        pendingImageDeletions.removeAll()
        let allItemPaths = Set(items.compactMap { $0.imageFileURL?.path })
        let seeds = snapshotSeeds()
        // sync 派发：等待所有 pending 异步保存完成后再执行，确保最终写入的是最新数据。
        // encode 在 saveQueue 后台核执行，主线程仅等待，不占用主线程 CPU 编码。
        var restoreDeletions = false
        saveQueue.sync {
            let snapshot = Self.buildSnapshot(seeds: seeds.items, groups: seeds.groups)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let jsonData = try? encoder.encode(snapshot),
                  let encryptedMetadata = ClipboardStorageCrypto.seal(jsonData) else {
                Self.logger.error("[ClipboardManager] JSON encode failed (sync)")
                restoreDeletions = true
                return
            }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
                // 收紧权限：剪贴板历史属敏感数据，目录 0700、文件 0600，
                // 避免同机其他用户/进程读取明文历史。
                Self.applyProtectivePermissions(directory: dir, imagesDirectory: imgDir)
                for (url, data) in imagesToWrite where !FileManager.default.fileExists(atPath: url.path) {
                    // .atomic：写临时文件后 rename，进程中途被杀不会留下
                    // 半截 TIFF（否则 warmUp 静默失败，图片条目永久空白）。
                    guard let encrypted = ClipboardStorageCrypto.seal(data) else {
                        throw NSError(domain: "EasyMacTool.ClipboardCrypto", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Unable to encrypt image history"])
                    }
                    try encrypted.write(to: url, options: .atomic)
                    // TIFF 文件同样收紧为 0600，与 metadata.json 保持一致
                    //（.atomic 写入继承 umask 通常为 0644，纵深防御补齐）。
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                           ofItemAtPath: url.path)
                }
                try encryptedMetadata.write(to: metaURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: metaURL.path)
                // 清理已删除条目对应的磁盘图片文件
                for path in deletions {
                    try? FileManager.default.removeItem(atPath: path)
                }
                if let enumerator = FileManager.default.enumerator(atPath: imgDir.path) {
                    for case let fileName as String in enumerator where fileName.hasSuffix(".tiff") {
                        let path = imgDir.appendingPathComponent(fileName).path
                        if !allItemPaths.contains(path) { try? FileManager.default.removeItem(atPath: path) }
                    }
                }
            } catch {
                Self.logger.error("[ClipboardManager] Save failed (sync): \(error.localizedDescription, privacy: .public)")
                // 删除清单回集合：本轮清理失败，待下轮保存重试，
                // 避免 images/ 目录因清单丢失而缓慢膨胀。用本地 flag，
                // sync 闭包外（@MainActor）恢复，避免跨 actor 访问。
                restoreDeletions = true
            }
        }
        if restoreDeletions {
            pendingImageDeletions.formUnion(deletions)
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
        pendingCaptureChangeCount = nil
        captureTimeoutTimer?.invalidate()
        captureTimeoutTimer = nil
        captureGeneration &+= 1
        captureInFlight = false
    }

    /// Disabling persistence removes old on-disk history while retaining the
    /// current in-memory session. New writes are skipped until re-enabled.
    func setPersistentHistoryEnabled(_ enabled: Bool) {
        guard persistentHistoryEnabled != enabled else { return }
        persistentHistoryEnabled = enabled
        if enabled {
            schedulePersist()
            return
        }
        saveTimer?.invalidate()
        saveTimer = nil
        pendingImageDeletions.removeAll()
        let directory = Self.storageDirectory
        saveQueue.async {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Re-pastes the given item: writes it to the pasteboard and (optionally)
    /// simulates Cmd+V into the previously frontmost app.
    ///
    /// 冷数据图片（>3天）需先异步 warmUp 从磁盘加载 TIFF Data，避免
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
    func reapply(_ item: ClipboardItem, autoPaste: Bool, expectedAppBundleID: String? = nil) {
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
            item.write(to: .general)
            suppressUntilChangeCount = NSPasteboard.general.changeCount
            // Move the item to the top so it's most-recently-used.
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                let moved = items[idx]
                moveToFront(moved)
            }
            schedulePersist()
            if autoPaste {
                // 用 Task.sleep 代替 DispatchQueue.main.asyncAfter，
                // 这样 Task.cancel 能取消未执行的 simulatePaste。
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                guard !Task.isCancelled, token == reapplyToken else { return }
                self.simulatePaste(expectedAppBundleID: expectedAppBundleID)
            }
        }
    }

    /// 纯文本粘贴：只写回 `string` 纯文本（剥掉 RTF/富文本/颜色格式），再走
    /// simulatePaste。适用于文本/链接/颜色；图片/文件无纯文本形式，回退到
    /// 普通 reapply。粘贴后剪贴板仅含纯文本（不还原原格式）。
    func reapplyPlain(_ item: ClipboardItem, autoPaste: Bool, expectedAppBundleID: String? = nil) {
        guard let plain = Self.plainText(for: item) else {
            reapply(item, autoPaste: autoPaste, expectedAppBundleID: expectedAppBundleID)
            return
        }
        let token = UUID()
        reapplyToken = token
        currentReapplyTask?.cancel()
        currentReapplyTask = Task {
            guard !Task.isCancelled, token == reapplyToken else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(plain, forType: .string)
            suppressUntilChangeCount = NSPasteboard.general.changeCount
            // Move the item to the top so it's most-recently-used.
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                let moved = items[idx]
                moveToFront(moved)
            }
            schedulePersist()
            if autoPaste {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, token == reapplyToken else { return }
                self.simulatePaste(expectedAppBundleID: expectedAppBundleID)
            }
        }
    }

    /// 返回条目的纯文本形式；图片/文件无纯文本形式返回 nil。
    private static func plainText(for item: ClipboardItem) -> String? {
        switch item.kind {
        case .text(let s): return s
        case .url(let url, _): return url.absoluteString
        case .color(_, let hex): return hex
        case .image, .file: return nil
        }
    }

    /// 把条目移到列表最前（MRU 语义）。分组不改变排序，仅用于 filter 过滤。
    private func moveToFront(_ item: ClipboardItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let moved = items.remove(at: idx)
        items.insert(moved, at: 0)
    }

    // MARK: - 分组

    /// 新建分组并返回其 id。名称已去空白。颜色从色板中随机挑选一个
    /// 尚未被现有分组占用的索引，保证各分组颜色互不相同；色板用尽时
    /// 回退到随机（允许重复）。
    @discardableResult
    func createGroup(name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let used = Set(groups.map { $0.colorIndex % ClipboardGroupPalette.count })
        var candidates = (0..<ClipboardGroupPalette.count).filter { !used.contains($0) }
        if candidates.isEmpty {
            candidates = Array(0..<ClipboardGroupPalette.count)
        }
        let colorIndex = candidates.randomElement() ?? 0
        let group = ClipboardGroup(name: trimmed.isEmpty ? "未命名分组" : trimmed,
                                   colorIndex: colorIndex)
        groups.append(group)
        schedulePersist()
        return group.id
    }

    func renameGroup(_ id: UUID, name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groups[idx].name = trimmed
        schedulePersist()
    }

    /// 删除分组：连同该分组下的条目一并删除（含其磁盘图片文件）。
    func deleteGroup(_ id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        groups.removeAll { $0.id == id }
        // 收集被删除条目的 image 磁盘文件路径，待 saveToDisk 时清理。
        for item in items where item.groupID == id {
            if let path = item.imageFileURL?.path {
                pendingImageDeletions.insert(path)
            }
        }
        // 移除该分组下所有条目。数组变化触发 didSet → itemsStamp+1，自动失效
        // filtered 缓存，无需手动递增。
        items.removeAll { $0.groupID == id }
        schedulePersist()
    }

    /// 把条目加入/移出分组（nil = 移出 → 回到「全部」）。
    func assign(_ item: ClipboardItem, toGroup groupID: UUID?) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        guard item.groupID != groupID else { return }
        item.groupID = groupID
        // item 是引用类型，items 数组本身不变，didSet 不触发——手动递增
        // 数据代次以失效 filtered 缓存，否则分组归属变化后 UI 不刷新。
        itemsStamp &+= 1
        schedulePersist()
    }

    func group(for id: UUID) -> ClipboardGroup? {
        groups.first { $0.id == id }
    }

    /// 当前多选（Cmd 点击）的条目 ID 集合。非空时面板显示「复制全部/清除」。
    @Published private(set) var batchSelectionIDs: Set<UUID> = []
    /// shift 区间选的锚点（最近一次 toggle 选中的最后一项的 index）。
    private var batchAnchorIndex: Int?

    func isBatchSelected(_ item: ClipboardItem) -> Bool {
        batchSelectionIDs.contains(item.id)
    }

    /// Cmd 点击切换多选。
    func toggleBatchSelection(_ item: ClipboardItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            batchAnchorIndex = idx
        }
        if batchSelectionIDs.contains(item.id) {
            batchSelectionIDs.remove(item.id)
        } else {
            batchSelectionIDs.insert(item.id)
        }
    }

    /// Finder 式 shift 区间选：选中从锚点到目标项之间的所有条目。
    func extendBatchSelection(to item: ClipboardItem) {
        guard let targetIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        let anchorIndex = batchAnchorIndex ?? targetIndex
        let lo = min(anchorIndex, targetIndex)
        let hi = max(anchorIndex, targetIndex)
        if lo >= 0, hi < items.count {
            for i in lo...hi { batchSelectionIDs.insert(items[i].id) }
        }
        batchAnchorIndex = targetIndex
    }

    func clearBatchSelection() {
        batchSelectionIDs.removeAll()
        batchAnchorIndex = nil
    }

    /// 当前选中的条目（按 items 顺序）。
    func selectedBatchItems() -> [ClipboardItem] {
        items.filter { batchSelectionIDs.contains($0.id) }
    }

    /// 批量复制/粘贴：全文件 → 写入文件；否则 → 富文本（文本合并 + 图片附件）。
    func reapplyBatch(autoPaste: Bool, expectedAppBundleID: String? = nil) {
        let selected = selectedBatchItems()
        guard !selected.isEmpty else { return }
        let token = UUID()
        reapplyToken = token
        currentReapplyTask?.cancel()
        currentReapplyTask = Task {
            guard !Task.isCancelled, token == reapplyToken else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            let allFiles = selected.allSatisfy { if case .file = $0.kind { return true } else { return false } }
            if allFiles {
                let urls = selected.flatMap { item -> [URL] in
                    if case .file(let u) = item.kind { return u } else { return [] }
                }
                pb.writeObjects(urls as [NSPasteboardWriting])
            } else {
                let rich = Self.batchAttributedString(selected)
                pb.writeObjects([rich])
                let plain = Self.batchPlainText(selected)
                if !plain.isEmpty { pb.setString(plain, forType: .string) }
            }
            suppressUntilChangeCount = NSPasteboard.general.changeCount
            // 把选中项移到最前（保持顺序 reversed 以避免索引漂移）。
            for item in selected.reversed() {
                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    moveToFront(items[idx])
                }
            }
            schedulePersist()
            if autoPaste {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, token == reapplyToken else { return }
                self.simulatePaste(expectedAppBundleID: expectedAppBundleID)
            }
        }
    }

    /// 批量纯文本：文本/链接/颜色用其字符串，文件用路径，图片跳过。
    private static func batchPlainText(_ items: [ClipboardItem]) -> String {
        items.compactMap { item -> String? in
            if case .file(let urls) = item.kind {
                return urls.map(\.path).joined(separator: "\n")
            }
            return Self.plainText(for: item)
        }.joined(separator: "\n")
    }

    /// 批量富文本：文本/链接/颜色合并为文本，图片内嵌为附件。
    private static func batchAttributedString(_ items: [ClipboardItem]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for item in items {
            if case .image = item.kind {
                if let img = item.fullImage {
                    let attach = NSTextAttachment()
                    attach.image = img
                    result.append(NSAttributedString(attachment: attach))
                    result.append(NSAttributedString(string: "\n"))
                }
            } else if let text = Self.plainText(for: item) {
                result.append(NSAttributedString(string: text + "\n"))
            } else if case .file(let urls) = item.kind {
                result.append(NSAttributedString(string: urls.map(\.path).joined(separator: "\n") + "\n"))
            }
        }
        return result
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
        let current = NSPasteboard.general.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard isCapturing else { return }

        // 精确抑制：只抑制 reapply write 引起的 changeCount 变化。
        if let suppress = suppressUntilChangeCount, current == suppress {
            suppressUntilChangeCount = nil
            return
        }
        suppressUntilChangeCount = nil

        pendingCaptureChangeCount = current
        startPendingCaptureIfNeeded()
    }

    private func startPendingCaptureIfNeeded() {
        guard isCapturing, !captureInFlight,
              let requestedChangeCount = pendingCaptureChangeCount else { return }
        pendingCaptureChangeCount = nil
        captureInFlight = true
        captureGeneration &+= 1
        let generation = captureGeneration

        // 真正的 pasteboard 读取（可能阻塞）在后台串行队列执行，
        // 主线程只做 changeCount 判断与最终的 ClipboardItem 构建。
        // Snapshot settings on the main actor before crossing to the read queue.
        // The background closure then captures only Sendable value types.
        let ignoredApps = Set(AppSettings.shared.ignoredClipboardApps)
        let sourceApp = captureSourceApp()
        readQueue.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.scheduleCaptureTimeout(generation: generation,
                                             changeCount: requestedChangeCount)
            }
            let content = Self.readContent(ignoredApps: ignoredApps, sourceApp: sourceApp)
            DispatchQueue.main.async {
                guard let self, self.captureGeneration == generation else { return }
                self.captureTimeoutTimer?.invalidate()
                self.captureTimeoutTimer = nil
                self.captureInFlight = false
                guard self.isCapturing else { return }

                let latestChangeCount = NSPasteboard.general.changeCount
                if latestChangeCount != requestedChangeCount {
                    self.lastChangeCount = latestChangeCount
                    if self.suppressUntilChangeCount == latestChangeCount {
                        self.suppressUntilChangeCount = nil
                    } else {
                        self.pendingCaptureChangeCount = latestChangeCount
                    }
                } else if let content, let item = self.makeItem(from: content) {
                    self.ingest(item)
                }
                self.startPendingCaptureIfNeeded()
            }
        }
    }

    /// 后台读取在途超过 5s（pasteboard server 卡住）时释放 inFlight 标志，
    /// 让后续 poll 能继续派发新读取；卡住的旧读被 generation token 丢弃。
    private func scheduleCaptureTimeout(generation: Int, changeCount: Int) {
        captureTimeoutTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.captureGeneration == generation,
                      self.captureInFlight else { return }
                self.captureTimeoutTimer = nil
                self.captureInFlight = false
                self.captureGeneration &+= 1
                let latest = NSPasteboard.general.changeCount
                self.lastChangeCount = latest
                self.pendingCaptureChangeCount = latest == changeCount ? changeCount : latest
                self.startPendingCaptureIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureTimeoutTimer = timer
    }

    /// 在后台队列读取剪贴板原始内容。返回 nil 表示应跳过（无内容/敏感标记/
    /// 疑似密码/敏感来源）。只做 pasteboard 读取与轻量分类，不构造 @MainActor
    /// 的 ClipboardItem——pasteboard server 阻塞时不会冻结主线程。
    nonisolated private static func readContent(ignoredApps: Set<String>,
                                                sourceApp: CapturedSourceApp) -> CapturedContent? {
        let pb = NSPasteboard.general
        guard let types = pb.types, !types.isEmpty else { return nil }
        // 遵守 concealed/transient 约定：密码管理器等写入剪贴板时附带的标记。
        if types.contains(where: { Self.sensitivePasteboardMarkers.contains($0) }) { return nil }
        let hasURL = types.contains(.URL)
        let hasString = types.contains(.string)
        let hasTIFF = types.contains(.tiff)
        let hasFileURL = types.contains(.fileURL)
        guard hasURL || hasString || hasTIFF || hasFileURL else { return nil }

        let name = sourceApp.name
        let bundleID = sourceApp.bundleID

        // 浏览器密码启发式检测：Chrome/Firefox/Edge 等从自动填充字段复制密码
        // 时不设置标记。误报代价低于漏报（密码被明文持久化）。
        if hasString && !hasURL && !hasTIFF && !hasFileURL,
           let sourceBundleID = bundleID,
           Self.browserBundleIDs.contains(sourceBundleID) {
            let candidate = pb.string(forType: .string) ?? ""
            if Self.looksLikePassword(candidate) { return nil }
        }
        // 敏感来源 bundleID 黑名单。
        if Self.isSensitiveSource(bundleID: bundleID) { return nil }
        // 用户配置的「忽略来源 app」列表。
        if let bundleID = bundleID, ignoredApps.contains(bundleID) { return nil }

        // 读取各类型原始内容，主线程按 文件>图片>URL>文本 优先级构建 item。
        let fileURLs: [URL]? = hasFileURL
            ? (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])
            : nil
        let tiffData: Data? = hasTIFF ? pb.data(forType: .tiff) : nil
        let urlTypeString: String? = hasURL ? pb.string(forType: .URL) : nil
        let plainString: String? = hasString ? pb.string(forType: .string) : nil
        let rtfData: Data? = (hasString && pb.availableType(from: [.rtf]) != nil)
            ? pb.data(forType: .rtf) : nil
        return CapturedContent(fileURLs: fileURLs,
                               tiffData: tiffData,
                               urlTypeString: urlTypeString,
                               plainString: plainString,
                               rtfData: rtfData,
                               sourceName: name,
                               sourceAppBundleID: bundleID,
                               tintR: sourceApp.tintR,
                               tintG: sourceApp.tintG,
                               tintB: sourceApp.tintB,
                               tintA: sourceApp.tintA)
    }

    private func captureSourceApp() -> CapturedSourceApp {
        let frontmost = NSWorkspace.shared.frontmostApplication
        var tint = NSColor(red: 0x0A/255.0, green: 0x84/255.0, blue: 0xFF/255.0, alpha: 1.0)
        if let app = frontmost, let appIcon = app.icon {
            tint = AppTintExtractor.tint(from: appIcon, bundleIdentifier: app.bundleIdentifier)
        }
        let srgb = tint.usingColorSpace(.sRGB) ?? tint
        return CapturedSourceApp(name: frontmost?.localizedName,
                                 bundleID: frontmost?.bundleIdentifier,
                                 tintR: Double(srgb.redComponent),
                                 tintG: Double(srgb.greenComponent),
                                 tintB: Double(srgb.blueComponent),
                                 tintA: Double(srgb.alphaComponent))
    }

    /// 主线程根据后台读取的 CapturedContent 构建 ClipboardItem（优先级：
    /// 文件 > 图片 > URL > 文本（含颜色/URL 启发式））。语义与旧 snapshot() 一致。
    private func makeItem(from content: CapturedContent) -> ClipboardItem? {
        let tint = NSColor(red: CGFloat(content.tintR),
                           green: CGFloat(content.tintG),
                           blue: CGFloat(content.tintB),
                           alpha: CGFloat(content.tintA))
        // 文件（必须全部是 file URL，避免网页链接被误判为文件）。
        if let urls = content.fileURLs, !urls.isEmpty, urls.allSatisfy({ $0.isFileURL }) {
            return ClipboardItem(kind: .file(URLs: urls),
                                 sourceAppBundleID: content.sourceAppBundleID,
                                 sourceAppName: content.sourceName,
                                 sourceAppTint: tint)
        }
        // 图片（缩略图生成失败则继续往下尝试 URL/文本）。
        if let tiff = content.tiffData, tiff.count <= Self.maximumImagePayloadBytes,
           let thumbnail = ClipboardItem.makeThumbnail(from: tiff, max: 256) {
            if let bundleID = content.sourceAppBundleID,
               let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
               let appIcon = app.icon {
                AppIconCache.prewarm(appIcon, for: bundleID)
            }
            let item = ClipboardItem(kind: .image(tiff, thumbnail: thumbnail),
                                     sourceAppBundleID: content.sourceAppBundleID,
                                     sourceAppName: content.sourceName,
                                     sourceAppTint: tint)
            item.imageFileURL = Self.imagesDirectoryURL.appendingPathComponent("\(item.id.uuidString).tiff")
            item.imagePixelSize = ClipboardItem.readPixelSize(from: tiff)
            return item
        }
        // URL（带 string 伴生）。
        if let urlStr = content.urlTypeString, let url = URL(string: urlStr) {
            return ClipboardItem(kind: .url(url, title: url.host),
                                 sourceAppBundleID: content.sourceAppBundleID,
                                 sourceAppName: content.sourceName,
                                 sourceAppTint: tint)
        }
        // 文本（含颜色/URL 启发式）。
        if let text = content.plainString {
            if let (color, hex) = ColorStringParser.parse(text) {
                return ClipboardItem(kind: .color(color, hex: hex),
                                     sourceAppBundleID: content.sourceAppBundleID,
                                     sourceAppName: content.sourceName,
                                     sourceAppTint: tint)
            }
            if let url = URL(string: text),
               let scheme = url.scheme,
               scheme == "http" || scheme == "https" {
                return ClipboardItem(kind: .url(url, title: url.host),
                                     sourceAppBundleID: content.sourceAppBundleID,
                                     sourceAppName: content.sourceName,
                                     sourceAppTint: tint)
            }
            guard text.utf8.count <= Self.maximumTextPayloadBytes else { return nil }
            return ClipboardItem(kind: .text(text),
                                 sourceAppBundleID: content.sourceAppBundleID,
                                 sourceAppName: content.sourceName,
                                 sourceAppTint: tint,
                                 rtfData: content.rtfData)
        }
        return nil
    }

    /// 去重 + 插入 + 裁剪 + 落盘（主线程）。与旧 poll 尾部逻辑一致。
    private func ingest(_ item: ClipboardItem) {
        // 去重：遍历全部历史，若已有相同 payload 的条目把旧条目移到所属分组最前。
        if let existingIndex = items.firstIndex(where: { isSamePayload($0, item) }) {
            let existing = items[existingIndex]
            moveToFront(existing)
            schedulePersist()
            return
        }
        items.insert(item, at: 0)
        trimHistoryToLimits()
        schedulePersist()
    }

    /// 后台读取的剪贴板原始内容（Sendable）：主线程据此构建 ClipboardItem。
    /// 只携带原始数据与来源元数据，pasteboard 读取完全在后台队列完成。
    nonisolated private struct CapturedContent: Sendable {
        let fileURLs: [URL]?
        let tiffData: Data?
        let urlTypeString: String?
        let plainString: String?
        let rtfData: Data?
        let sourceName: String?
        let sourceAppBundleID: String?
        let tintR: Double
        let tintG: Double
        let tintB: Double
        let tintA: Double
    }

    nonisolated private struct CapturedSourceApp: Sendable {
        let name: String?
        let bundleID: String?
        let tintR: Double
        let tintG: Double
        let tintB: Double
        let tintA: Double
    }

    private func trimHistoryToLimits() {
        // 增量维护 totalBytes：之前每次循环迭代都全量 reduce 重算字节数，
        // 当历史接近 150MB 上限需移除多条时复杂度退化为 O(n²)。
        // 现在循环外计算一次，每次移除时减去对应字节数，整体 O(n)。
        let keepCount = ClipboardHistoryPolicy.retainedPrefixCount(
            costs: items.map(\.estimatedMemoryBytes),
            itemLimit: historyLimit,
            byteLimit: Self.maximumHistoryPayloadBytes
        )
        while items.count > keepCount {
            let removed = items.removeLast()
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
        guard persistentHistoryEnabled else { return }
        saveTimer?.invalidate()
        // 同 rescheduleTimer：用 .common 模式避免 NSMenu 模态期间保存停滞。
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.saveToDisk() }
        }
        RunLoop.main.add(t, forMode: .common)
        saveTimer = t
    }

    /// 将剪贴板历史持久化到磁盘。
    /// - 元数据写入 metadata.json（JSON 编码，image data 不包含在其中）
    /// - 图片 TIFF Data 写入 images/\(id).tiff 独立文件
    /// - 清理已删除条目对应的磁盘图片文件（pendingImageDeletions）
    /// 文件 I/O 在后台队列执行，避免阻塞主线程。
    private func saveToDisk() {
        guard persistentHistoryEnabled, Self.storageIsAvailable else { return }
        let dir = Self.storageDirectory
        let imgDir = Self.imagesDirectoryURL
        let metaURL = Self.metadataURL
        // 主线程构建快照 DTO + 收集待写图片（@MainActor 访问 ClipboardItem）。
        // encode 移到 saveQueue 后台执行，避免 1000 条历史的主线程编码卡顿。
        var imagesToWrite: [(URL, Data)] = []
        for item in items {
            guard case .image(let data, _) = item.kind, let data else { continue }
            if item.imageFileURL == nil {
                item.imageFileURL = imgDir.appendingPathComponent("\(item.id.uuidString).tiff")
            }
            guard let url = item.imageFileURL else { continue }
            imagesToWrite.append((url, data))
        }
        // Explicit deletions cover normal operation. A throttled full scan also
        // recovers files orphaned by a crash without enumerating images/ on
        // every clipboard change. `nil` makes the first save after launch scan.
        let cleanupScheduledAt = Date()
        let shouldCleanOrphans = lastOrphanImageCleanupAt.map {
            cleanupScheduledAt.timeIntervalSince($0) >= Self.orphanImageCleanupInterval
        } ?? true
        if shouldCleanOrphans {
            lastOrphanImageCleanupAt = cleanupScheduledAt
        }
        let allItemPaths = shouldCleanOrphans
            ? Set(items.compactMap { $0.imageFileURL?.path })
            : []
        let imageWrites = imagesToWrite
        let deletions = pendingImageDeletions
        pendingImageDeletions.removeAll()
        let seeds = snapshotSeeds()
        // 文件 I/O + JSON 编码在串行保存队列执行，避免与 saveToDiskSync 并发写 metadata.json
        saveQueue.async {
            let snapshot = Self.buildSnapshot(seeds: seeds.items, groups: seeds.groups)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let jsonData = try? encoder.encode(snapshot),
                  let encryptedMetadata = ClipboardStorageCrypto.seal(jsonData) else {
                Self.logger.error("[ClipboardManager] JSON encode failed")
                Task { @MainActor in self.pendingImageDeletions.formUnion(deletions) }
                return
            }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
                Self.applyProtectivePermissions(directory: dir, imagesDirectory: imgDir)
                // 写入图片文件（.atomic：避免进程被杀留下半截 TIFF）。
                for (url, data) in imageWrites where !FileManager.default.fileExists(atPath: url.path) {
                    guard let encrypted = ClipboardStorageCrypto.seal(data) else {
                        throw NSError(domain: "EasyMacTool.ClipboardCrypto", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Unable to encrypt image history"])
                    }
                    try encrypted.write(to: url, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                           ofItemAtPath: url.path)
                }
                // 写入元数据 JSON
                try encryptedMetadata.write(to: metaURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: metaURL.path)
                // 清理已删除条目对应的磁盘图片文件
                for path in deletions {
                    try? FileManager.default.removeItem(atPath: path)
                }
                // Periodically recover orphaned TIFF files left by a crash or
                // force-quit. Normal saves only process the explicit deletions.
                if shouldCleanOrphans,
                   FileManager.default.fileExists(atPath: imgDir.path),
                   let enumerator = FileManager.default.enumerator(atPath: imgDir.path) {
                    for case let fileName as String in enumerator {
                        guard fileName.hasSuffix(".tiff") else { continue }
                        let fullPath = imgDir.appendingPathComponent(fileName).path
                        if !allItemPaths.contains(fullPath) {
                            try? FileManager.default.removeItem(atPath: fullPath)
                        }
                    }
                }
            } catch {
                Self.logger.error("[ClipboardManager] Save failed: \(error.localizedDescription, privacy: .public)")
                // 删除清单并回集合（回主线程修改 @MainActor 状态），
                // 待下轮保存重试，避免 images/ 目录因清单丢失而膨胀。
                Task { @MainActor in
                    self.pendingImageDeletions.formUnion(deletions)
                    if shouldCleanOrphans,
                       self.lastOrphanImageCleanupAt == cleanupScheduledAt {
                        self.lastOrphanImageCleanupAt = nil
                    }
                }
            }
        }
    }

    /// 从磁盘加载剪贴板历史。
    /// - 读取 metadata.json 解码所有条目
    /// - image 条目：设置 imageFileURL 为绝对路径
    /// - 热数据（≤3天）：异步 warmUp() 加载 data + thumbnail 到内存
    /// - 冷数据（>3天）：仅保留元数据，访问时按需 warmUp()
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
        guard persistentHistoryEnabled, Self.storageIsAvailable else {
            isLoaded = true
            return
        }
        let metaURL = Self.metadataURL
        let imgDir = Self.imagesDirectoryURL
        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            isLoaded = true
            return
        }
        // Step 1: 后台读取 JSON 文件数据（纯 Data，无 @MainActor 依赖）
        DispatchQueue.global(qos: .userInitiated).async {
            guard let fileData = ClipboardStorageCrypto.openFileOrLegacy(at: metaURL) else {
                Task { @MainActor in self.items = []; self.isLoaded = true }
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
                    // v2 分组；v1 旧文件无 groups 字段 → 空。
                    self.groups = metadata.groups ?? []
                } else if let legacy = try? decoder.decode([ClipboardItem].self, from: fileData) {
                    // v0 旧格式：裸数组，无 schemaVersion 字段，也无分组。
                    loaded = legacy
                    self.groups = []
                } else {
                    Self.logger.error("Load failed: decode error")
                    self.items = []
                    self.isLoaded = true
                    return
                }
                let hotCutoff = Date().addingTimeInterval(-Self.hotDataCutoff)
                var hotImageItems: [ClipboardItem] = []
                for item in loaded {
                    guard case .image = item.kind else { continue }
                    // 解码时 imageFileURL 存的是文件名（相对路径），解析为绝对路径
                    let fileName = item.imageFileURL?.lastPathComponent ?? "\(item.id.uuidString).tiff"
                    item.imageFileURL = imgDir.appendingPathComponent(fileName)
                    // 热数据：稍后限并发 warmUp，避免阻塞主线程。
                    // items 先设置（UI 显示占位），图片数据后台加载后自动填入。
                    if item.createdAt > hotCutoff {
                        hotImageItems.append(item)
                    }
                }
                // 合并 poll 期间新增的条目到 loaded 头部，然后一次性赋值。
                // 之前分两步（先 self.items = loaded，再逐条 insert），SwiftUI
                // 会观察到中间态导致卡片闪烁/选中错位。现在构建完整数组后
                // 单次 @Published 变更，避免中间态。
                let pendingNew = self.items
                let loadedIDs = Set(loaded.map { $0.id })
                var merged = loaded
                // pendingNew 是 poll 在 load 窗口期累积的新条目，新序在前 [C, B, A]
                // （C 最新）。逐个 insert(at: 0) 会反转顺序，必须倒序遍历才能保持
                // [C, B, A, ...loaded] 的新序在前语义。
                for item in pendingNew.reversed() where !loadedIDs.contains(item.id) {
                    merged.insert(item, at: 0)
                }
                self.items = merged
                self.isLoaded = true
                let imageURLs = loaded.compactMap(\.imageFileURL)
                self.migrateLegacyImageFiles(imageURLs)
                // 异步加载完成后立即裁剪并落盘：磁盘上的条目可能超过当前 historyLimit
                // （如用户在设置中降低了上限后重启），保证启动后内存与上限一致，
                // 同时修正磁盘 metadata.json。start() 中的同步 trim 是 no-op（此时
                // items 仍为空），真正的裁剪必须等 load 完成后在此执行。
                self.trimHistoryToLimits()
                self.schedulePersist()
                // Sequentially warm hot images. `warmUpAsync` performs file IO
                // off the main actor; sequencing caps disk and decoded-image
                // peaks and avoids passing actor-isolated ClipboardItem values
                // through a task group.
                for item in hotImageItems {
                    await item.warmUpAsync()
                }
            }
        }
    }

    /// Rewrites legacy raw TIFF payloads after a successful metadata load. The
    /// serial save queue orders this migration with normal persistence writes.
    private func migrateLegacyImageFiles(_ urls: [URL]) {
        guard persistentHistoryEnabled, !urls.isEmpty else { return }
        saveQueue.async {
            for url in urls {
                guard let data = try? Data(contentsOf: url),
                      !ClipboardStorageCrypto.isEncrypted(data),
                      let encrypted = ClipboardStorageCrypto.seal(data) else { continue }
                do {
                    try encrypted.write(to: url, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                           ofItemAtPath: url.path)
                } catch {
                    Self.logger.error("[ClipboardManager] Legacy image migration failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// 浏览器密码启发式检测：判断字符串是否像密码。
    /// 仅在来源是已知浏览器 + 剪贴板仅含 string 类型时调用。
    /// 规则（全部满足才判定为密码）：
    /// 1. 长度 6-64（密码长度范围，过短/过长排除）
    /// 2. 无空格（密码通常无空格，正常句子含空格）
    /// 3. 含字母（排除纯数字 PIN，但纯数字 PIN 通常会被 ConcealedType 标记）
    /// 4. 含数字或符号（排除纯字母的普通词）
    /// 5. 不是常见非密码文本（如 URL、邮箱、IP）
    /// 误报代价（跳过正常文本复制）低于漏报代价（密码被明文持久化）。
    nonisolated private static func looksLikePassword(_ candidate: String) -> Bool {
        let len = candidate.count
        // 长度范围：6-64（密码通常在此范围，过短/过长都不像）
        guard len >= 6, len <= 64 else { return false }
        // 无空格：密码通常无空格，含空格的多为正常句子
        if candidate.contains(" ") || candidate.contains("\t") || candidate.contains("\n") {
            return false
        }
        // 排除明显非密码的常见文本类型（避免误报）
        // 邮箱：含 @ 且 @ 后含 .
        if candidate.contains("@"), let at = candidate.firstIndex(of: "@"),
           candidate[at...].contains(".") {
            return false
        }
        // URL：以 http:// 或 https:// 开头
        if candidate.lowercased().hasPrefix("http://") || candidate.lowercased().hasPrefix("https://") {
            return false
        }
        // IP 地址：x.x.x.x 模式
        let dotCount = candidate.filter { $0 == "." }.count
        if dotCount == 3,
           candidate.split(separator: ".").allSatisfy({ Int($0) != nil }) {
            return false
        }
        // 字符分类
        let hasLetter = candidate.contains { $0.isLetter }
        let hasDigit = candidate.contains { $0.isNumber }
        let hasSymbol = candidate.contains { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
        // 密码特征：含字母 且 （含数字 或 含符号）
        // 排除纯字母的普通词、纯数字的 PIN（PIN 通常有 ConcealedType 标记）
        return hasLetter && (hasDigit || hasSymbol)
    }

    nonisolated private static func isSensitiveSource(bundleID: String?) -> Bool {
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
            // 快速通道：首尾 + 中间各 16KB 采样不等直接 false。连续复制同一张
            // 20MB 大图时全量 == 比较需上百毫秒（主线程），三段采样先排除
            // 绝大多数"不同图同大小"的情况，相等再走全量比较。
            // 中间采样覆盖首尾相同但中间不同的边缘情况（如拼接图差异在中段）。
            let sampleSize = min(16 * 1024, x.count)
            if x.prefix(sampleSize) != y.prefix(sampleSize) { return false }
            if x.suffix(sampleSize) != y.suffix(sampleSize) { return false }
            let midStart = (x.count - sampleSize) / 2
            if x[midStart..<(midStart + sampleSize)] != y[midStart..<(midStart + sampleSize)] { return false }
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
    ///
    /// 目标 app 校验：orderOut 后原 app 恢复焦点是异步的，50ms sleep 不保证
    /// 目标 app 已成为 key window。若当前前台与呼出面板前记录的 expectedAppBundleID
    /// 不一致（用户快速切窗、或焦点恢复慢），放弃模拟粘贴——pasteboard 已写入，
    /// 用户可手动 Cmd+V。避免粘贴到错误窗口泄露剪贴板内容。
    fileprivate func simulatePaste(expectedAppBundleID: String?) {
        if let expected = expectedAppBundleID {
            let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if current != expected {
                Self.logger.info("[Clipboard] simulatePaste aborted: frontmost app mismatch (expected=\(expected, privacy: .public), current=\(current ?? "nil", privacy: .public)) — pasteboard still written, user can Cmd+V manually")
                return
            }
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        // CGEvent(keyboardEventSource:) 在极端内存不足时可能返回 nil，
        // guard 防护避免隐式解包崩溃。
        guard let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
              let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) else { return }
        cmdDown.flags = .maskCommand
        cmdUp.flags = .maskCommand
        // 打上与 HotkeyManager 一致的合成事件标记，使自家 event tap 跳过这些
        // 事件，杜绝重入/误匹配（合成 Cmd+V 不会再被当作快捷键处理）。
        cmdDown.setIntegerValueField(.eventSourceUserData, value: HotkeyManager.syntheticMarker)
        cmdUp.setIntegerValueField(.eventSourceUserData, value: HotkeyManager.syntheticMarker)
        cmdDown.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
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
