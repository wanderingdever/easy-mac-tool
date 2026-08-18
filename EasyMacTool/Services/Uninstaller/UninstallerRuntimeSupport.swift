import Darwin
import Foundation

nonisolated enum UninstallerRuntimeSupport {
    enum LaunchItemKind: Equatable, Sendable {
        case userAgent
        case sharedAgent
        case systemDaemon
    }

    struct LaunchItem: Equatable, Sendable {
        let url: URL
        let identity: UninstallerSupport.FileIdentity
        let label: String
        let kind: LaunchItemKind
    }

    struct ProcessIdentity: Equatable, Sendable {
        let pid: pid_t
        let uid: uid_t
        let executablePath: String
    }

    struct CommandResult: Equatable, Sendable {
        let exitCode: Int32
        let errorText: String

        var succeeded: Bool { exitCode == 0 }
    }

    enum BootoutDisposition: Equatable, Sendable {
        case stopped
        case notLoaded
        case failed
    }

    private static let pathBufferSize = 4_096

    static func launchItemKind(for url: URL, home: URL) -> LaunchItemKind? {
        let path = url.standardizedFileURL.path
        let userAgents = home.standardizedFileURL
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true).path
        if path.hasPrefix(userAgents + "/") { return .userAgent }
        if path.hasPrefix("/Library/LaunchAgents/") { return .sharedAgent }
        if path.hasPrefix("/Library/LaunchDaemons/") { return .systemDaemon }
        return nil
    }

    static func launchItem(at url: URL,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> LaunchItem? {
        guard let kind = launchItemKind(for: url, home: home),
              let identity = UninstallerSupport.fileIdentity(at: url),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let label = dictionary["Label"] as? String,
              UninstallerSupport.looksLikeBundleID(label) else {
            return nil
        }
        return LaunchItem(url: url.standardizedFileURL,
                          identity: identity,
                          label: label,
                          kind: kind)
    }

    static func bootoutArguments(for item: LaunchItem, uid: uid_t) -> [String]? {
        guard item.kind != .systemDaemon else { return nil }
        return ["bootout", "gui/\(uid)", item.url.path]
    }

    static func bootstrapArguments(for item: LaunchItem, uid: uid_t) -> [String]? {
        guard item.kind != .systemDaemon else { return nil }
        return ["bootstrap", "gui/\(uid)", item.url.path]
    }

    static func runLaunchctl(arguments: [String]) -> CommandResult {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CommandResult(exitCode: process.terminationStatus, errorText: message)
        } catch {
            return CommandResult(exitCode: -1, errorText: error.localizedDescription)
        }
    }

    static func bootoutDisposition(_ result: CommandResult) -> BootoutDisposition {
        if result.succeeded { return .stopped }
        let message = result.errorText.lowercased()
        if message.contains("could not find service")
            || message.contains("no such process")
            || message.contains("service not found") {
            return .notLoaded
        }
        return .failed
    }

    static func allProcesses() -> [ProcessIdentity] {
        // `proc_listallpids` reports a process count when called without a
        // buffer, not a byte count. Dividing it by `MemoryLayout<pid_t>` would
        // under-allocate and silently omit most running helper processes.
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        let count = min(pids.count, Int(written))
        return pids.prefix(count).compactMap(processIdentity)
    }

    static func processIdentity(_ pid: pid_t) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else {
            return nil
        }
        var pathBuffer = [CChar](repeating: 0, count: pathBufferSize)
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return nil }
        let path = String(
            decoding: pathBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return ProcessIdentity(pid: pid, uid: info.pbi_uid, executablePath: path)
    }

    static func isEligibleProcess(_ process: ProcessIdentity,
                                  appURL: URL,
                                  currentUID: uid_t = getuid(),
                                  ownPID: pid_t = getpid()) -> Bool {
        guard process.pid != ownPID, process.uid == currentUID else { return false }
        let appPath = appURL.standardizedFileURL.path
        let executable = URL(fileURLWithPath: process.executablePath).standardizedFileURL.path
        return executable.hasPrefix(appPath + "/")
    }

    static func isSameProcess(_ expected: ProcessIdentity,
                              current: ProcessIdentity?,
                              appURL: URL,
                              allowsExternalPath: Bool = false,
                              currentUID: uid_t = getuid(),
                              ownPID: pid_t = getpid()) -> Bool {
        guard let current, current == expected else { return false }
        if allowsExternalPath {
            return current.pid != ownPID && current.uid == currentUID
        }
        return isEligibleProcess(current,
                                 appURL: appURL,
                                 currentUID: currentUID,
                                 ownPID: ownPID)
    }
}
