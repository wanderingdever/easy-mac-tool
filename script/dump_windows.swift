import AppKit
import ApplicationServices

// 诊断工具：
// 1) 列出当前屏幕上所有窗口的 owner / windowID / layer / 标题 / frame，
//    用于验证 WindowEnumerator 的弹出层过滤（信号 1/2/3）是否正确分类。
// 2) `--ax <app名>`：对匹配 app 输出 AX 诊断——kAXHiddenAttribute（Cmd+H 隐藏
//    状态）、kAXWindowsAttribute 窗口数、每个窗口的 AXWindowID / 标题 /
//    kAXMinimizedAttribute。用于定位"隐藏/最小化窗口不可见"的断点。
//
// 用法：
//   swift script/dump_windows.swift                  # 全部窗口
//   swift script/dump_windows.swift Edge             # 只看进程名含 "Edge" 的
//   swift script/dump_windows.swift --ax 微信        # AX 诊断（隐藏微信后运行）
//
// 复现 Edge 地址栏下拉时：先在地址栏输入保持下拉展开，再到终端运行本脚本
// （下拉在切换焦点时会关闭，建议用 `sleep 5 && swift ...` 延迟执行）。

let args = CommandLine.arguments
let axMode = args.firstIndex(of: "--ax") != nil
let filter = args.dropFirst().first(where: { $0 != "--ax" })?.lowercased()

// MARK: - AX 诊断模式

if axMode {
    print("== AX 诊断模式 ==")
    guard AXIsProcessTrusted() else {
        print("FAIL: 辅助功能权限未授予（AXIsProcessTrusted == false），AX 查询会全部失败。")
        exit(1)
    }
    var foundAny = false
    for app in NSWorkspace.shared.runningApplications {
        guard let name = app.localizedName else { continue }
        if let filter, !name.lowercased().contains(filter) { continue }
        let pid = app.processIdentifier
        foundAny = true

        // kAXHiddenAttribute：app 是否被 Cmd+H 隐藏
        let axApp = AXUIElementCreateApplication(pid)
        var hiddenRef: CFTypeRef?
        let hiddenResult = AXUIElementCopyAttributeValue(axApp, kAXHiddenAttribute as CFString, &hiddenRef)
        let hidden = (hiddenResult == .success) ? ((hiddenRef as? NSNumber)?.boolValue ?? false) : nil
        print("\n[\(name)] pid=\(pid) NSRunningApplication.isHidden=\(app.isHidden) "
              + "AXHidden=\(hidden.map(String.init) ?? "查询失败(\(hiddenResult.rawValue))")")

        // kAXWindowsAttribute：窗口列表
        var windowsRef: CFTypeRef?
        let winResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard winResult == .success, let axWindows = windowsRef as? [AXUIElement] else {
            print("   kAXWindowsAttribute 查询失败(\(winResult.rawValue)) 或返回非数组 → 窗口枚举不到")
            continue
        }
        if axWindows.isEmpty {
            print("   kAXWindowsAttribute 返回空数组 → 隐藏后窗口从 AX 树移除")
        }
        print("   kAXWindowsAttribute 窗口数: \(axWindows.count)")
        for (i, window) in axWindows.enumerated() {
            var idRef: CFTypeRef?
            let idResult = AXUIElementCopyAttributeValue(window, "AXWindowID" as CFString, &idRef)
            let wid = (idResult == .success) ? (idRef as? NSNumber)?.uint32Value : nil
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? "(无标题)"
            var minRef: CFTypeRef?
            let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef)
            let minimized = (minResult == .success) ? ((minRef as? NSNumber)?.boolValue ?? false) : nil
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            var pos = CGPoint.zero
            var size = CGSize.zero
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
               let v = posRef, CFGetTypeID(v) == AXValueGetTypeID() {
                AXValueGetValue(v as! AXValue, .cgPoint, &pos)
            }
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let v = sizeRef, CFGetTypeID(v) == AXValueGetTypeID() {
                AXValueGetValue(v as! AXValue, .cgSize, &size)
            }
            print("   [\(i)] windowID=\(wid.map(String.init) ?? "nil") minimized=\(minimized.map(String.init) ?? "失败(\(minResult.rawValue))") title=\"\(title)\" frame=(\(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height)))")
        }
    }
    if !foundAny {
        print("未找到匹配的 app（进程名含 '\(filter ?? "")'）。")
    }
    exit(0)
}

// MARK: - 普通窗口列表模式

guard let array = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
) as? [[String: Any]] else {
    print("FAIL: CGWindowListCopyWindowInfo returned nil")
    exit(1)
}

struct Row {
    let owner: String
    let pid: pid_t
    let id: Int
    let layer: Int
    let title: String
    let frame: CGRect
}

var rows: [Row] = []
for info in array {
    guard let id = info[kCGWindowNumber as String] as? Int,
          let layer = info[kCGWindowLayer as String] as? Int,
          let pid = info[kCGWindowOwnerPID as String] as? Int32,
          let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
          let x = bounds["X"], let y = bounds["Y"],
          let w = bounds["Width"], let h = bounds["Height"] else { continue }
    let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
    if let filter, !owner.lowercased().contains(filter) { continue }
    let title = info[kCGWindowName as String] as? String ?? ""
    rows.append(Row(owner: owner, pid: pid, id: id, layer: layer,
                    title: title, frame: CGRect(x: x, y: y, width: w, height: h)))
}

// 按 owner + layer 排序，弹出层（layer != 0 / 无标题高重叠）一目了然
rows.sort { ($0.owner, $0.layer, $0.id) < ($1.owner, $1.layer, $1.id) }

print(String(format: "%-22@ %6@ %8@ %5@ %-40@ %@", "OWNER", "PID", "ID", "LAYER", "TITLE", "FRAME"))
for r in rows {
    let title = r.title.isEmpty ? "(无标题)" : String(r.title.prefix(38))
    let frame = String(format: "(%.0f,%.0f %.0fx%.0f)",
                       r.frame.origin.x, r.frame.origin.y,
                       r.frame.size.width, r.frame.size.height)
    print(String(format: "%-22@ %6d %8d %5d %-40@ %@",
                 r.owner as NSString, r.pid, r.id, r.layer, title as NSString, frame))
}
print("\n共 \(rows.count) 个窗口")
