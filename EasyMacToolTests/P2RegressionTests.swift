import Darwin
import Testing
@testable import EasyMacTool

@Suite("P2 performance and boundary regressions")
struct P2RegressionTests {
    @Test func processPathIndexUsesNearestEnclosingApplication() {
        let index = ProcessPathOwnerIndex([
            (prefix: "/Applications/Editor.app/", pid: pid_t(10)),
            (prefix: "/Applications/Editor.app/Contents/PlugIns/Preview.app/", pid: pid_t(20)),
        ])

        #expect(index.ownerPID(for: "/Applications/Editor.app/Contents/MacOS/Editor") == 10)
        #expect(index.ownerPID(for: "/Applications/Editor.app/Contents/Frameworks/Helper") == 10)
        #expect(index.ownerPID(for: "/Applications/Editor.app/Contents/PlugIns/Preview.app/Contents/MacOS/Preview") == 20)
        #expect(index.ownerPID(for: "/Applications/Other.app/Contents/MacOS/Other") == nil)
        #expect(index.ownerPID(for: "Applications/Editor.app/Contents/MacOS/Editor") == nil)
    }

    @Test func compactByteFormattingHandlesRoundingAcrossUnitBoundaries() {
        #expect(MetricFormat.bytesPerSecCompact(1023.4) == "1023B")
        #expect(MetricFormat.bytesPerSecCompact(1023.5) == "1.0K")
        #expect(MetricFormat.bytesPerSecCompact(1023.9) == "1.0K")
        #expect(MetricFormat.bytesPerSecCompact(1024 * 1023.5) == "1.0M")
    }

    @Test func multiDigitAppleSiliconNameDoesNotMasqueradeAsM1() {
        #expect(TemperatureSensorSelector.platform(brandString: "Apple M1") == .appleM1Family)
        #expect(TemperatureSensorSelector.platform(brandString: "Apple M1 Pro") == .appleM1Family)
        #expect(TemperatureSensorSelector.platform(brandString: "Apple M10") == .generic)
    }

    @Test func temperatureStabilizationHonorsBoundsAndExpiresCachedValues() {
        var cache: CachedSensorReading?
        #expect(TemperatureSensorSelector.stabilizedTemperature(
            1.0, cache: &cache, now: 0, maxAge: 10, minimum: 1
        ) == nil)
        #expect(TemperatureSensorSelector.stabilizedTemperature(
            1.1, cache: &cache, now: 1, maxAge: 10, minimum: 1
        ) == 1.1)
        #expect(TemperatureSensorSelector.stabilizedTemperature(
            125, cache: &cache, now: 2, maxAge: 10, minimum: 1
        ) == 1.1)
        for second in 3...5 {
            _ = TemperatureSensorSelector.stabilizedTemperature(
                nil, cache: &cache, now: Double(second), maxAge: 10, minimum: 1
            )
        }
        #expect(TemperatureSensorSelector.stabilizedTemperature(
            nil, cache: &cache, now: 6, maxAge: 10, minimum: 1
        ) == nil)
    }

    @MainActor @Test func largeClipboardTextSearchIsCaseAndDiacriticInsensitive() {
        let text = String(repeating: "prefix ", count: 3_000) + "CAFÉ Needle"
        let item = ClipboardItem(kind: .text(text))
        #expect(item.matchesSearch("cafe needle"))
        #expect(!item.matchesSearch("missing value"))
    }

    @MainActor @Test func processMemorySamplingDoesNotTrapOnRusageBuffer() {
        let candidates = AppMemorySampler.captureCandidates()
        _ = AppMemorySampler.sample(candidates: Array(candidates.prefix(1)), limit: 1)
    }
}
