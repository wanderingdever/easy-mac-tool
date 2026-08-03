import AppKit

// 诊断工具：列出当前屏幕上所有窗口的 owner / windowID / layer / 标题 / frame，
// 用于验证 WindowEnumerator 的弹出层过滤（信号 1/2/3）是否正确分类。
//
// 用法：
//   swift script/dump_windows.swift            # 全部窗口
//   swift script/dump_windows.swift Edge       # 只看进程名含 "Edge" 的
//
// 复现 Edge 地址栏下拉时：先在地址栏输入保持下拉展开，再到终端运行本脚本
// （下拉在切换焦点时会关闭，建议用 `sleep 5 && swift ...` 延迟执行）。

let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : nil

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
