import Foundation
import IOKit

/// 直接通过 IOKit 访问 SMC（System Management Controller）读取 CPU 温度与
/// 风扇转速。无第三方依赖、无需 root（App Sandbox 已禁用）。
///
/// 原理：通过 IOServiceMatching("AppleSMC") 拿到 SMC 服务，再用
/// IOConnectCallStructMethod 发送 SMCReadKey 命令读取指定 4 字符 key。
/// 参考 osx-cpu-temp / iStats 的 C 实现，转为纯 Swift。
///
/// 机型差异：不同 Mac SMC key 名不同（温度 TC0P/TC0D/TC0H、风扇 F0Ac/F1Ac）。
/// 读不到时返回 nil，UI 静默隐藏对应项。
enum SMCReader {
    /// SMC 命令码（来自 AppleSMC.kext 私有头，与 osx-cpu-temp 一致）。
    private enum KernelIndex: UInt32 {
        case readKey = 5   // SMCReadKey
    }

    /// SMC 数据结构（与 osx-cpu-temp 的 SMCKeyData 完全一致，80 字节）：
    ///   key: UInt32 (4) + vers: UInt32 (4) + pLimitData: 32 bytes +
    ///   dataSize: UInt32 (4) + dataType: UInt32 (4) + dataBytes: 32 bytes
    /// 总共 80 字节。Swift 中用 tuple 表达固定大小 32-byte 数组。
    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers: UInt32 = 0
        var pLimitData: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataBytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    /// SMC 服务连接。静态缓存避免每次读取重新打开。
    private static var connection: io_connect_t = 0
    private static var didTryOpen: Bool = false

    /// 4 字符 key（"TC0P"）转 UInt32（big-endian，与 SMC 约定一致）。
    private static func keyToUInt32(_ key: String) -> UInt32 {
        var result: UInt32 = 0
        for char in key.utf8.prefix(4) {
            result = (result << 8) | UInt32(char)
        }
        // 不需要再 bigEndian 转换——我们已经按字节序拼好了。
        return result
    }

    /// UInt32 转 4 字符 key（用于解析 dataType）。
    private static func uint32ToKey(_ value: UInt32) -> String {
        // SMC key 以 big-endian 存储，与上方 keyToUInt32 对应。
        return String(format: "%c%c%c%c",
                      UInt8(truncatingIfNeeded: value >> 24),
                      UInt8(truncatingIfNeeded: value >> 16),
                      UInt8(truncatingIfNeeded: value >> 8),
                      UInt8(truncatingIfNeeded: value))
    }

    /// 打开 SMC 服务连接。失败返回 false（机型无 SMC kext）。
    private static func openConnection() -> Bool {
        if didTryOpen { return connection != 0 }
        didTryOpen = true

        guard let matching = IOServiceMatching("AppleSMC") else { return false }
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, matching)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        // IOServiceOpen 第 3 个参数是 userClient type，AppleSMC 为 0。
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        return kr == kIOReturnSuccess
    }

    /// 读取指定 SMC key 的原始字节。失败返回 nil。
    private static func readKey(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard openConnection() else { return nil }

        var input = SMCKeyData()
        input.key = keyToUInt32(key)
        // input.dataSize 必须设为 0（请求读取 key 的现有数据大小），其他字段清零。
        input.dataSize = 0
        input.dataType = 0

        var output = SMCKeyData()
        let inputSize = MemoryLayout<SMCKeyData>.size
        var outputSize = MemoryLayout<SMCKeyData>.size

        let kr = withUnsafePointer(to: &input) { inputPtr in
            inputPtr.withMemoryRebound(to: UInt8.self, capacity: inputSize) { inBytes in
                withUnsafeMutablePointer(to: &output) { outputPtr in
                    outputPtr.withMemoryRebound(to: UInt8.self, capacity: outputSize) { outBytes in
                        IOConnectCallStructMethod(
                            connection,
                            KernelIndex.readKey.rawValue,
                            inBytes, inputSize,
                            outBytes, &outputSize
                        )
                    }
                }
            }
        }
        guard kr == kIOReturnSuccess else { return nil }
        guard output.dataSize > 0, output.dataSize <= 32 else { return nil }

        let type = uint32ToKey(output.dataType)
        // 将 tuple 拍扁为数组。
        let mirror = Mirror(reflecting: output.dataBytes)
        let bytes = mirror.children.compactMap { $0.value as? UInt8 }
        return (type, Array(bytes.prefix(Int(output.dataSize))))
    }

    /// 解析 SMC 数值。类型说明（与 osx-cpu-temp 一致）：
    /// - "sp78" (SP78): 2 bytes, signed int / 256.0（如温度）
    /// - "fpe2" (FPE2): 2 bytes, unsigned int / 4.0（如风扇转速）
    /// - "sp5e" (SPIRE_DATA): 32-bit float, big-endian
    /// - "flt " (FLOAT): 32-bit float
    private static func parseValue(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(raw) / 4.0
        case "sp5e", "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 |
                      UInt32(bytes[2]) << 8  | UInt32(bytes[3])
            let float = Float(bitPattern: raw)
            return Double(float)
        default:
            return nil
        }
    }

    // MARK: - Public

    /// 读取 CPU 温度（摄氏度）。
    /// 依次尝试多个常见 key：TC0P（CPU Proximity）、TC0D（CPU Die）、TC0H。
    /// 全部失败返回 nil（虚拟机/某些机型 SMC 不可用）。
    static func readCPUTemperature() -> Double? {
        for key in ["TC0P", "TC0D", "TC0H", "TC0E", "TC0F", "TC0C", "TC1C", "TC2C"] {
            if let result = readKey(key),
               let value = parseValue(type: result.type, bytes: result.bytes) {
                return value
            }
        }
        return nil
    }

    /// 读取所有风扇转速（RPM 数组）。
    /// 先读 FNum 获取风扇数量，再依次读 F0Ac/F1Ac/F2Ac 实际转速。
    static func readFanSpeeds() -> [Int]? {
        // 风扇数量。
        guard let countResult = readKey("FNum"),
              let count = parseValue(type: countResult.type, bytes: countResult.bytes) else {
            return nil
        }
        let fanCount = Int(count)
        guard fanCount > 0 else { return nil }

        var speeds: [Int] = []
        for i in 0..<fanCount {
            // F0Ac / F1Ac / F2Ac：风扇 i 实际转速。
            let key = "F\(i)Ac"
            if let result = readKey(key),
               let value = parseValue(type: result.type, bytes: result.bytes) {
                speeds.append(Int(value))
            }
        }
        return speeds.isEmpty ? nil : speeds
    }
}
