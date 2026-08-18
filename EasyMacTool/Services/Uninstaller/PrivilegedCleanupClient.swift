import Foundation
import ServiceManagement

nonisolated enum PrivilegedCleanupWire {
    static let protocolVersion = 1
    static let machServiceName = "com.easy.EasyMacTool.PrivilegedCleanup"
    static let daemonPlistName = "com.easy.EasyMacTool.PrivilegedHelper.plist"
    // The helper rejects every XPC client whose code-signing identifier does
    // not match the main application. Path and identity checks remain required
    // as a second, independent authorization boundary.
    static let clientCodeSigningRequirement = "identifier \"com.easy.EasyMacTool\""

    struct Identity: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let fileType: UInt16
    }

    struct Item: Codable, Sendable {
        let path: String
        let identity: Identity
        let kind: String
    }

    struct LaunchItem: Codable, Sendable {
        let item: Item
        let label: String
        let launchKind: String
    }

    struct Request: Codable, Sendable {
        let version: Int
        let appPath: String
        let bundleID: String
        let bundleIDs: [String]
        let uid: UInt32
        let items: [Item]
        let launchItems: [LaunchItem]
    }

    struct ItemResult: Codable, Sendable {
        let path: String
        let removed: Bool
        let bytes: Int64
        let error: String?
    }

    struct Response: Codable, Sendable {
        let version: Int
        let results: [ItemResult]
        let launchErrors: [String]
        let fatalError: String?
    }
}

@objc private protocol PrivilegedCleanupService {
    nonisolated func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

nonisolated enum PrivilegedCleanupClient {
    static func perform(_ request: PrivilegedCleanupWire.Request) async -> PrivilegedCleanupWire.Response {
        do {
            let connection = try await connect()
            defer { connection.invalidate() }
            let data = try JSONEncoder().encode(request)
            return try await withCheckedThrowingContinuation { continuation in
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    continuation.resume(throwing: error)
                } as? PrivilegedCleanupService
                proxy?.perform(data) { responseData in
                    do {
                        continuation.resume(returning: try JSONDecoder().decode(
                            PrivilegedCleanupWire.Response.self,
                            from: responseData
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            return PrivilegedCleanupWire.Response(
                version: PrivilegedCleanupWire.protocolVersion,
                results: request.items.map {
                    .init(path: $0.path,
                          removed: false,
                          bytes: 0,
                          error: "管理员清理 helper 不可用：\(error.localizedDescription)")
                },
                launchErrors: [],
                fatalError: error.localizedDescription
            )
        }
    }

    private static func connect() async throws -> NSXPCConnection {
        let service = SMAppService.daemon(plistName: PrivilegedCleanupWire.daemonPlistName)
        do {
            try service.register()
        } catch {
            // A previously approved daemon can already be registered. The
            // XPC connection below provides the definitive availability check.
        }
        let connection = NSXPCConnection(
            machServiceName: PrivilegedCleanupWire.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedCleanupService.self)
        connection.resume()
        return connection
    }
}
