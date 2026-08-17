import AppKit
import Foundation

/// Formats a `Date` as a Chinese relative-time string:
/// - < 1 minute: 刚刚
/// - < 1 hour: N分钟前
/// - < 24 hours (same day): N小时前
/// - yesterday: 昨天
/// - day before yesterday: 前天
/// - older this week: N天前 (3天前 … 5天前 …)
/// - older: absolute short date (e.g. 6月12日)
enum RelativeTimeFormatter {
    /// 复用 DateFormatter：初始化昂贵，每张剪贴板卡片渲染都会调用，
    /// 之前每次新建导致历史较多时性能浪费。
    private static let absoluteDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日"
        return fmt
    }()

    static func string(from date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "刚刚"
        }
        if interval < 3600 {
            let m = Int(interval / 60)
            return "\(m)分钟前"
        }
        // Use calendar day difference so "yesterday" / "前天" align with the
        // user's wall clock rather than raw seconds.
        let dayDiff = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        if dayDiff == 0 {
            let h = Int(interval / 3600)
            return "\(h)小时前"
        }
        if dayDiff == 1 { return "昨天" }
        if dayDiff == 2 { return "前天" }
        if dayDiff < 7 {
            return "\(dayDiff)天前"
        }
        // Beyond a week: fall back to an absolute date without year.
        return Self.absoluteDateFormatter.string(from: date)
    }
}

/// Extracts a representative accent color from an app icon. Strategy:
/// downsample the icon, walk its pixels, and compute a saturation-weighted
/// average so we pick the most "colorful" color (ignoring near-white / near-
/// black / near-transparent backgrounds that most macOS icons sit on).
///
/// Results are cached per bundle identifier so the expensive pixel-walk only
/// happens once per app — subsequent snapshots from the same app hit the
/// cache and return instantly, avoiding main-thread stalls.
enum AppTintExtractor {
    /// Thread-safe cache: bundleIdentifier → tint color.
    /// 设置 countLimit=200 限制缓存上限，避免菜单栏 app 长期运行累积所有
    /// 启动过的 app 色调导致内存无限增长。NSCache 在内存压力时也会自动淘汰。
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSColor> = {
        let c = NSCache<NSString, NSColor>()
        c.countLimit = 200
        return c
    }()

    /// Returns the cached tint for the given bundle ID, or extracts it
    /// synchronously if not cached. The extraction is fast (~1ms) but
    /// happens at most once per app thanks to the cache.
    nonisolated static func tint(from icon: NSImage, bundleIdentifier: String? = nil) -> NSColor {
        if let bid = bundleIdentifier, let cached = cache.object(forKey: bid as NSString) {
            return cached
        }
        let result = extract(from: icon)
        if let bid = bundleIdentifier {
            cache.setObject(result, forKey: bid as NSString)
        }
        return result
    }

    nonisolated private static func extract(from icon: NSImage) -> NSColor {
        // Work at a small size — we only need an approximate hue.
        let sampleSize = 32
        let target = NSSize(width: sampleSize, height: sampleSize)
        guard let rep = icon.bestRepresentation(for: NSRect(origin: .zero, size: target),
                                                context: nil, hints: nil) as? NSBitmapImageRep
        else { return Self.fallbackTint }

        var totalR: CGFloat = 0
        var totalG: CGFloat = 0
        var totalB: CGFloat = 0
        var totalWeight: CGFloat = 0

        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                // Convert to sRGB before reading components — colorAt may
                // return a color in a non-RGB space (e.g. gray) whose
                // redComponent raises an exception.
                guard let rgb = color.usingColorSpace(.sRGB) else { continue }
                // Skip fully transparent pixels (icon rounded corners).
                if rgb.alphaComponent < 0.5 { continue }
                let r = rgb.redComponent
                let g = rgb.greenComponent
                let b = rgb.blueComponent

                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let brightness = maxC
                let saturation = maxC > 0 ? (maxC - minC) / maxC : 0

                // Weight by saturation (favor colorful pixels) and downweight
                // extreme brightness extremes (near-white/near-black).
                var weight = saturation * saturation
                if brightness > 0.92 { weight *= 0.2 }
                if brightness < 0.08 { weight *= 0.2 }
                if weight < 0.01 { continue }

                totalR += r * weight
                totalG += g * weight
                totalB += b * weight
                totalWeight += weight
            }
        }

        guard totalWeight > 0 else { return Self.fallbackTint }
        return NSColor(red: totalR / totalWeight,
                       green: totalG / totalWeight,
                       blue: totalB / totalWeight,
                       alpha: 1.0)
    }

    /// A safe sRGB fallback — never a catalog color so component accessors
    /// (redComponent etc.) always work.
    nonisolated private static let fallbackTint = NSColor(red: 0x0A/255.0,
                                             green: 0x84/255.0,
                                             blue: 0xFF/255.0,
                                             alpha: 1.0)
}

