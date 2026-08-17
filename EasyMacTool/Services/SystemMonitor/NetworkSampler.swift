import Darwin
import Foundation

/// One network reading: instantaneous speed plus session totals.
nonisolated struct NetworkReading: Sendable {
    var downBytesPerSec: Double?
    var upBytesPerSec: Double?
    var totalDown: UInt64
    var totalUp: UInt64
}

/// Samples cumulative interface byte counters and derives speed + session totals.
nonisolated final class NetworkSampler: @unchecked Sendable {
    private var previous: (counters: NetworkCounters, time: TimeInterval)?
    private var totalDown: UInt64 = 0
    private var totalUp: UInt64 = 0
    /// Routing-table payloads are typically tens of KB. Keep capacity between
    /// ticks instead of allocating a fresh array for every monitor refresh.
    private var routeBuffer: [UInt8] = []
    private var interfaceNameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))

    private static let maxGap: TimeInterval = 10

    func sample(now: TimeInterval) -> NetworkReading {
        let counters = readCountersReusingBuffer()
        defer { previous = (counters, now) }

        guard let prev = previous, now > prev.time, now - prev.time <= Self.maxGap else {
            return NetworkReading(downBytesPerSec: nil, upBytesPerSec: nil,
                                  totalDown: totalDown, totalUp: totalUp)
        }

        let elapsed = now - prev.time
        let (down, up) = MetricFormat.netSpeed(previous: prev.counters,
                                               current: counters,
                                               elapsed: elapsed)
        if counters.received >= prev.counters.received {
            totalDown += counters.received - prev.counters.received
        }
        if counters.sent >= prev.counters.sent {
            totalUp += counters.sent - prev.counters.sent
        }
        return NetworkReading(downBytesPerSec: down, upBytesPerSec: up,
                              totalDown: totalDown, totalUp: totalUp)
    }

    /// Sums received/sent bytes across the physical interfaces via the routing
    /// socket (`NET_RT_IFLIST2`), which reports 64-bit counters in `if_data64`.
    static func readCounters() -> NetworkCounters {
        var routeBuffer: [UInt8] = []
        var interfaceNameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        return readCounters(routeBuffer: &routeBuffer, interfaceNameBuffer: &interfaceNameBuffer)
    }

    private func readCountersReusingBuffer() -> NetworkCounters {
        Self.readCounters(routeBuffer: &routeBuffer, interfaceNameBuffer: &interfaceNameBuffer)
    }

    private static func readCounters(
        routeBuffer: inout [UInt8],
        interfaceNameBuffer: inout [CChar]
    ) -> NetworkCounters {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else {
            return NetworkCounters()
        }

        if routeBuffer.count < length {
            routeBuffer = [UInt8](repeating: 0, count: length)
        }
        guard sysctl(&mib, 6, &routeBuffer, &length, nil, 0) == 0 else {
            return NetworkCounters()
        }

        var result = NetworkCounters()
        routeBuffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= length {
                let header = base.advanced(by: offset)
                    .assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }

                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = base.advanced(by: offset)
                        .assumingMemoryBound(to: if_msghdr2.self).pointee
                    interfaceNameBuffer[0] = 0
                    if if_indextoname(UInt32(info.ifm_index), &interfaceNameBuffer) != nil {
                        let name = String(decoding: interfaceNameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                          as: UTF8.self)
                        if MetricFormat.includeNetworkInterface(name) {
                            result.received += info.ifm_data.ifi_ibytes
                            result.sent += info.ifm_data.ifi_obytes
                        }
                    }
                }
                offset += messageLength
            }
        }
        return result
    }
}
