import Foundation
import Darwin

private let machServiceName = "com.easy.EasyMacTool.PrivilegedCleanup"
private let launchctlTimeout: TimeInterval = 5

private struct CleanupIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let fileType: UInt16
}

private struct CleanupItem: Codable {
    let path: String
    let identity: CleanupIdentity
    let kind: String
}

private struct CleanupLaunchItem: Codable {
    let item: CleanupItem
    let label: String
    let launchKind: String
}

private struct CleanupRequest: Codable {
    let version: Int
    let appPath: String
    let bundleID: String
    let bundleIDs: [String]
    let uid: UInt32
    let items: [CleanupItem]
    let launchItems: [CleanupLaunchItem]
}

private struct CleanupItemResult: Codable {
    let path: String
    let removed: Bool
    let bytes: Int64
    let error: String?
}

private struct CleanupResponse: Codable {
    let version: Int
    let results: [CleanupItemResult]
    let launchErrors: [String]
    let fatalError: String?
}

@objc private protocol PrivilegedCleanupService {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

private final class CleanupService: NSObject, PrivilegedCleanupService {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let response: CleanupResponse
        do {
            let decoded = try JSONDecoder().decode(CleanupRequest.self, from: request)
            response = perform(decoded)
        } catch {
            response = CleanupResponse(version: 1,
                                       results: [],
                                       launchErrors: [],
                                       fatalError: "请求格式无效：\(error.localizedDescription)")
        }
        let data = (try? JSONEncoder().encode(response)) ?? Data()
        reply(data)
    }

    private func perform(_ request: CleanupRequest) -> CleanupResponse {
        guard request.version == 1,
              request.uid != 0,
              request.uid == UInt32(NSXPCConnection.current()?.effectiveUserIdentifier ?? 0),
              validBundleID(request.bundleID),
              !request.bundleIDs.isEmpty,
              request.bundleIDs.count <= 128,
              request.bundleIDs.allSatisfy(validBundleID),
              request.bundleIDs.contains(request.bundleID),
              isAllowedAppPath(request.appPath, uid: request.uid),
              Bundle(url: URL(fileURLWithPath: request.appPath))?.bundleIdentifier == request.bundleID,
              ownedBundleIDs(in: request.appPath, primary: request.bundleID).isSuperset(of: request.bundleIDs) else {
            return CleanupResponse(version: 1,
                                   results: [],
                                   launchErrors: [],
                                   fatalError: "请求未通过安全校验")
        }

        var launchErrors: [String] = []
        for launchItem in request.launchItems {
            guard request.bundleIDs.contains(launchItem.label),
                  validate(launchItem.item,
                           appPath: request.appPath,
                           bundleIDs: request.bundleIDs) else {
                launchErrors.append("启动项身份或路径校验失败：\(launchItem.item.path)")
                continue
            }
            let arguments: [String]
            switch launchItem.launchKind {
            case "systemDaemon":
                arguments = ["bootout", "system", launchItem.item.path]
            case "sharedAgent", "userAgent":
                arguments = ["bootout", "gui/\(request.uid)", launchItem.item.path]
            default:
                launchErrors.append("未知启动项类型：\(launchItem.item.path)")
                continue
            }
            let result = runLaunchctl(arguments)
            if !result.succeeded && !result.errorText.lowercased().contains("no such process") {
                launchErrors.append("无法停止启动项 \(launchItem.label)：\(result.errorText)")
            }
        }

        let results = request.items.map { item -> CleanupItemResult in
            guard validate(item,
                           appPath: request.appPath,
                           bundleIDs: request.bundleIDs) else {
                return CleanupItemResult(path: item.path,
                                         removed: false,
                                         bytes: 0,
                                         error: "项目身份或路径校验失败")
            }
            do {
                let bytes = directorySize(at: item.path)
                try moveToTrash(item.path, uid: request.uid)
                return CleanupItemResult(path: item.path,
                                         removed: true,
                                         bytes: bytes,
                                         error: nil)
            } catch {
                return CleanupItemResult(path: item.path,
                                         removed: false,
                                         bytes: 0,
                                         error: "移至废纸篓失败：\(error.localizedDescription)")
            }
        }
        return CleanupResponse(version: 1,
                               results: results,
                               launchErrors: launchErrors,
                               fatalError: nil)
    }

    private func validate(_ item: CleanupItem,
                          appPath: String,
                          bundleIDs: [String]) -> Bool {
        let url = URL(fileURLWithPath: item.path).standardizedFileURL
        let path = url.path
        guard isAllowedProtectedPath(path,
                                     appPath: appPath,
                                     bundleIDs: bundleIDs),
              path == item.path,
              let current = identity(at: path),
              current == item.identity,
              current.fileType != UInt16(S_IFLNK) else {
            return false
        }
        return true
    }

