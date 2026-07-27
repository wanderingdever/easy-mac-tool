import Foundation

/// 单次采样的系统指标快照。所有字段 Optional，采集失败为 nil，
/// UI 静默隐藏对应项不报错（机型差异 / 虚拟机 SMC 不可用等）。
struct SystemMetrics: Equatable {
    var cpuUsage: Double?            // 0.0-1.0
    var cpuTemperature: Double?      // 摄氏度
    var fanSpeeds: [Int]?            // RPM 数组，多风扇
    var memoryUsage: Double?         // 0.0-1.0
    var memoryUsedGB: Double?
    var memoryTotalGB: Double?
    var diskUsage: Double?           // 0.0-1.0
    var diskUsedGB: Double?
    var diskTotalGB: Double?
    var networkUpload: Double?       // bytes/s
    var networkDownload: Double?
    var gpuUsage: Double?            // 0.0-1.0

    static let empty = SystemMetrics()

    /// 按 SystemMetricKind 取值，便于 UI 通用化渲染。
    func value(for kind: SystemMetricKind) -> Double? {
        switch kind {
        case .cpuTemperature: return cpuTemperature
        case .cpuUsage:        return cpuUsage
        case .fanSpeed:        return fanSpeeds?.first.map(Double.init)
        case .memory:          return memoryUsage
        case .disk:            return diskUsage
        case .gpu:             return gpuUsage
        case .network:         return networkDownload   // 用下载作为主指标
        }
    }
}

/// 监控指标种类枚举：用于「菜单栏展示」开关与下拉面板布局。
/// 顺序即菜单栏默认从左到右的展示顺序（按 rawValue 排序后）。
enum SystemMetricKind: String, Codable, CaseIterable, Identifiable {
    case cpuTemperature = "cpu_temp"
    case cpuUsage       = "cpu_usage"
    case fanSpeed       = "fan"
    case memory         = "memory"
    case disk           = "disk"
    case network        = "network"
    case gpu             = "gpu"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cpuTemperature: return "CPU 温度"
        case .cpuUsage:        return "CPU 占用"
        case .fanSpeed:        return "风扇转速"
        case .memory:          return "内存"
        case .disk:            return "磁盘"
        case .network:         return "网速"
        case .gpu:             return "GPU 占用"
        }
    }

    var symbol: String {
        switch self {
        case .cpuTemperature: return "thermometer.medium"
        case .cpuUsage:        return "cpu"
        case .fanSpeed:        return "fanblades"
        case .memory:          return "memorychip"
        case .disk:            return "internaldrive"
        case .network:         return "network"
        case .gpu:             return "rectangle.dashed.and.paperclip"
        }
    }

    /// 菜单栏数值的单位（百分比项不显示单位，温度/转速显示）。
    var unit: String {
        switch self {
        case .cpuTemperature: return "°C"
        case .fanSpeed:        return "RPM"
        case .network:         return ""     // 网速自适应 K/M
        default:               return "%"
        }
    }

    /// 异常阈值（warning 橙色）：超过此值菜单栏数值变橙。
    /// nil 表示该项不着色（如网速、风扇转速，因机型差异大不设阈值）。
    var warningThreshold: Double? {
        switch self {
        case .cpuTemperature: return 80
        case .cpuUsage:       return 0.80
        case .memory:         return 0.85
        case .disk:           return 0.85
        case .gpu:            return 0.80
        default:              return nil
        }
    }

    /// 危险阈值（danger 红色）：超过此值菜单栏数值变红。
    var dangerThreshold: Double? {
        switch self {
        case .cpuTemperature: return 90
        case .cpuUsage:       return 0.90
        case .memory:         return 0.95
        case .disk:           return 0.95
        case .gpu:            return 0.90
        default:              return nil
        }
    }
}

/// 系统监控配置（嵌入 AppSettings 持久化）。
/// - enabled: 总开关，关闭后 SystemMonitorManager 不采样、菜单栏与下拉面板不展示。
/// - menuBarItems: 选中在菜单栏 E 图标旁展示的指标集合。
struct SystemMonitorConfig: Codable, Equatable {
    var enabled: Bool = false
    var menuBarItems: Set<SystemMetricKind> = []

    static let `default` = SystemMonitorConfig()
}
