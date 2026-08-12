import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import os
import ScreenCaptureKit

/// Maintains a persistent cache of the last successful preview frame per window,
/// so minimized/hidden windows can show their last-known state.
///
/// A byte-budgeted LRU cache for preview frames. A count-only cap is unsafe on
/// high-resolution displays because a single CGImage can consume many MB.
@MainActor
final class WindowPreviewCache {
    static let shared = WindowPreviewCache()
    private static let byteLimit = 96 * 1024 * 1024

    private struct Key: Hashable {
        let pid: pid_t
        let windowID: CGWindowID
    }
    private struct Entry {
        let image: CGImage
        let cost: Int
        var lastAccess: UInt64
    }

    private var cache: [Key: Entry] = [:]
    private var totalCost = 0
    private var accessCounter: UInt64 = 0
    /// 系统内存压力源：收到 .warning/.critical 时清空缓存，
    /// 释放最多 96MB 的窗口预览图内存。之前 clear() 从未被调用，
    /// 仅依赖系统回收 VM 释放，内存压力时无法及时降压。
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.clear()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    func image(for windowID: CGWindowID, pid: pid_t) -> CGImage? {
        let key = Key(pid: pid, windowID: windowID)
        guard var entry = cache[key] else { return nil }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        cache[key] = entry
        return entry.image
    }

    func store(_ image: CGImage, for windowID: CGWindowID, pid: pid_t) {
        let key = Key(pid: pid, windowID: windowID)
        if let old = cache.removeValue(forKey: key) {
            totalCost -= old.cost
        }
        let cost = image.bytesPerRow * image.height
        // An individual frame larger than the full budget is not cached; it
        // remains available in the current overlay but cannot bloat idle memory.
        guard cost <= Self.byteLimit else { return }
        while totalCost + cost > Self.byteLimit,
              let leastRecent = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            totalCost -= leastRecent.value.cost
            cache.removeValue(forKey: leastRecent.key)
        }
        accessCounter &+= 1
        cache[key] = Entry(image: image, cost: cost, lastAccess: accessCounter)
        totalCost += cost
    }

    func clear() {
        cache.removeAll()
        totalCost = 0
    }
}

