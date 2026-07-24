import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import ScreenCaptureKit

/// Maintains a persistent cache of the last successful preview frame per window,
/// so minimized/hidden windows can show their last-known state.
@MainActor
final class WindowPreviewCache {
    static let shared = WindowPreviewCache()
    private var cache: [CGWindowID: CGImage] = [:]

    func image(for windowID: CGWindowID) -> CGImage? { cache[windowID] }

    func store(_ image: CGImage, for windowID: CGWindowID) { cache[windowID] = image }

    func clear() { cache.removeAll() }
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
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// The window currently receiving a live stream (selected/hovered).
    private var liveWindowID: CGWindowID?

    /// 存储 startCapture 的 Task，便于在 stopAll 中 cancel。
    /// 防止用户快速开关切换器时，旧 Task 继续为已不显示的窗口捕获快照，
    /// 浪费 CPU/GPU 资源并污染 WindowPreviewCache。
    private var snapshotTask: Task<Void, Never>?

    func startCapture(for items: [WindowItem], previewSize: AppSettings.PreviewSize) {
        // 取消上一次未完成的快照 Task（若用户快速重新打开切换器）。
        snapshotTask?.cancel()
        snapshotTask = Task {
            // 1. 同步处理 placeholder/offscreen（icon 渲染，无需 await）。
            //    这些 item 不参与并行捕获。
            var pending: [WindowItem] = []
            for item in items {
                if item.isPlaceholder || item.isOffScreen {
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
                for item in pending {
                    // 捕获可能耗时，持有 item 强引用防止在 await 期间被
                    // 释放（用户快速关闭切换器时 items 可能被替换）。
                    group.addTask { [item] in
                        let image = await self.captureSnapshot(
                            for: item, previewSize: previewSize
                        )
                        return (item, image)
                    }
                }
                var collected: [(WindowItem, CGImage?)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            // 3. 批量设置 latestImage：在同一 MainActor runloop tick 中连续
            //    设置多个 @Published 属性，SwiftUI 会合并为一次重绘，所有
            //    cell 同时更新（无波浪式动画）。这是相比串行 await 循环
            //    （每个 item.latestImage 触发一次重绘）的关键改进。
            for (item, image) in results {
                if let image {
                    item.latestImage = image
                    WindowPreviewCache.shared.store(image, for: item.id)
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
        // Stop the previous live stream.
        if let oldID = liveWindowID, let oldStream = streams[oldID] {
            oldStream.stopCapture { _ in }
            streams.removeValue(forKey: oldID)
            itemForStream.removeValue(forKey: ObjectIdentifier(oldStream))
        }
        liveWindowID = nil

        guard let item = item, !item.isOffScreen, !item.isPlaceholder else { return }

        // Start a new live stream for this window.
        startStream(for: item, previewSize: previewSize)
        liveWindowID = item.id
    }

    func stopAll() {
        // Cancel the in-flight snapshot Task: prevents the old Task from
        // continuing to capture windows that are no longer displayed, and
        // from polluting WindowPreviewCache with stale frames.
        snapshotTask?.cancel()
        snapshotTask = nil
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
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let scale = max(previewSize.captureScale, 240.0 / max(item.frame.width, 1))
        config.width = max(1, Int(item.frame.width * scale))
        config.height = max(1, Int(item.frame.height * scale))

        guard let stream = try? SCStream(filter: filter, configuration: config, delegate: self) else { return }
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try stream.startCapture()
            streams[item.id] = stream
            itemForStream[ObjectIdentifier(stream)] = item
        } catch {
            // Skip individual windows we can't capture.
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
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        MainActor.assumeIsolated {
            guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
            if let item = self.itemForStream[ObjectIdentifier(stream)] {
                item.latestImage = cgImage
                WindowPreviewCache.shared.store(cgImage, for: item.id)
            }
        }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            let key = ObjectIdentifier(stream)
            // 同步清理 streams 字典和 liveWindowID：之前只移除 itemForStream，
            // 导致已停止的 stream 仍留在 streams 中，setLiveWindow 会再次
            // 调用 stopCapture（对已停止的 stream 无意义）。
            if let item = self.itemForStream.removeValue(forKey: key) {
                self.streams.removeValue(forKey: item.id)
                if self.liveWindowID == item.id {
                    self.liveWindowID = nil
                }
            }
        }
    }
}