    private func isAllowedAppPath(_ path: String, uid: UInt32) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path,
              url.pathExtension.lowercased() == "app",
              url == url.resolvingSymlinksInPath().standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        let home = homeDirectory(for: uid)
        return url.path.hasPrefix("/Applications/")
            || url.path.hasPrefix(home + "/Applications/")
    }

    private func isAllowedProtectedPath(_ path: String,
                                        appPath: String,
                                        bundleIDs: [String]) -> Bool {
        guard path == appPath else {
            return bundleIDs.contains { id in
                [
                    "/Library/Application Support/\(id)",
                    "/Library/Caches/\(id)",
                    "/Library/Preferences/\(id).plist",
                    "/Library/PrivilegedHelperTools/\(id)",
                    "/Library/LaunchAgents/\(id).plist",
                    "/Library/LaunchDaemons/\(id).plist",
                ].contains(path)
            }
        }
        return true
    }

    private func ownedBundleIDs(in appPath: String, primary: String) -> Set<String> {
        var result: Set<String> = [primary]
        let root = URL(fileURLWithPath: appPath, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) else { return result }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isDirectory == true,
                  ["app", "appex", "xpc", "plugin", "bundle"].contains(url.pathExtension.lowercased()),
                  let id = Bundle(url: url)?.bundleIdentifier,
                  validBundleID(id),
                  id == primary || id.hasPrefix(primary + ".") else { continue }
            result.insert(id)
        }
        return result
    }

    private func validBundleID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.count >= 3
            && value.unicodeScalars.allSatisfy(allowed.contains)
            && !value.hasPrefix(".")
            && !value.hasSuffix(".")
            && parts.count >= 2
            && parts.allSatisfy { !$0.isEmpty }
            && value.lowercased() != "com.apple"
            && !value.lowercased().hasPrefix("com.apple.")
            && value.lowercased() != "com.opensource"
            && !value.lowercased().hasPrefix("com.opensource.")
            && value.lowercased() != "org.gnu"
            && !value.lowercased().hasPrefix("org.gnu.")
    }

    private func homeDirectory(for uid: UInt32) -> String {
        guard let passwd = getpwuid(uid_t(uid)), let raw = passwd.pointee.pw_dir else {
            return "/Users/unknown"
        }
        return String(cString: raw)
    }

    private func moveToTrash(_ path: String, uid: UInt32) throws {
        let fileManager = FileManager.default
        let home = homeDirectory(for: uid)
        let trash = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
        var trashInfo = stat()
        if lstat(trash.path, &trashInfo) == 0 {
            guard (trashInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw NSError(domain: "EasyMacToolPrivilegedHelper",
                              code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "用户废纸篓不是目录"])
            }
        } else {
            try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
            var passwdGroup: gid_t = 0
            if let passwd = getpwuid(uid_t(uid)) {
                passwdGroup = passwd.pointee.pw_gid
            }
            _ = chown(trash.path, uid_t(uid), passwdGroup)
            _ = chmod(trash.path, mode_t(0o700))
        }

        let source = URL(fileURLWithPath: path)
        for index in 0...1_000 {
            let suffix = index == 0 ? "" : " (index + 1)"
            let destination = trash.appendingPathComponent(
                source.deletingPathExtension().lastPathComponent + suffix
                    + (source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"),
                isDirectory: source.hasDirectoryPath
            )
            var destinationInfo = stat()
            guard lstat(destination.path, &destinationInfo) != 0 else { continue }
            try fileManager.moveItem(at: source, to: destination)
            return
        }
        throw NSError(domain: "EasyMacToolPrivilegedHelper",
                      code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "用户废纸篓中没有可用的目标名称"])
    }

    private func identity(at path: String) -> CleanupIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return CleanupIdentity(device: UInt64(info.st_dev),
                               inode: UInt64(info.st_ino),
                               fileType: UInt16(info.st_mode & S_IFMT))
    }

    private func directorySize(at path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let child = enumerator.nextObject() as? String {
            let childPath = URL(fileURLWithPath: path).appendingPathComponent(child).path
            var info = stat()
            if lstat(childPath, &info) == 0 {
                total += Int64(info.st_size)
            }
        }
        var root = stat()
        if lstat(path, &root) == 0 { total += Int64(root.st_size) }
        return total
    }

    private struct CommandResult {
        let succeeded: Bool
        let errorText: String
    }

    private func runLaunchctl(_ arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(launchctlTimeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard !process.isRunning else {
                process.terminate()
                return CommandResult(succeeded: false, errorText: "launchctl 超时")
            }
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CommandResult(succeeded: process.terminationStatus == 0, errorText: text)
        } catch {
            return CommandResult(succeeded: false, errorText: error.localizedDescription)
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard (try? newConnection.setCodeSigningRequirement(
            "identifier \"com.easy.EasyMacTool\""
        )) != nil else {
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: PrivilegedCleanupService.self)
        newConnection.exportedObject = CleanupService()
        newConnection.invalidationHandler = {}
        newConnection.interruptionHandler = {}
        newConnection.resume()
        return true
    }
}