/// Parses color strings (hex / rgb()/hsl()) into an `NSColor`. Recognizes the
/// common formats designers copy from color pickers:
/// - #RGB, #RRGGBB, #RRGGBBAA
/// - rgb(255, 0, 0), rgba(255, 0, 0, 0.5)
/// - hsl(0, 100%, 50%)
nonisolated enum ColorStringParser {
    /// Returns (color, hex) if the string parses as a recognizable color,
    /// otherwise nil.
    static func parse(_ text: String) -> (NSColor, String)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Hex: #RGB or #RRGGBB or #RRGGBBAA
        if s.hasPrefix("#") {
            return parseHex(s)
        }
        // rgb() / rgba()
        if s.lowercased().hasPrefix("rgb") {
            return parseRGB(s)
        }
        // hsl() / hsla()
        if s.lowercased().hasPrefix("hsl") {
            return parseHSL(s)
        }
        // Bare 6-digit hex without #
        if s.count == 6, s.allSatisfy({ $0.isHexDigit }) {
            return parseHex("#" + s)
        }
        return nil
    }

    private static func parseHex(_ s: String) -> (NSColor, String)? {
        var hex = s
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        switch hex.count {
        case 3:
            // #RGB → #RRGGBB (each digit doubled)
            let chars = Array(hex)
            r = CGFloat(hexPair(String(repeating: chars[0], count: 2))) / 255
            g = CGFloat(hexPair(String(repeating: chars[1], count: 2))) / 255
            b = CGFloat(hexPair(String(repeating: chars[2], count: 2))) / 255
        case 6:
            let chars = Array(hex)
            r = CGFloat(hexPair(String(chars[0..<2]))) / 255
            g = CGFloat(hexPair(String(chars[2..<4]))) / 255
            b = CGFloat(hexPair(String(chars[4..<6]))) / 255
        case 8:
            let chars = Array(hex)
            r = CGFloat(hexPair(String(chars[0..<2]))) / 255
            g = CGFloat(hexPair(String(chars[2..<4]))) / 255
            b = CGFloat(hexPair(String(chars[4..<6]))) / 255
            a = CGFloat(hexPair(String(chars[6..<8]))) / 255
        default:
            return nil
        }
        let color = NSColor(red: r, green: g, blue: b, alpha: a)
        // Canonical hex for display / re-paste: always #RRGGBB (drop alpha for
        // brevity in the title; alpha still restores if present).
        let displayHex = String(format: "#%02X%02X%02X",
                                Int(round(r * 255)),
                                Int(round(g * 255)),
                                Int(round(b * 255)))
        return (color, displayHex)
    }

    /// Parses a 2-character hex string (e.g. "FF") into a 0–255 integer.
    /// Returns 0 if the input is invalid.
    private static func hexPair(_ s: String) -> Int {
        Int(s, radix: 16) ?? 0
    }

    private static func parseRGB(_ s: String) -> (NSColor, String)? {
        let inner = extractParenContent(s)
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard (3...4).contains(parts.count),
              let r = Double(parts[0]),
              let g = Double(parts[1]),
              let b = Double(parts[2]),
              [r, g, b].allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
        let a: Double
        if parts.count == 4 {
            guard let parsedAlpha = Double(parts[3]), parsedAlpha.isFinite,
                  (0...1).contains(parsedAlpha) else { return nil }
            a = parsedAlpha
        } else {
            a = 1
        }
        // CSS rgb() numeric channels are always 0...255; rgb(1, 0, 0) is not
        // the normalized equivalent of rgb(255, 0, 0).
        let color = NSColor(red: CGFloat(r / 255), green: CGFloat(g / 255),
                            blue: CGFloat(b / 255), alpha: CGFloat(a))
        let displayHex = String(format: "#%02X%02X%02X",
                                Int(round(r)), Int(round(g)), Int(round(b)))
        return (color, displayHex)
    }

    private static func parseHSL(_ s: String) -> (NSColor, String)? {
        let inner = extractParenContent(s)
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let h = Double(parts[0]),
              let sVal = Double(parts[1].replacingOccurrences(of: "%", with: "")),
              let lVal = Double(parts[2].replacingOccurrences(of: "%", with: "")) else { return nil }
        let color = NSColor(hue: CGFloat(h / 360),
                            saturation: CGFloat(sVal / 100),
                            brightness: CGFloat(lVal / 100),
                            alpha: 1)
        // Convert to RGB for hex display.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let displayHex = String(format: "#%02X%02X%02X",
                                Int(round(r * 255)),
                                Int(round(g * 255)),
                                Int(round(b * 255)))
        return (color, displayHex)
    }

    private static func extractParenContent(_ s: String) -> String {
        guard let open = s.firstIndex(of: "("),
              let close = s.lastIndex(of: ")") else { return "" }
        return String(s[s.index(after: open)..<close])
    }
}

/// Caches app icons by bundle identifier so ClipboardItem doesn't need to
/// hold its own NSImage copy per entry. Without this cache, copying 100
/// items from the same app would retain 100 copies of its icon NSImage.
///
/// Lookup is O(1) on cache hit; on miss it scans NSWorkspace.runningApplications
/// (acceptable since most apps are cached after first hit).
@MainActor
enum AppIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // 200 个 app 图标 × ~128×128×4 = ~12MB 上限，避免长期运行内存无限增长。
        // NSCache 在内存压力时也会自动淘汰。
        c.countLimit = 200
        return c
    }()

    /// Returns the cached icon for the given bundle ID, or looks it up from
    /// NSWorkspace and caches it. Returns nil for unknown / not-running apps.
    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        // Scan running applications for the matching bundle ID.
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
              let icon = app.icon else { return nil }
        cache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }

    /// Pre-warms the cache for the given bundle ID + icon pair (used when
    /// ClipboardManager captures the source app icon at snapshot time — we
    /// already have the icon, no need to re-scan running apps).
    static func prewarm(_ icon: NSImage, for bundleID: String?) {
        guard let bundleID else { return }
        if cache.object(forKey: bundleID as NSString) == nil {
            cache.setObject(icon, forKey: bundleID as NSString)
        }
    }
}
