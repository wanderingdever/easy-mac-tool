import AppKit
import Foundation

/// 链接元数据缓存：为 .url 剪贴板条目异步抓取网页标题与站点图标（类似 Paste
/// 的链接预览）。按 URL 字符串缓存，in-flight 请求去重，避免同一 URL 重复抓取。
///
/// 性能 / 隐私说明：
/// - 仅对 http/https URL 抓取；请求超时 6s；HTML 流式截断到 512KB、图标 256KB，
///   避免超大页面/资源拖慢或占用内存。
/// - 标题取自 <title>；图标优先 <link rel="...icon...">（apple-touch-icon 优先，
///   多为 PNG），回退 <host>/favicon.ico。
/// - 结果仅内存缓存（不持久化），重复条目直接命中；网络失败静默降级为系统
///   link.circle 图标 + host 文本。
@MainActor
final class LinkMetadataCache {
    static let shared = LinkMetadataCache()

    struct Metadata {
        let title: String?
        let favicon: NSImage?
    }

    /// NSCache 包装类：Metadata 是 struct，NSCache 要求 value 为 class。
    final class MetadataBox: NSObject {
        let metadata: Metadata
        init(_ metadata: Metadata) { self.metadata = metadata }
    }

    /// 用 NSCache 替代裸字典：countLimit + totalCostLimit 双重限制，favicon
    /// 数据按字节计入成本，防止长期运行 + 大量复制 URL 后缓存无限增长。
    private let cache: NSCache<NSString, MetadataBox> = {
        let c = NSCache<NSString, MetadataBox>()
        c.countLimit = 200
        c.totalCostLimit = ImageMemoryBudget.linkFaviconBytes
        return c
    }()
    private var inFlight: [String: Task<(title: String?, faviconData: Data?), Never>] = [:]

