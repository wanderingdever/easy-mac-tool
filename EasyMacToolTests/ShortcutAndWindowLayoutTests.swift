import CoreGraphics
import Foundation
import Testing
@testable import EasyMacTool

@Suite("Shortcut and window layout policies")
struct ShortcutAndWindowLayoutTests {
    @Test func blocksReservedSystemShortcutsOnlyOnExactModifiers() {
        #expect(AppSettings.isReservedSystemCombo(keyCode: 0x0C, modifiers: .maskCommand))
        #expect(AppSettings.isReservedSystemCombo(
            keyCode: 0x35, modifiers: [.maskCommand, .maskAlternate]
        ))
        #expect(!AppSettings.isReservedSystemCombo(
            keyCode: 0x0C, modifiers: [.maskCommand, .maskShift]
        ))
    }

    @MainActor @Test func globalShortcutConflictRejectsLayoutConflictsAndHonorsExclusion() {
        let layout = LayoutShortcut(action: .leftHalf, keyCode: 0x30, modifiers: .maskCommand)
        #expect(AppSettings.globalShortcutConflictDescription(
            keyCode: 0x30,
            modifiers: .maskCommand,
            switcherShortcuts: [],
            clipboardShortcut: nil,
            layoutShortcuts: [layout],
            excludingWindowShortcutID: nil
        ) == "已被窗口布局「左半屏」使用")
        #expect(AppSettings.layoutShortcutConflictDescription(
            keyCode: 0x30,
            modifiers: .maskCommand,
            excludingAction: .leftHalf,
            shortcuts: [layout]
        ) == nil)
    }

    @MainActor @Test func globalShortcutConflictChecksSwitcherAndClipboardShortcuts() {
        let switcher = ShortcutConfig(name: "测试", keyCode: 0x30, modifiers: .maskCommand)
        #expect(AppSettings.globalShortcutConflictDescription(
            keyCode: 0x30,
            modifiers: .maskCommand,
            switcherShortcuts: [switcher],
            clipboardShortcut: nil,
            layoutShortcuts: [],
            excludingWindowShortcutID: nil
        ) == "已被窗口切换快捷键「测试」使用")

        let clipboard = ShortcutConfig(name: "剪贴板", keyCode: 0x09, modifiers: [.maskCommand, .maskShift])
        #expect(AppSettings.globalShortcutConflictDescription(
            keyCode: 0x09,
            modifiers: [.maskCommand, .maskShift],
            switcherShortcuts: [],
            clipboardShortcut: clipboard,
            layoutShortcuts: [],
            excludingWindowShortcutID: nil
        ) == "已被剪切板快捷键使用")
    }

    @Test func fallbackWindowIDIsStableAndUsesMarkerBits() {
        let first = WindowEnumerator.fallbackWindowID(pid: 42, title: "T", windowIndex: 0)
        let second = WindowEnumerator.fallbackWindowID(pid: 42, title: "T", windowIndex: 0)
        #expect(first == second)
        #expect(first & 0xF0000000 == 0xF0000000)
        #expect(first != WindowEnumerator.fallbackWindowID(pid: 43, title: "T", windowIndex: 0))
        #expect(first != WindowEnumerator.fallbackWindowID(pid: 42, title: "T", windowIndex: 1))
    }

    @MainActor @Test func shortcutConfigBackwardCompatibilityDefaultsNewFields() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "默认",
          "keyCode": 48,
          "modifiersRaw": 1048576,
          "showMinimized": false,
          "showHidden": false,
          "currentSpaceOnly": true,
          "releaseBehavior": "focus",
          "previewSize": "small",
          "isDefault": true
        }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ShortcutConfig.self, from: data)

        #expect(decoded.showFullscreen)
        #expect(decoded.showWindowless)
        #expect(!decoded.showMainWindowOnly)
        #expect(decoded.screensToShow == .all)
        #expect(decoded.tabGrouping == .singleWindow)
        #expect(decoded.appsToShow == .all)
        #expect(decoded.windowOrder == .recentlyFocused)
    }

    @Test func normalizesInvalidMonitorIntervals() {
        #expect(AppSettings.normalizedMonitorInterval(-10) == 1)
        #expect(AppSettings.normalizedMonitorInterval(0) == 1)
        #expect(AppSettings.normalizedMonitorInterval(5) == 5)
    }

    @Test func mapsRadialAnglesAcrossWraparound() {
        #expect(RadialSector.sector(forAngleDegrees: 0) == .right)
        #expect(RadialSector.sector(forAngleDegrees: 90) == .top)
        #expect(RadialSector.sector(forAngleDegrees: -90) == .bottom)
        #expect(RadialSector.sector(forAngleDegrees: 359) == .right)
    }

    @Test func formatsTheNonContiguousANSIKeypadRow() {
        let codes: [CGKeyCode] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        for (digit, code) in codes.enumerated() {
            #expect(KeyComboFormatter.format(keyCode: code, modifiers: []) == String(digit))
        }
        #expect(KeyComboFormatter.format(keyCode: 0x1E, modifiers: []) == "Key30")
    }

    @Test func preservesNegativeScreenOrigins() {
        let screen = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        #expect(WindowLayoutManager.targetFrame(for: .leftHalf, visibleFrame: screen)
            == CGRect(x: -1920, y: 120, width: 960, height: 1080))
        #expect(WindowLayoutManager.targetFrame(for: .topRight, visibleFrame: screen)
            == CGRect(x: -960, y: 660, width: 960, height: 540))
        #expect(WindowLayoutManager.targetFrame(for: .fullScreen, visibleFrame: screen) == screen)
    }

    @Test func metricHistoryKeepsOldestToNewestOrderWithoutShifting() {
        var history = MetricHistory(capacity: 3)
        history.push(1)
        history.push(2)
        #expect(history.values == [1, 2])
        history.push(3)
        history.push(4)
        #expect(history.values == [2, 3, 4])
        history.push(5)
        #expect(history.values == [3, 4, 5])
    }

    @MainActor @Test func parsesCSSRGBChannelsWithoutAmbiguousNormalization() throws {
        let (_, darkRedHex) = try #require(ColorStringParser.parse("rgb(1, 0, 0)"))
        #expect(darkRedHex == "#010000")
        let (_, redHex) = try #require(ColorStringParser.parse("rgba(255, 0, 0, 0.5)"))
        #expect(redHex == "#FF0000")
        #expect(ColorStringParser.parse("rgb(256, 0, 0)") == nil)
        #expect(ColorStringParser.parse("rgba(0, 0, 0, 2)") == nil)
    }
}
