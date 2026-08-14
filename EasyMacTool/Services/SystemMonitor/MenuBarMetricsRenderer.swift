import AppKit

/// Builds the compact metric-block content shown next to the menu bar icon.
/// Each metric is drawn as a small image (label on top, value below) and
/// embedded into an attributed string as a text attachment, matching the
/// Vorssaint menu bar look.
enum MenuBarMetricsRenderer {
    private static let stackedFontSize: CGFloat = 9.4
    private static let singleLineFontSize: CGFloat = 11.6

    private static let blockImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private static func blockImageCost(_ image: NSImage) -> Int {
        max(1, Int(image.size.width * image.size.height) * 16)
    }

    static func statusFont(stacked: Bool) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: statusFontSize(stacked: stacked),
                                    weight: stacked ? .semibold : .medium)
    }

    static func statusFontSize(stacked: Bool) -> CGFloat {
        stacked ? stackedFontSize : singleLineFontSize
    }

    /// Returns true when any enabled metric has a reading to show.
    static func hasContent(for snapshot: SystemSnapshot, metrics: [MenuBarMetric]) -> Bool {
        !metrics.isEmpty && metrics.contains { valueAttributed(for: $0, snapshot: snapshot, temperatureUnit: .celsius) != nil }
    }

    /// Builds the attributed title for the enabled metrics separated by a
    /// light separator. Returns an empty string when nothing is available.
    static func attributed(for snapshot: SystemSnapshot,
                           metrics: [MenuBarMetric],
                           temperatureUnit: TemperatureUnit) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var first = true
        for metric in metrics {
            guard let value = valueAttributed(for: metric, snapshot: snapshot, temperatureUnit: temperatureUnit) else { continue }
            if !first {
                result.append(compactGap())
                result.append(verticalSeparator())
                result.append(compactGap())
            }
            first = false
            result.append(value)
        }
        if result.length == 0 { return result }
        result.addAttribute(.font,
                            value: statusFont(stacked: false),
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Renders a single metric as an attributed string (an image attachment).
    private static func valueAttributed(for metric: MenuBarMetric,
                                        snapshot: SystemSnapshot,
                                        temperatureUnit: TemperatureUnit) -> NSAttributedString? {
        switch metric {
        case .cpu:
            guard let usage = snapshot.cpuUsage else { return nil }
            return block(label: "CPU", value: MetricFormat.percent(usage), minimum: "100%")
        case .cpuTemperature:
            guard let temp = snapshot.cpuTemperature else { return nil }
            return block(label: "CPUº", value: compact(temp, unit: temperatureUnit), minimum: "999°")
        case .gpu:
            guard let usage = snapshot.gpuUsage else { return nil }
            return block(label: "GPU", value: MetricFormat.percent(usage), minimum: "100%")
        case .gpuTemperature:
            guard let temp = snapshot.gpuTemperature else { return nil }
            return block(label: "GPUº", value: compact(temp, unit: temperatureUnit), minimum: "999°")
        case .memory:
            return memoryBlock(snapshot: snapshot)
        case .network:
            guard let down = snapshot.netDownBytesPerSec, let up = snapshot.netUpBytesPerSec else { return nil }
            return networkBlock(down: down, up: up)
        case .diskUsage:
            guard let disk = primaryDisk(from: snapshot.disk) else { return nil }
            return block(label: "DSK", value: MetricFormat.percent(disk.usedFraction), minimum: "100%")
        case .power:
            guard let watts = snapshot.power?.systemWatts else { return nil }
            return block(label: "PWR", value: MetricFormat.wattsCompact(watts), minimum: "99W")
        case .fanSpeed:
            guard !snapshot.fanSpeeds.isEmpty else { return nil }
            let value = snapshot.fanSpeeds.map { String(Int($0.rounded())) }.joined(separator: "/")
            let minimum = Array(repeating: "20000", count: snapshot.fanSpeeds.count).joined(separator: "/")
            return block(label: "RPM", value: value, minimum: minimum)
        }
    }

    private static func compact(_ celsius: Double, unit: TemperatureUnit) -> String {
        MetricFormat.temperatureCompact(celsius, unit: unit)
    }

    private static func memoryBlock(snapshot: SystemSnapshot) -> NSAttributedString? {
        let value = MetricFormat.menuBarMemoryPercent(used: snapshot.memoryUsed, total: snapshot.memoryTotal)
        return block(label: "RAM", value: value, minimum: "100%", pressure: snapshot.memoryPressure)
    }

    private static func primaryDisk(from reading: DiskReading?) -> DiskDeviceReading? {
        guard let devices = reading?.devices, !devices.isEmpty else { return nil }
        return devices.first(where: { $0.isInternal }) ?? devices.first
    }

    // MARK: - Block drawing

    private static func block(label: String,
                              value: String,
                              minimum: String,
                              pressure: MemoryPressure? = nil) -> NSAttributedString? {
        let labelFont = NSFont.systemFont(ofSize: 6.6, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .semibold)
        let sizingLabel: [NSAttributedString.Key: Any] = [.font: labelFont]
        let sizingValue: [NSAttributedString.Key: Any] = [.font: valueFont]
        let labelSize = (label as NSString).size(withAttributes: sizingLabel)
        let valueSize = (value as NSString).size(withAttributes: sizingValue)
        let minValueSize = (minimum as NSString).size(withAttributes: sizingValue)
        let dotDiameter: CGFloat = pressure == nil ? 0 : 4.8
        let dotGap: CGFloat = pressure == nil || value.isEmpty ? 0 : 4
        let reservedValueWidth = max(valueSize.width, minValueSize.width)
        let reservedGroupWidth = dotDiameter + dotGap + reservedValueWidth
        let drawnGroupWidth = dotDiameter + dotGap + valueSize.width
        let width = ceil(max(labelSize.width, reservedGroupWidth) + 0.5)
        let height: CGFloat = 21

        let cacheKey = "metric|\(label)|\(value)|\(minimum)|\(pressure.map(String.init(describing:)) ?? "none")" as NSString
        if let cached = blockImageCache.object(forKey: cacheKey) {
            return attachment(image: cached)
        }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.labelColor]
            let valueAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.labelColor]
            (label as NSString).draw(at: NSPoint(x: (width - labelSize.width) / 2, y: 12.0),
                                     withAttributes: labelAttrs)
            var valueX = (width - drawnGroupWidth) / 2
            if let pressure {
                let dotRect = NSRect(x: valueX, y: 3.5, width: dotDiameter, height: dotDiameter)
                MenuBarMetricsRenderer.nsColor(for: pressure).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                valueX += dotDiameter + dotGap
            }
            (value as NSString).draw(at: NSPoint(x: valueX, y: -0.8), withAttributes: valueAttrs)
            return true
        }
        image.isTemplate = false
        blockImageCache.setObject(image, forKey: cacheKey, cost: blockImageCost(image))
        return attachment(image: image)
    }

    private static func networkBlock(down: Double, up: Double) -> NSAttributedString? {
        let downText = MetricFormat.bytesPerSecCompact(down)
        let upText = MetricFormat.bytesPerSecCompact(up)
        let font = NSFont.monospacedSystemFont(ofSize: 9.2, weight: .semibold)
        let lineHeight: CGFloat = 10.0
        let height: CGFloat = 20
        let lines = ["↓\(downText)", "↑\(upText)"]
        let reserved = ["↓8888M", "↑8888M"]
        let sizing: [NSAttributedString.Key: Any] = [.font: font]
        let contentWidth = reserved.map { ($0 as NSString).size(withAttributes: sizing).width }.max() ?? 22
        let width = ceil(contentWidth + 1.0)
        let cacheKey = "network|\(downText)|\(upText)" as NSString
        if let cached = blockImageCache.object(forKey: cacheKey) {
            return attachment(image: cached)
        }
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let textSize = ((lines.first ?? "") as NSString).size(withAttributes: attrs)
            let contentHeight = lineHeight + textSize.height
            let bottomY = (height - contentHeight) / 2
            for (index, line) in lines.enumerated() {
                let y = bottomY + lineHeight * CGFloat(1 - index)
                let lineSize = (line as NSString).size(withAttributes: attrs)
                (line as NSString).draw(at: NSPoint(x: max(0.5, width - lineSize.width - 0.5), y: y),
                                        withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = false
        blockImageCache.setObject(image, forKey: cacheKey, cost: blockImageCost(image))
        return attachment(image: image)
    }

    private static func attachment(image: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -5.5, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// A slim horizontal gap used between metric blocks for a compact breathing space.
    private static func compactGap() -> NSAttributedString {
        NSAttributedString(string: " ",
                           attributes: [.foregroundColor: NSColor.clear])
    }

    /// A thin vertical divider line placed between metric blocks.
    private static var separatorImage: NSImage = {
        let height: CGFloat = 13
        let width: CGFloat = 5
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            let lineX = floor((width - 1) / 2)
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: lineX, y: 3, width: 1, height: height - 6).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()

    private static func verticalSeparator() -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = separatorImage
        attachment.bounds = NSRect(x: 0, y: -5.5, width: separatorImage.size.width, height: separatorImage.size.height)
        return NSAttributedString(attachment: attachment)
    }

    static func nsColor(for pressure: MemoryPressure) -> NSColor {
        switch pressure {
        case .normal: return .systemGreen
        case .warning: return .systemYellow
        case .critical: return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }
}