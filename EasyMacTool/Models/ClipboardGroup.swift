import Foundation
import SwiftUI

/// 分组调色板：一组可辨识的标识色（sRGB，直接可作 SwiftUI Color/NSColor）。
/// 新建分组按 colorIndex 依次分配，用于 Tag 圆点与卡片角标区分不同分组。
enum ClipboardGroupPalette {
    static let count = colors.count
    static let colors: [Color] = [
        Color(red: 0xE2/255, green: 0x6A/255, blue: 0x8A/255),   // 粉
        Color(red: 0x4A/255, green: 0x90/255, blue: 0xE2/255),   // 蓝
        Color(red: 0x4A/255, green: 0xC8/255, blue: 0x9A/255),   // 绿
        Color(red: 0x6A/255, green: 0x5A/255, blue: 0xD4/255),   // 紫
        Color(red: 0xE8/255, green: 0xA8/255, blue: 0x4A/255),   // 橙
        Color(red: 0x4A/255, green: 0xB8/255, blue: 0xD4/255),   // 青
    ]
    static func color(_ index: Int) -> Color {
        colors[((index % count) + count) % count]
    }
}

/// 剪贴板分组：一组可命名的文件夹，条目通过 `ClipboardItem.groupID` 归属。
/// 分组取代了旧的「置顶」标记——条目不再靠布尔标记排到最前，而是分类到分组中。
struct ClipboardGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    /// 分组标识色（预设调色板索引）。新建分组时按顺序分配，用于 Tag 与
    /// 卡片角标区分不同分组。
    var colorIndex: Int

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), colorIndex: Int = 0) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.colorIndex = colorIndex
    }

    // MARK: - Codable（向后兼容旧存档：无 colorIndex 字段 → 默认 0）
    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, colorIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(colorIndex, forKey: .colorIndex)
    }
}