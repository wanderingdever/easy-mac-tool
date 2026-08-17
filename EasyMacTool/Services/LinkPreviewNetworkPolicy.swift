import Darwin
import Foundation

/// Network boundary for clipboard link previews. A preview request is allowed
/// only when every resolved address is globally routable; mixed public/private
/// DNS answers are rejected to avoid DNS rebinding through a second address.
nonisolated enum LinkPreviewNetworkPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil,
              url.password == nil,
              let rawHost = url.host(percentEncoded: false) else { return false }

        if let port = url.port,
           (scheme == "http" && port != 80) || (scheme == "https" && port != 443) {
            return false
        }

        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty,
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal") else { return false }

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return false
        }
        defer { freeaddrinfo(first) }

        var foundAddress = false
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if info.pointee.ai_family == AF_INET,
               let address = info.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee }) {
                foundAddress = true
                guard isPublicIPv4(address.sin_addr) else { return false }
            } else if info.pointee.ai_family == AF_INET6,
                      let address = info.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in6.self, capacity: 1, { $0.pointee }) {
                foundAddress = true
                guard isPublicIPv6(address.sin6_addr) else { return false }
            }
            cursor = info.pointee.ai_next
        }
        return foundAddress
    }

    private static func isPublicIPv4(_ address: in_addr) -> Bool {
        let value = UInt32(bigEndian: address.s_addr)
        let first = UInt8((value >> 24) & 0xff)
        let second = UInt8((value >> 16) & 0xff)

        switch (first, second) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (255, _):
            return false
        case (100, 64...127), (172, 16...31):
            return false
        case (192, 0), (192, 2), (198, 18...19), (198, 51), (203, 0), (224...255, _):
            return false
        default:
            return true
        }
    }

    private static func isPublicIPv6(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.count == 16 else { return false }

        if bytes.allSatisfy({ $0 == 0 }) { return false }                 // ::
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false } // ::1
        if bytes[0] & 0xfe == 0xfc { return false }                      // fc00::/7
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return false }   // fe80::/10
        if bytes[0] == 0xff { return false }                              // multicast
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 {
            return false                                                  // documentation
        }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            var ipv4 = in_addr()
            withUnsafeMutableBytes(of: &ipv4) { destination in
                destination.copyBytes(from: bytes[12..<16])
            }
            return isPublicIPv4(ipv4)
        }
        return true
    }
}