    nonisolated private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    nonisolated private static let noRedirectDelegate = NoRedirectDelegate()

    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration,
                          delegate: noRedirectDelegate,
                          delegateQueue: nil)
    }()

    private init() {}

    /// 同步读取已缓存的元数据（命中时返回，未命中返回 nil）。
    func cached(_ urlString: String) -> Metadata? {
        cache.object(forKey: urlString as NSString)?.metadata
    }

    /// 异步获取元数据：缓存命中直接返回；否则后台抓取。同一 URL 并发去重。
    /// 网络抓取在 Task.detached 后台执行（返回 Sendable 的 (title, Data)），
    /// NSImage 在主 actor 创建，避免跨 actor 传递非 Sendable 的 NSImage。
    ///
    /// 隐私保护：默认不抓取。用户在设置中开启「链接预览」后才会对 http/https
    /// URL 发起网络请求，避免复制私有/带 token 的链接时 app 主动访问造成服务端
    /// 副作用或信息泄露。关闭时返回空 Metadata，视图回退到系统图标 + host 文本。
    func metadata(for urlString: String, userInitiated: Bool = false) async -> Metadata {
        let mode = AppSettings.shared.clipboardLinkPreviewMode
        guard mode == .automatic || (mode == .manual && userInitiated) else {
            return Metadata(title: nil, favicon: nil)
        }
        if let cached = cache.object(forKey: urlString as NSString)?.metadata { return cached }
        if let task = inFlight[urlString] {
            // 并发去重：等待首个请求完成后从缓存读取（首个请求负责写入 cache）。
            _ = await task.value
            return cache.object(forKey: urlString as NSString)?.metadata
                ?? Metadata(title: nil, favicon: nil)
        }
        // fetchRaw 加 8s 超时竞速：URLSession 自身有 6s timeout，但极端情况
        // （DNS 慢、连接挂起）下兜底，保证 inFlight 不会因 Task 永不完成而残留。
        let task = Task.detached(priority: .utility) { () -> (title: String?, faviconData: Data?) in
            await withTaskGroup(of: (title: String?, faviconData: Data?).self) { group in
                group.addTask { await Self.fetchRaw(urlString) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    return (nil, nil)
                }
                let result = await group.next() ?? (title: nil, faviconData: nil)
                group.cancelAll()
                return result
            }
        }
        inFlight[urlString] = task
        let raw = await task.value
        guard raw.title != nil || raw.faviconData != nil else {
            inFlight[urlString] = nil
            return Metadata(title: nil, favicon: nil)
        }
        let meta = Metadata(
            title: raw.title,
            favicon: raw.faviconData.flatMap { NSImage(data: $0) }
        )
        // cost = favicon 字节数，让 NSCache 按成本淘汰（大图标优先被回收）。
        let cost = raw.faviconData?.count ?? 0
        cache.totalCostLimit = ImageMemoryBudget.adjusted(ImageMemoryBudget.linkFaviconBytes)
        cache.setObject(MetadataBox(meta), forKey: urlString as NSString, cost: cost)
        inFlight[urlString] = nil
        return meta
    }

    // MARK: - 抓取（后台，nonisolated）

    /// 抓取 URL 的标题与 favicon 原始数据。全部为 Sendable 类型，可跨 actor。
    nonisolated private static func fetchRaw(_ urlString: String) async -> (title: String?, faviconData: Data?) {
        guard let url = URL(string: urlString), LinkPreviewNetworkPolicy.allows(url) else {
            return (nil, nil)
        }

        // 1. 抓取 HTML（流式截断 512KB）。
        var title: String? = nil
        var iconHref: String? = nil
        if let html = await fetchHTMLString(url) {
            title = parseTitle(html)
            iconHref = parseIconHref(html)
        }

        // 2. 解析 favicon 绝对地址：优先 HTML 中声明的图标，回退 /favicon.ico。
        // 跳过 data: URI（如 example.com 的占位空图标 <link rel="icon" href="data:,">），
        // 直接回退到 /favicon.ico。
        let faviconURL: URL? = {
            if let href = iconHref, !href.hasPrefix("data:"),
               let abs = absoluteURL(href, base: url) { return abs }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.path = "/favicon.ico"
            components.query = nil
            components.fragment = nil
            return components.url
        }()

        // 3. 抓取 favicon 数据（截断 256KB）。
        var faviconData: Data? = nil
        if let faviconURL {
            faviconData = await fetchData(faviconURL, limit: 256 * 1024)
        }
        return (title, faviconData)
    }

    /// 流式读取 URL 内容为 String（UTF-8，回退 Latin-1），截断到 512KB。
    nonisolated private static func fetchHTMLString(_ url: URL) async -> String? {
        guard let data = await fetchData(url, limit: 512 * 1024, htmlOnly: true) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// 通用下载：截断到 limit 字节。htmlOnly=true 时仅接受 text/html 响应。
    /// 用 URLSession.data(for:) 一次性获取后截断，替代 bytes 逐字节异步迭代。
    /// 之前的 `for try await byte in bytes` 逐字节迭代：512KB HTML = 524,288 次
    /// 异步挂起，每次挂起 ~微秒，总 CPU 开销 ~0.5s/请求。Apple 文档明确警告此模式。
    nonisolated private static func fetchData(_ initialURL: URL, limit: Int, htmlOnly: Bool = false) async -> Data? {
        var url = initialURL
        for redirectCount in 0...3 {
            guard LinkPreviewNetworkPolicy.allows(url) else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    if (300..<400).contains(http.statusCode) {
                        guard redirectCount < 3,
                              let location = http.value(forHTTPHeaderField: "Location"),
                              let nextURL = URL(string: location, relativeTo: url)?.absoluteURL else { return nil }
                        url = nextURL
                        continue
                    }
                    guard (200..<300).contains(http.statusCode) else { return nil }
                    if htmlOnly {
                        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                        // 仅接受 HTML（防止对图片/二进制跑 title 解析）。
                        guard contentType.contains("text/html")
                                || contentType.contains("application/xhtml") else { return nil }
                    }
                }
                // 截断到 limit 字节（title 通常在前 64KB，不需完整下载）
                if data.count > limit { return data.prefix(limit) }
                return data.isEmpty ? nil : data
            } catch {
                return nil
            }
        }
        return nil
    }

    // MARK: - HTML 解析

    /// 解析 <title>。返回去除首尾空白 + 基础实体反转义后的标题。
    nonisolated private static func parseTitle(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<title[^>]*>(.*?)</title>") else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: html) else { return nil }
        let raw = String(html[r])
        let unescaped = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let trimmed = unescaped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 从 <link> 标签中解析站点图标 href：apple-touch-icon 优先，其次 icon /
    /// shortcut icon。返回 HTML 中声明的（可能相对）href。
    nonisolated private static func parseIconHref(_ html: String) -> String? {
        guard let tagRegex = try? NSRegularExpression(pattern: "(?i)<link\\b[^>]*>") else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = tagRegex.matches(in: html, range: range)
        var appleTouch: String? = nil
        var generic: String? = nil
        for m in matches {
            guard let r = Range(m.range, in: html) else { continue }
            let tag = String(html[r])
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  let href = attribute("href", in: tag) else { continue }
            if rel.contains("apple-touch-icon") {
                if appleTouch == nil { appleTouch = href }
            } else if rel.contains("icon") {
                if generic == nil { generic = href }
            }
        }
        return appleTouch ?? generic
    }

    /// 提取标签属性值：支持 name="value" 与 name='value' 两种引号。
    nonisolated private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: name + "\\s*=\\s*([\"'])(.*?)\\1",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let m = regex.firstMatch(in: tag, range: range),
              m.numberOfRanges > 2,
              let r = Range(m.range(at: 2), in: tag) else { return nil }
        return String(tag[r])
    }

    /// 解析相对/协议相对 href 为绝对 URL。
    nonisolated private static func absoluteURL(_ href: String, base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") {
            return URL(string: (base.scheme ?? "https") + ":" + trimmed)
        }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }
}
