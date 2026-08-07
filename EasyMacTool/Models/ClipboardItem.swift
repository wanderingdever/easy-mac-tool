import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// A single entry in the clipboard history. Captured at the moment the system
/// pasteboard changes. Stores enough to render a rich preview (Paste-style)
/// and to restore the original payload when the user re-selects it.
@MainActor
final class ClipboardItem: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    /// `var` 以支持冷数据 warmUp()：从磁盘加载图片后回填 .image kind 的
    /// data/thumbnail。仅 image kind 会变更，且仅在 nil → 有值方向变更，
    /// 不影响 _cachedFullImage 等缓存（冷数据时它们本就是 nil）。
    var kind: Kind

    /// Originating app metadata — drives the card header background tint and
    /// the leading app icon shown on each card.
    ///
    /// 只存 bundleID，图标通过 AppIconCache 按 bundleID 查询——避免每个 item
    /// 持有一份 NSImage 副本（同一 app 复制 100 次只占 1 份图标内存）。
    let sourceAppBundleID: String?
    let sourceAppName: String?
    let sourceAppTint: NSColor

    /// 富文本 RTF 数据：若文本是从支持富文本的应用（如 VSCode、Pages、
    /// Safari）复制的，保留其 RTF 数据以在卡片中还原颜色/字体样式。
    /// 仅 .text kind 会有值；其他 kind 为 nil。
    let rtfData: Data?

    /// 图片 TIFF 数据的磁盘文件引用（仅持久化后的 image kind 有值）。
    /// 热数据（≤7天）：imageData 与 thumbnail 在内存中。
    /// 冷数据（>7天）：imageData 与 thumbnail 为 nil，需 warmUp() 从文件加载。
    var imageFileURL: URL?

    /// 图片像素尺寸缓存（仅 image kind）：snapshot / warmUp 时通过 ImageIO
    /// 读一次元数据并缓存。footerText 直接读缓存——之前每次访问都
    /// CGImageSourceCreateWithData + CopyProperties，搜索框每个按键全量
    /// 过滤时对每个图片条目重复解析 TIFF 元数据，导致输入掉帧。
    /// 不持久化：重启后由 warmUp 路径重建。
    var imagePixelSize: (width: Int, height: Int)?

    enum Kind {
        case text(String)
        case url(URL, title: String?)
        /// 图片：存原始 TIFF Data + 缩略图 NSImage。
        /// - Data 用于重新粘贴时还原（write(to:)）和全屏预览懒加载
        /// - thumbnail 用于卡片预览（最大 256×256，已缩小避免持有 30MB NSImage）
        /// 冷数据加载时 data 与 thumbnail 可能为 nil，通过 warmUp() 从磁盘恢复。
        case image(Data?, thumbnail: NSImage?)
        case file(URLs: [URL])
        case color(NSColor, hex: String)
    }

    /// Coarse type used by the filter chip in the search bar.
    enum ContentKind: String, CaseIterable, Identifiable {
        case text, link, image, file, color
        var id: String { rawValue }
        var label: String {
            switch self {
            case .text: return "文本"
            case .link: return "链接"
            case .image: return "图片"
            case .file: return "文件"
            case .color: return "颜色"
            }
        }
        var symbol: String {
            switch self {
            case .text: return "doc.text"
            case .link: return "link"
            case .image: return "photo"
            case .file: return "doc"
            case .color: return "paintpalette"
            }
        }
        /// 种类颜色：用于筛选菜单图标背景色和类型标签区分。
        var tint: NSColor {
            switch self {
            case .text: return NSColor(red: 0x4A/255, green: 0x90/255, blue: 0xE2/255, alpha: 1)   // 蓝
            case .link: return NSColor(red: 0x6A/255, green: 0x5A/255, blue: 0xD4/255, alpha: 1)   // 紫
            case .image: return NSColor(red: 0xE2/255, green: 0x6A/255, blue: 0x8A/255, alpha: 1)   // 粉
            case .file: return NSColor(red: 0x4A/255, green: 0xC8/255, blue: 0x9A/255, alpha: 1)   // 绿
            case .color: return NSColor(red: 0xE8/255, green: 0xA8/255, blue: 0x4A/255, alpha: 1)   // 橙
            }
        }
    }

    var contentKind: ContentKind {
        switch kind {
        case .text: return .text
        case .url: return .link
        case .image: return .image
        case .file: return .file
        case .color: return .color
        }
    }

    init(id: UUID = UUID(),
         createdAt: Date = Date(),
         kind: Kind,
         sourceAppBundleID: String? = nil,
         sourceAppName: String? = nil,
         // Safe sRGB fallback — never a catalog color, so component accessors
         // (redComponent etc.) always work without a color-space conversion.
         sourceAppTint: NSColor = NSColor(red: 0x0A/255.0,
                                          green: 0x84/255.0,
                                          blue: 0xFF/255.0,
                                          alpha: 1.0),
         rtfData: Data? = nil,
         imageFileURL: URL? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.sourceAppTint = sourceAppTint
        self.rtfData = rtfData
        self.imageFileURL = imageFileURL
    }

    // MARK: - Codable

    /// 自定义 Codable：NSColor 编码为 sRGB 分量数组，
    /// image kind 的 TIFF Data 存独立文件（通过 imageFileURL 引用），
    /// thumbnail 不编码（从 TIFF Data 重新生成）。
    enum CodingKeys: String, CodingKey {
        case id, createdAt, kind, sourceAppBundleID, sourceAppName
        case sourceAppTintR, sourceAppTintG, sourceAppTintB, sourceAppTintA
        case rtfData, imageFileName, kindType
        case textValue, urlValue, urlTitle, fileURLs, colorHex
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        sourceAppBundleID = try c.decodeIfPresent(String.self, forKey: .sourceAppBundleID)
        sourceAppName = try c.decodeIfPresent(String.self, forKey: .sourceAppName)
        let r = try c.decode(Double.self, forKey: .sourceAppTintR)
        let g = try c.decode(Double.self, forKey: .sourceAppTintG)
        let b = try c.decode(Double.self, forKey: .sourceAppTintB)
        let a = try c.decode(Double.self, forKey: .sourceAppTintA)
        sourceAppTint = NSColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
        rtfData = try c.decodeIfPresent(Data.self, forKey: .rtfData)
        let imageName = try c.decodeIfPresent(String.self, forKey: .imageFileName)

        let kindType = try c.decode(String.self, forKey: .kindType)
        switch kindType {
        case "text":
            let text = try c.decode(String.self, forKey: .textValue)
            kind = .text(text)
        case "url":
            let url = try c.decode(URL.self, forKey: .urlValue)
            let title = try c.decodeIfPresent(String.self, forKey: .urlTitle)
            kind = .url(url, title: title)
        case "image":
            // image 的 TIFF Data 存独立文件，加载时按需读取。
            // 冷数据（>7天）不加载 data/thumbnail，需 warmUp()。
            // imageFileURL 由 ClipboardManager.loadFromDisk() 设置为绝对路径。
            kind = .image(nil, thumbnail: nil)
        case "file":
            let urls = try c.decode([URL].self, forKey: .fileURLs)
            kind = .file(URLs: urls)
        case "color":
            let hex = try c.decode(String.self, forKey: .colorHex)
            // 从 hex 字符串重建 NSColor（之前错误地复用了 sourceAppTint 的 RGB 分量）
            if let (color, _) = ColorStringParser.parse(hex) {
                kind = .color(color, hex: hex)
            } else {
                // Fallback：hex 解析失败时用 sRGB 纯黑作为兜底色。
                // 之前错误地用 sourceAppTint（来源 app 的色调）作为用户复制
                // 颜色的兜底——语义完全错误，用户复制的颜色与来源 app 无关。
                // 也不能用 NSColor.black：它是 calibrated white 色彩空间，
                // footerText / colorHexString 访问 redComponent 会抛
                // NSInvalidArgumentException（OC 异常，Swift 拦不住）。
                kind = .color(NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 1), hex: hex)
            }
        default:
            throw DecodingError.dataCorruptedError(forKey: .kindType, in: c, debugDescription: "Unknown kind type")
        }
        // imageFileName 仅存文件名（如 "UUID.tiff"），不含目录路径。
        // 此处的 imageFileURL 指向当前工作目录，是临时值——
        // ClipboardManager.loadFromDisk() 会在解码后修正为绝对路径。
        if kindType == "image", let imageName {
            imageFileURL = URL(fileURLWithPath: imageName, relativeTo: nil)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(sourceAppBundleID, forKey: .sourceAppBundleID)
        try c.encodeIfPresent(sourceAppName, forKey: .sourceAppName)
        let srgb = sourceAppTint.usingColorSpace(.sRGB) ?? sourceAppTint
        try c.encode(Double(srgb.redComponent), forKey: .sourceAppTintR)
        try c.encode(Double(srgb.greenComponent), forKey: .sourceAppTintG)
        try c.encode(Double(srgb.blueComponent), forKey: .sourceAppTintB)
        try c.encode(Double(srgb.alphaComponent), forKey: .sourceAppTintA)
        try c.encodeIfPresent(rtfData, forKey: .rtfData)

        switch kind {
        case .text(let text):
            try c.encode("text", forKey: .kindType)
            try c.encode(text, forKey: .textValue)
        case .url(let url, let title):
            try c.encode("url", forKey: .kindType)
            try c.encode(url, forKey: .urlValue)
            try c.encodeIfPresent(title, forKey: .urlTitle)
        case .image:
            try c.encode("image", forKey: .kindType)
            // TIFF Data 存独立文件，JSON 中只存文件名（UUID.tiff）
            if let url = imageFileURL {
                try c.encode(url.lastPathComponent, forKey: .imageFileName)
            } else {
                try c.encode("\(id.uuidString).tiff", forKey: .imageFileName)
            }
        case .file(let urls):
            try c.encode("file", forKey: .kindType)
            try c.encode(urls, forKey: .fileURLs)
        case .color(_, let hex):
            try c.encode("color", forKey: .kindType)
            try c.encode(hex, forKey: .colorHex)
        }
    }

    /// 通过 AppIconCache 按 bundleID 查询图标。视图层访问此属性即可，
    /// 避免每个 ClipboardItem 持有一份 NSImage 副本。
    var sourceAppIcon: NSImage? { AppIconCache.icon(for: sourceAppBundleID) }

    /// Approximate in-memory payload size used by ClipboardManager to enforce
    /// a bounded history budget. This deliberately counts the original image
    /// data as well as its decoded thumbnail.
    var estimatedMemoryBytes: Int {
        switch kind {
        case .text(let text):
            return text.lengthOfBytes(using: .utf8) + (rtfData?.count ?? 0)
        case .url(let url, let title):
            return url.absoluteString.lengthOfBytes(using: .utf8)
                + (title?.lengthOfBytes(using: .utf8) ?? 0)
        case .image(let data, let thumbnail):
            // 冷数据 data/thumbnail 为 nil，内存占用为 0（数据在磁盘上）。
            let dataBytes = data?.count ?? 0
            // makeThumbnail 现在用 CGImage 的实际像素尺寸设置 NSImage.size，
            // 所以 thumbnail.size 能正确反映像素数。每像素 4 字节（RGBA）。
            let thumbPixels = thumbnail.map { Int($0.size.width * $0.size.height * 4) } ?? 0
            return dataBytes + thumbPixels
        case .file(let urls):
            return urls.reduce(0) { $0 + $1.path.lengthOfBytes(using: .utf8) }
        case .color:
            return 64
        }
    }

    /// 图片缩略图（用于卡片预览，已缩放到最大 256×256）。
    var imageThumbnail: NSImage? {
        guard case .image(_, let thumb) = kind else { return nil }
        return thumb
    }

    /// 从磁盘加载图片数据，将冷数据 .image(nil, nil) 回填为 .image(data, thumbnail)。
    /// 仅在 image kind 且 data 或 thumbnail 为 nil 时执行。
    /// 调用后 _cachedFullImage 等缓存会在首次访问时从新的 data 生成。
    /// 注意：此方法内部 Data(contentsOf:) 是同步磁盘 IO，在主线程调用会阻塞。
    /// 视图渲染路径应优先使用 warmUpAsync() 避免卡顿。
    func warmUp() {
        guard case .image(let data, let thumbnail) = kind,
              data == nil || thumbnail == nil,
              let url = imageFileURL else { return }
        guard let fileData = try? Data(contentsOf: url) else { return }
        let thumb = thumbnail ?? Self.makeThumbnail(from: fileData, max: 256)
        kind = .image(fileData, thumbnail: thumb)
        // kind 变化后 footerText 改变，失效搜索缓存
        _cachedSearchableText = nil
        // 同步填充像素尺寸缓存，footerText 不再重复解析 TIFF 元数据
        if imagePixelSize == nil {
            imagePixelSize = Self.readPixelSize(from: fileData)
        }
    }

    /// 异步 warmUp：在后台队列读取磁盘数据，再回主线程更新 kind。
    /// 用于卡片渲染路径——避免 warmUp() 同步 IO 阻塞主线程造成卡顿。
    /// 调用方应在 .task 或 Task 中 await 此方法。
    func warmUpAsync() async {
        guard case .image(let data, let thumbnail) = kind,
              data == nil || thumbnail == nil,
              let url = imageFileURL else { return }
        // 后台读取文件数据，避免阻塞主线程
        let fileData = await Task.detached { try? Data(contentsOf: url) }.value
        guard let fileData else { return }
        // 回主线程更新 kind（ClipboardItem 是 @MainActor 隔离）
        await MainActor.run {
            // 重新检查：可能在 await 期间已被其他路径 warmUp
            guard case .image(let curData, let curThumb) = self.kind,
                  curData == nil || curThumb == nil else { return }
            let thumb = curThumb ?? Self.makeThumbnail(from: fileData, max: 256)
            self.kind = .image(fileData, thumbnail: thumb)
            // kind 变化后 footerText 改变，失效搜索缓存
            self._cachedSearchableText = nil
            // 同步填充像素尺寸缓存，footerText 不再重复解析 TIFF 元数据
            if self.imagePixelSize == nil {
                self.imagePixelSize = Self.readPixelSize(from: fileData)
            }
        }
    }

    /// 用 ImageIO 仅读取图片元数据中的像素尺寸（不解码像素）。
    /// 供 snapshot / warmUp 填充 imagePixelSize 缓存。
    static func readPixelSize(from imageData: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// 使用 ImageIO 解码端降采样生成缩略图，避免解码完整位图再重绘。
    /// 从 ClipboardManager 移至此处，供 warmUp() 和 ClipboardManager 共用。
    /// 注意：NSImage 的 size 必须设为 CGImage 的实际像素尺寸，不能用 .zero。
    /// 之前用 .zero 导致 estimatedMemoryBytes 估算为 0，150MB 上限失效。
    static func makeThumbnail(from imageData: Data, max maxSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSize)
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        // 用 CGImage 的实际像素尺寸设置 NSImage.size，使 estimatedMemoryBytes
        // 能正确估算（width * height * 4 bytes）。
        let size = NSSize(width: image.width, height: image.height)
        return NSImage(cgImage: image, size: size)
    }

    /// 完整图片（懒加载 + 缓存）：从存储的 TIFF Data 创建 NSImage。
    /// 用于全屏预览；NSImage(data:) 不立即解码像素，访问 .size 等元数据时极快。
    /// 首次访问后缓存到静态 NSCache，避免每次 body 重渲染都新建 NSImage 实例。
    /// 用 NSCache 而非实例变量：ClipboardItem 是常驻对象，滚动出去后视图销毁了，
    /// 实例变量 _cachedFullImage 仍持有 NSImage（每张 4-8MB），100 张图滚一遍
    /// 可累积 400-800MB。NSCache 在系统内存压力时自动淘汰，无需依赖 coolDown()。
    /// totalCostLimit = 100MB，按 TIFF data 字节数计入成本，超出自动 LRU 淘汰。
    private static let fullImageCache: NSCache<NSUUID, NSImage> = {
        let c = NSCache<NSUUID, NSImage>()
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()
    var fullImage: NSImage? {
        if let cached = Self.fullImageCache.object(forKey: id as NSUUID) { return cached }
        guard case .image(let data, _) = kind, let data else { return nil }
        guard let img = NSImage(data: data) else { return nil }
        // cost = TIFF data 字节数，让 NSCache 按总成本淘汰大图。
        Self.fullImageCache.setObject(img, forKey: id as NSUUID, cost: data.count)
        return img
    }

    /// 缓存的 RTF 解析结果：避免每次卡片 body 重渲染都重新解析 RTF Data。
    /// NSAttributedString(data:options:) 是同步解析，100 张含代码的文本卡片
    /// 每次滚动都触发 100 次解析，是滚动卡顿的最主要嫌疑源。
    /// 首次访问时解析并缓存，后续直接返回。
    private var _cachedAttributedString: AttributedString?
    var cachedAttributedString: AttributedString? {
        if let cached = _cachedAttributedString { return cached }
        guard let rtfData,
              let nsAttr = try? NSAttributedString(
                  data: rtfData,
                  options: [.documentType: NSAttributedString.DocumentType.rtf],
                  documentAttributes: nil) else { return nil }
        let attr = AttributedString(nsAttr)
        _cachedAttributedString = attr
        return attr
    }

    /// 缓存的 header 前景色：基于 sourceAppTint 的 luminance 计算黑/白。
    /// 之前每次 body 都重算 usingColorSpace + luminance，100 张卡片滚动时浪费。
    private var _cachedHeaderForeground: Color?
    var headerForeground: Color {
        if let cached = _cachedHeaderForeground { return cached }
        let ns = sourceAppTint.usingColorSpace(.sRGB)
            ?? NSColor.systemBlue.usingColorSpace(.sRGB)
            ?? NSColor(red: 0x0A/255.0, green: 0x84/255.0, blue: 0xFF/255.0, alpha: 1.0)
        let luminance = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        let color: Color = luminance > 0.6 ? .black : .white
        _cachedHeaderForeground = color
        return color
    }

    /// 搜索用的小写文本（title + footerText 拼接），懒加载缓存。
    /// filtered 在搜索框每次击键时全量遍历，预计算避免重复 lowercased() +
    /// footerText 的 trimming/split（1000 条 × 每次击键的主要开销）。
    /// kind 变化（warmUp）后需失效——warmUp/warmUpAsync/coolDown 中清空。
    private var _cachedSearchableText: String?
    var searchableText: String {
        if let cached = _cachedSearchableText { return cached }
        let text = (title + "\n" + footerText).lowercased()
        _cachedSearchableText = text
        return text
    }

    /// 释放懒加载缓存（fullImage / _cachedAttributedString / _cachedHeaderForeground）。
    /// 由 ClipboardManager 在系统内存压力时对所有 item 调用，避免 1000 张图的
    /// fullImage 永久持有导致内存爆炸。释放后下次访问会重新生成。
    /// 注意：只释放缓存，不改变 kind（data/thumbnail 仍保留，因为是热数据的核心内容）。
    func coolDown() {
        Self.fullImageCache.removeObject(forKey: id as NSUUID)
        _cachedAttributedString = nil
        _cachedHeaderForeground = nil
        _cachedSearchableText = nil
    }

    /// Short title shown above the preview card.
    var title: String {
        switch kind {
        case .text(let s):
            return firstLine(of: s) ?? "文本"
        case .url(let url, let title):
            return title ?? url.host ?? url.absoluteString
        case .image:
            return "图像"
        case .file(let urls):
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个文件"
        case .color(_, let hex):
            return hex.uppercased()
        }
    }

    /// Type label shown in the card header (right side). One of:
    /// 文本 / 链接 / 图片 / 文件 / 颜色.
    var typeLabel: String {
        switch kind {
        case .text: return "文本"
        case .url: return "链接"
        case .image: return "图片"
        case .file: return "文件"
        case .color: return "颜色"
        }
    }

    /// Footer statistic shown in the transparent floating strip at the bottom
    /// of each card. Centered, single line.
    /// - 文本: 字数统计 (e.g. "123 字")
    /// - 文件: 文件路径 (truncated)
    /// - 图片: 像素比例 (e.g. "1920×1080")
    /// - 链接: 主机名
    /// - 颜色: 十六进制 + RGB
    ///
    /// 重要：image 分支不能用 fullImage 懒加载（会触发 NSImage(data:) 解码
    /// 并永久缓存到 _cachedFullImage）。filtered 计算属性每次 body 重算
    /// 都会访问 footerText，搜索框输入时会把所有 image 条目的 fullImage
    /// 全量加载到内存（内存爆炸主路径）。
    /// 改为：热数据从 kind.image(data) 读 CGImage 尺寸（仅 metadata），
    /// 冷数据不读盘只显示"图像"。
    var footerText: String {
        switch kind {
        case .text(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let chars = trimmed.count
            let lines = s.split(separator: "\n", omittingEmptySubsequences: true).count
            return lines > 1 ? "\(chars) 字 · \(lines) 行" : "\(chars) 字"
        case .url(let url, _):
            return url.host ?? url.absoluteString
        case .image(let data, _):
            // 优先读像素尺寸缓存（snapshot/warmUp 时填充一次）。
            // 之前每次访问都 CGImageSourceCreateWithData + CopyProperties——
            // filtered 计算属性在搜索框每次击键时全量重算，历史接近上限时
            // 每按键触发数百次 ImageIO 元数据解析，导致输入掉帧。
            if let size = imagePixelSize {
                return "\(size.width) × \(size.height) px"
            }
            // 缓存未填充但 data 在内存（如直接构造的测试数据）：补读并缓存。
            if let data, let size = Self.readPixelSize(from: data) {
                imagePixelSize = size
                return "\(size.width) × \(size.height) px"
            }
            // 冷数据（data == nil）：不读盘，避免 filtered 触发全量懒加载
            return "图像"
        case .file(let urls):
            if let first = urls.first {
                let path = first.deletingLastPathComponent().path
                return truncateMiddle(path, max: 30)
            }
            return "\(urls.count) 个文件"
        case .color(let color, let hex):
            // usingColorSpace 防御：任何非 RGB 色彩空间的 NSColor 直接访问
            // redComponent 会抛 NSInvalidArgumentException（OC 异常）。
            let c = color.usingColorSpace(.sRGB) ?? NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 1)
            let rgb = "\(Int(c.redComponent * 255)), \(Int(c.greenComponent * 255)), \(Int(c.blueComponent * 255))"
            return "\(hex.uppercased()) · RGB(\(rgb))"
        }
    }

    /// Renders the item back onto the system pasteboard on re-selection.
    func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        switch kind {
        case .text(let s):
            // Preserve the rich representation for apps that understand RTF,
            // while also providing the plain-text fallback expected by all apps.
            if let rtfData {
                pasteboard.setData(rtfData, forType: .rtf)
            }
            pasteboard.setString(s, forType: .string)
        case .url(let url, _):
            pasteboard.setString(url.absoluteString, forType: .string)
            pasteboard.setPropertyList([url.absoluteString], forType: .URL)
        case .image(let data, _):
            // 冷数据 data 为 nil 时跳过：reapply() 在调用 write(to:) 前已通过
            // warmUpAsync() 加载冷数据，不应在此同步 fallback（阻塞主线程）。
            // 若 data 仍为 nil（warmUpAsync 失败），不写入图片到 pasteboard。
            if let data {
                pasteboard.setData(data, forType: .tiff)
            }
        case .file(let urls):
            pasteboard.writeObjects(urls as [NSPasteboardWriting])
        case .color(let color, _):
            // Re-encode as hex string so it pastes back into color pickers /
            // text fields that accept hex (most common for designers).
            pasteboard.setString(colorHexString(color), forType: .string)
        }
    }

    private func firstLine(of text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed) }
        }
        return nil
    }

    private func truncateMiddle(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let head = s.prefix((max - 1) / 2)
        let tail = s.suffix((max - 1) / 2)
        return "\(head)…\(tail)"
    }

    /// 判断 URL 是否指向图片文件（按扩展名）。用于 .file kind 在卡片/预览
    /// 中显示图片缩略图而非通用文件图标。
    static func isImageFile(_ url: URL) -> Bool {
        let exts: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif",
                                 "heic", "webp", "bmp", "icns", "psd"]
        return exts.contains(url.pathExtension.lowercased())
    }

    private func colorHexString(_ color: NSColor) -> String {
        // usingColorSpace 防御：非 RGB 色彩空间的 NSColor 直接访问分量会抛异常
        let c = color.usingColorSpace(.sRGB) ?? NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 1)
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