/// Manages window previews. Strategy for performance:
/// 1. On switcher open: capture static snapshots for ALL windows (one-time).
/// 2. Only the selected/hovered window gets a live SCStream.
/// 3. When selection changes, stop the old stream and start a new one for the
///    newly selected window.
@MainActor
final class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private var streams: [CGWindowID: SCStream] = [:]
    private var itemForStream: [ObjectIdentifier: WindowItem] = [:]
    // nonisolated(unsafe)：CIContext 本身线程安全，但需要从 nonisolated 的
    // stream(_:didOutputSampleBuffer:of:) 回调中访问。与 lastFrameTime 同样处理。
    // 不加此标注在 Swift 6 strict concurrency 下会报 "Main actor-isolated property
    // 'ciContext' can not be referenced from a nonisolated context"。
    private nonisolated(unsafe) let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    /// SCStream 帧回调队列：让 CIImage→CGImage 像素转换在后台执行，
    /// 仅最终赋值派发回主线程。之前用 .main 队列导致 10fps 的 createCGImage
    /// 持续占用主线程，造成切换器动画掉帧。
    private let captureQueue = DispatchQueue(label: "com.easymactool.captureStream", qos: .userInitiated)

    /// Live stream 帧节流时间戳：避免 10fps 每帧都触发 SwiftUI 重渲染。
    /// 节流到 5fps（200ms 一次），人眼难以察觉但减半渲染开销。
    /// 使用 OSAllocatedUnfairLock 替代 nonisolated(unsafe)：Date 内部 8 字节
    /// Double 非原子读写，极端情况可能读到撕裂值。锁开销可忽略（纳秒级），
    /// 消除数据竞争隐患。
    private nonisolated(unsafe) let lastFrameTime = OSAllocatedUnfairLock(initialState: Date.distantPast)

    /// The window currently receiving a live stream (selected/hovered).
    private var liveWindowID: CGWindowID?

    /// setLiveWindow 防抖 Task：选中项变化后延迟 300ms 才启动实时流。
    /// 避免用户快速 Tab 切换时频繁启停 SCStream（启动开销 ~100-200ms）。
    /// 500ms 内若选中项再次变化，旧 Task 被 cancel，新 Task 启动。
    /// 这与 Windows Alt+Tab 的节奏一致：短暂停留才显示实时画面。
    private var liveDebounceTask: Task<Void, Never>?
    private static let liveDebounceDelay: UInt64 = 500_000_000  // 500ms

    /// 存储 startCapture 的 Task，便于在 stopAll 中 cancel。
    /// 防止用户快速开关切换器时，旧 Task 继续为已不显示的窗口捕获快照，
    /// 浪费 CPU/GPU 资源并污染 WindowPreviewCache。
    private var snapshotTask: Task<Void, Never>?
    private static let maximumConcurrentSnapshots = 4

    func startCapture(for items: [WindowItem], previewSize: AppSettings.PreviewSize) {
        // 取消上一次未完成的快照 Task（若用户快速重新打开切换器）。
        snapshotTask?.cancel()
        snapshotTask = Task {
            // 1. 同步处理 placeholder/offscreen。
            //    - placeholder（无窗口 app）：渲染 app icon 占位
            //    - minimized/hidden 窗口：直接渲染 app icon 占位
            //    离屏窗口不显示缓存预览（可能过时误导用户），统一用 app icon。
            //    这些 item 不参与并行捕获（ScreenCaptureKit 无法捕获离屏窗口）。
            var pending: [WindowItem] = []
            for item in items {
                if item.isOffScreen {
                    renderIconPlaceholder(for: item, previewSize: previewSize)
                } else {
                    pending.append(item)
                }
            }
            // 2. 并行捕获所有 on-screen 窗口。SCScreenshotManager.captureImage
            //    是 async 且线程安全，多个并行调用互不干扰。相比之前的串行
            //    for 循环，并行捕获让所有窗口几乎同时完成，避免从左至右的
            //    波浪式加载。
            let results: [(WindowItem, CGImage?)] = await withTaskGroup(
                of: (WindowItem, CGImage?).self
            ) { group in
                var nextIndex = 0
                func addNextTask() {
                    guard nextIndex < pending.count else { return }
                    let item = pending[nextIndex]
                    nextIndex += 1
                    group.addTask { [item] in
                        let image = await self.captureSnapshot(
                            for: item, previewSize: previewSize
                        )
                        return (item, image)
                    }
                }
                for _ in 0..<min(Self.maximumConcurrentSnapshots, pending.count) {
                    addNextTask()
                }
                var collected: [(WindowItem, CGImage?)] = []
                while let result = await group.next() {
                    collected.append(result)
                    addNextTask()
                }
                return collected
            }
            // 3. 批量设置 latestImage：在同一 MainActor runloop tick 中连续
            //    设置多个 @Published 属性，SwiftUI 会合并为一次重绘，所有
            //    cell 同时更新（无波浪式动画）。这是相比串行 await 循环
            //    （每个 item.latestImage 触发一次重绘）的关键改进。
            //    检查 Task.isCancelled：若 await 期间 stopAll() 被调用，
            //    不应继续向已关闭的切换器写入过期捕获。
            //    跳过当前 live stream 窗口：setLiveWindow 已启动实时流，
            //    若用静态快照覆盖会让选中项出现一帧旧图闪回（live stream 下一帧
            //    200ms 内会再覆盖回来，但用户可感知闪烁）。
            //    每轮重新读 liveWindowID（@MainActor 属性，Task 内同 actor 访问安全），
            //    避免 setLiveWindow 在 await 期间切换 live 窗口时快照过期误跳/漏跳。
            for (item, image) in results {
                if Task.isCancelled { break }
                if item.id == liveWindowID { continue }
                if let image {
                    item.latestImage = image
                    WindowPreviewCache.shared.store(image, for: item.id, pid: item.pid)
                } else if item.latestImage == nil {
                    // 捕获失败且无缓存：回退到 app icon 占位。
                    renderIconPlaceholder(for: item, previewSize: previewSize)
                }
            }
        }
    }

    /// Starts a live stream for the given item (the selected/hovered window).
    /// Stops any previous live stream first.
    func setLiveWindow(_ item: WindowItem?, previewSize: AppSettings.PreviewSize) {
        // 防抖：取消上一次未触发的延迟启动 Task。
        // 用户快速 Tab 切换时，每次 onSelectChanged 都会调 setLiveWindow，
        // 但只有最后一次停留超过 500ms 才真正启动 SCStream。
        liveDebounceTask?.cancel()
        liveDebounceTask = nil

        // 同一 item 不重复启停：避免选中项未变时无谓的 stop/start。
        // 注意：即使 item 相同，仍要取消之前的防抖 Task（可能正在等待）。
        if item?.id == liveWindowID && item != nil {
            return
        }

        // Stop the previous live stream.
        if let oldID = liveWindowID, let oldStream = streams[oldID] {
            oldStream.stopCapture { _ in }
            streams.removeValue(forKey: oldID)
            itemForStream.removeValue(forKey: ObjectIdentifier(oldStream))
        }
        liveWindowID = nil

        guard let item = item, !item.isOffScreen else { return }

        // 延迟 500ms 启动实时流：避免快速 Tab 时频繁启停 SCStream。
        // 500ms 内若选中项再次变化，此 Task 被 cancel，不会启动 stream。
        let itemCopy = item
        let sizeCopy = previewSize
        liveDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.liveDebounceDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 防抖期间选中项可能已变化，再次校验。
                guard self.liveWindowID != itemCopy.id else { return }
                self.startStream(for: itemCopy, previewSize: sizeCopy)
                if self.streams[itemCopy.id] != nil {
                    self.liveWindowID = itemCopy.id
                }
            }
        }
    }

    func stopAll() {
        // Cancel the in-flight snapshot Task: prevents the old Task from
        // continuing to capture windows that are no longer displayed, and
        // from polluting WindowPreviewCache with stale frames.
        snapshotTask?.cancel()
        snapshotTask = nil
        // 取消待触发的 live stream 防抖 Task：切换器关闭时若防抖仍在等待，
        // 不应在新面板/无面板时启动 stream。
        liveDebounceTask?.cancel()
        liveDebounceTask = nil
        for stream in streams.values {
            stream.stopCapture { _ in }
        }
        streams.removeAll()
        itemForStream.removeAll()
        liveWindowID = nil
    }

    // MARK: - Live stream

    private func startStream(for item: WindowItem, previewSize: AppSettings.PreviewSize) {
        guard let scWindow = item.scWindow else { return }
        // Don't create duplicate streams.
        if streams[item.id] != nil { return }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        // The UI publishes at 5 FPS, so asking ScreenCaptureKit for 10 FPS
        // only wastes compositor/GPU work before the software throttle drops it.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        // A live frame is rendered only into a thumbnail. Cap the capture to
        // twice the thumbnail dimensions (enough for Retina sharpness) instead
        // of scaling with an arbitrarily large source window.
        let requestedScale = max(previewSize.captureScale, 240.0 / max(item.frame.width, 1))
        let maximumScale = min(
            previewSize.thumbnailWidth * 2 / max(item.frame.width, 1),
            previewSize.thumbnailHeight * 2 / max(item.frame.height, 1)
        )
        let scale = min(requestedScale, maximumScale)
        config.width = max(1, Int(item.frame.width * scale))
        config.height = max(1, Int(item.frame.height * scale))

        // SCStream.delegate 是 weak 属性（Apple 框架惯例），不会强引用 self，
        // 因此不存在 manager → streams → stream → delegate → manager 的 retain cycle。
        // manager 常驻 app 生命周期，stopAll() 清空 streams 即可打破持有。
        guard let stream = try? SCStream(filter: filter, configuration: config, delegate: self) else { return }
        do {
            // 使用后台 captureQueue 处理帧回调，避免 10fps 的 createCGImage
            // 占用主线程造成切换器动画掉帧。
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try stream.startCapture()
            streams[item.id] = stream
            itemForStream[ObjectIdentifier(stream)] = item
        } catch {
            // startCapture/addStreamOutput 失败时必须显式 stopCapture：
            // stream 是局部变量出作用域后被释放，但 SCStream 内部可能已分配
            // 桌面捕获资源。itemForStream 未设置（上面那行未执行），
            // stream(_:didStopWithError:) delegate 的 guard itemForStream.removeValue
            // 会返回 nil，无法清理 streams 字典 → 资源泄漏。这里同步清理。
            stream.stopCapture { _ in }
        }
    }

    // MARK: - Static snapshot

    /// 捕获单个窗口的静态快照，返回 CGImage?。不修改 item.latestImage，
    /// 不写缓存——这些由调用方（startCapture 的批量更新阶段）统一处理。
    /// 解耦"捕获"与"赋值"让并行任务可以返回结果后批量赋值，SwiftUI
    /// 只触发一次重绘。
    private func captureSnapshot(for item: WindowItem,
                                  previewSize: AppSettings.PreviewSize) async -> CGImage? {
        guard let scWindow = item.scWindow else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let scale = previewSize.captureScale
        config.width = max(1, Int(item.frame.width * scale))
        config.height = max(1, Int(item.frame.height * scale))
        // try? 把捕获失败（权限不足、窗口已关闭等）转为 nil，
        // 由 startCapture 批量更新阶段统一回退到 icon 占位。
        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    // MARK: - Icon placeholder

    private func renderIconPlaceholder(for item: WindowItem, previewSize: AppSettings.PreviewSize) {
        guard let icon = item.appIcon else { return }
        let size = CGSize(width: previewSize.thumbnailWidth, height: previewSize.thumbnailHeight)
        item.latestImage = renderImage(from: icon, size: size)
    }

    private func renderImage(from nsImage: NSImage, size: CGSize) -> CGImage? {
        let rect = NSRect(origin: .zero, size: size)
        guard let rep = nsImage.bestRepresentation(for: rect, context: nil, hints: nil) as? NSBitmapImageRep,
              let cg = rep.cgImage else { return nil }
        return cg
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 节流：5fps 足够流畅，避免 10fps 每帧触发 SwiftUI 重渲染。
        // 时间戳检查在后台队列做，过滤掉一半的 createCGImage 调用，
        // 直接减少 CPU/GPU 开销。
        let now = Date()
        let shouldRender: Bool = self.lastFrameTime.withLock { last -> Bool in
            if now.timeIntervalSince(last) < 0.2 { return false }
            last = now
            return true
        }
        if !shouldRender { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // 在后台 captureQueue 上做 GPU→CPU 像素转换（重活），
        // 通过 Task { @MainActor } 异步派回主线程做最终赋值。
        // 不能用 MainActor.assumeIsolated——它是编译时断言辅助，
        // 要求运行时已在主线程，从后台队列调用会触发
        // dispatch_assert_queue_fail 崩溃（已实测验证）。
        guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        Task { @MainActor in
            if let item = self.itemForStream[ObjectIdentifier(stream)] {
                item.latestImage = cgImage
                // 不写 WindowPreviewCache：live stream 帧是临时的，
                // 选中切换时实时帧不需要进缓存，缓存无意义。
            }
        }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 不能用 MainActor.assumeIsolated——SCStreamDelegate 回调与
        // addStreamOutput 的 sampleHandlerQueue 一致（captureQueue 后台队列），
        // 从后台队列调用会触发 dispatch_assert_queue_fail 崩溃，在 release
        // 下表现为 CPU 100%/卡死。改用 Task { @MainActor } 异步派回主线程，
        // 与 stream(_:didOutputSampleBuffer:of:) 保持一致。
        Task { @MainActor in
            let key = ObjectIdentifier(stream)
            // 同步清理 streams 字典和 liveWindowID：之前只移除 itemForStream，
            // 导致已停止的 stream 仍留在 streams 中，setLiveWindow 会再次
            // 调用 stopCapture（对已停止的 stream 无意义）。
            // 防御：stopAll() 可能已清空 streams，此时 key 不存在直接跳过。
            guard let item = self.itemForStream.removeValue(forKey: key) else { return }
            self.streams.removeValue(forKey: item.id)
            if self.liveWindowID == item.id {
                self.liveWindowID = nil
            }
        }
    }
}
