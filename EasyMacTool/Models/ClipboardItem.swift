import AppKit
import CoreGraphics
import Foundation

/// A single entry in the clipboard history. Captured at the moment the system
/// pasteboard changes. Stores enough to render a rich preview (Paste-style)
/// and to restore the original payload when the user re-selects it.
@MainActor
final class ClipboardItem: Identifiable {
    let id: UUID
    let createdAt: Date
    let kind: Kind

    /// Originating app metadata — drives the card header background tint and
    /// the leading app icon shown on each card.
    let sourceAppIcon: NSImage?
    let sourceAppName: String?
    let sourceAppTint: NSColor

    /// 富文本 RTF 数据：若文本是从支持富文本的应用（如 VSCode、Pages、
    /// Safari）复制的，保留其 RTF 数据以在卡片中还原颜色/字体样式。
    /// 仅 .text kind 会有值；其他 kind 为 nil。
    let rtfData: Data?

    enum Kind {
        case text(String)
        case url(URL, title: String?)
        case image(NSImage)
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
         sourceAppIcon: NSImage? = nil,
         sourceAppName: String? = nil,
         // Safe sRGB fallback — never a catalog color, so component accessors
         // (redComponent etc.) always work without a color-space conversion.
         sourceAppTint: NSColor = NSColor(red: 0x0A/255.0,
                                          green: 0x84/255.0,
                                          blue: 0xFF/255.0,
                                          alpha: 1.0),
         rtfData: Data? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.sourceAppIcon = sourceAppIcon
        self.sourceAppName = sourceAppName
        self.sourceAppTint = sourceAppTint
        self.rtfData = rtfData
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

    /// SF Symbol used when no richer preview applies.
    var symbolName: String {
        switch kind {
        case .text: return "doc.text"
        case .url: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .color: return "paintpalette"
        }
    }

    /// Footer statistic shown in the transparent floating strip at the bottom
    /// of each card. Centered, single line.
    /// - 文本: 字数统计 (e.g. "123 字")
    /// - 文件: 文件路径 (truncated)
    /// - 图片: 像素比例 (e.g. "1920×1080")
    /// - 链接: 主机名
    /// - 颜色: 十六进制 + RGB
    var footerText: String {
        switch kind {
        case .text(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let chars = trimmed.count
            let lines = s.split(separator: "\n", omittingEmptySubsequences: true).count
            return lines > 1 ? "\(chars) 字 · \(lines) 行" : "\(chars) 字"
        case .url(let url, _):
            return url.host ?? url.absoluteString
        case .image(let img):
            return "\(Int(img.size.width)) × \(Int(img.size.height)) px"
        case .file(let urls):
            if let first = urls.first {
                let path = first.deletingLastPathComponent().path
                return truncateMiddle(path, max: 30)
            }
            return "\(urls.count) 个文件"
        case .color(let color, let hex):
            let rgb = "\(Int(color.redComponent * 255)), \(Int(color.greenComponent * 255)), \(Int(color.blueComponent * 255))"
            return "\(hex.uppercased()) · RGB(\(rgb))"
        }
    }

    /// Renders the item back onto the system pasteboard on re-selection.
    func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        switch kind {
        case .text(let s):
            pasteboard.setString(s, forType: .string)
        case .url(let url, _):
            pasteboard.setString(url.absoluteString, forType: .string)
            pasteboard.setPropertyList([url.absoluteString], forType: .URL)
        case .image(let img):
            if let tiff = img.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
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
        let r = Int(round(color.redComponent * 255))
        let g = Int(round(color.greenComponent * 255))
        let b = Int(round(color.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
