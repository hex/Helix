// ABOUTME: Finds the running mutagen daemon and moves it between normal and background priority.
// ABOUTME: Runs pgrep and taskpolicy with argument arrays; SessionStore reaches them through DaemonProcess.

import Darwin
import Foundation

/// The mutagen daemon as an operating system process.
public protocol DaemonProcess: Sendable {
    /// The daemon's process ID, or nil when no daemon is running.
    func pid() async throws -> ProcessID?
    /// Runs the process at background priority when enabled, at normal priority otherwise.
    func setBackgroundPriority(_ enabled: Bool, pid: ProcessID) async throws
}

/// A process ID the kernel can hand out: a positive 32-bit integer.
public struct ProcessID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int32

    public init?(_ rawValue: Int32) {
        guard rawValue > 0 else { return nil }
        self.rawValue = rawValue
    }

    /// Accepts decimal digits only, so text such as "+5", " 5" or "0x5" is rejected.
    public init?(parsing text: String) {
        guard !text.isEmpty,
              text.allSatisfy({ ("0"..."9").contains($0) }),
              let value = Int32(text) else { return nil }
        self.init(value)
    }

    public var description: String { String(rawValue) }
}

public enum DaemonProcessError: LocalizedError, Equatable {
    case unreadablePID(String)
    case executableLookupFailed(ProcessID, Int32)
    case severalDaemons([ProcessID])

    public var errorDescription: String? {
        switch self {
        case .unreadablePID(let text):
            return "pgrep printed \"\(text)\", which is not a process ID"
        case .executableLookupFailed(let pid, let code):
            return "Could not identify the executable of PID \(pid): \(String(cString: strerror(code)))"
        case .severalDaemons(let pids):
            return "Several mutagen daemons are running (pids \(pids.map(\.description).joined(separator: ", ")))"
        }
    }
}

/// The current user's mutagen daemon started from one mutagen executable,
/// identified by its exact daemon command line and executable path.
public struct MutagenDaemon: DaemonProcess {
    let cliPath: String
    private let findProcesses: @Sendable ([String]) async throws -> String
    private let executablePath: @Sendable (ProcessID) throws -> String?

    public init(cliPath: String) {
        self.init(cliPath: cliPath, findProcesses: { arguments in
            try await runProcess(
                executablePath: "/usr/bin/pgrep", arguments: arguments, deadline: CommandDeadline.query
            )
        }, executablePath: { pid in
            try Self.processExecutablePath(pid)
        })
    }

    init(
        cliPath: String,
        findProcesses: @escaping @Sendable ([String]) async throws -> String,
        executablePath: @escaping @Sendable (ProcessID) throws -> String?
    ) {
        self.cliPath = cliPath
        self.findProcesses = findProcesses
        self.executablePath = executablePath
    }

    public func pid() async throws -> ProcessID? {
        let expectedExecutable = Self.canonicalPath(cliPath)
        let launchNames = Set([cliPath, expectedExecutable, "mutagen"]).sorted()
        let pattern = launchNames.map { Self.literalPattern("\($0) daemon run") }.joined(separator: "|")
        let output: String
        do {
            output = try await findProcesses(["-U", String(getuid()), "-f", "-x", "--", pattern])
        } catch let error as CLIError where error.exitCode == 1 {
            // pgrep exits 1 when no process matches.
            return nil
        }
        let pids = try output.split(whereSeparator: \.isNewline).compactMap { line -> ProcessID? in
            guard let pid = ProcessID(parsing: String(line)) else {
                throw DaemonProcessError.unreadablePID(String(line))
            }
            guard let image = try executablePath(pid), Self.canonicalPath(image) == expectedExecutable else { return nil }
            return pid
        }
        guard pids.count <= 1 else { throw DaemonProcessError.severalDaemons(pids) }
        return pids.first
    }

    public func setBackgroundPriority(_ enabled: Bool, pid: ProcessID) async throws {
        _ = try await runProcess(
            executablePath: "/usr/sbin/taskpolicy",
            arguments: [enabled ? "-b" : "-B", "-p", pid.description],
            deadline: CommandDeadline.query
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func processExecutablePath(_ pid: ProcessID) throws -> String? {
        // Swift does not import the SDK's PROC_PIDPATHINFO_MAXSIZE macro.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid.rawValue, $0.baseAddress, UInt32($0.count))
        }
        if length == 0 {
            let code = errno
            // A candidate can exit between pgrep and the executable lookup.
            if code == ESRCH { return nil }
            throw DaemonProcessError.executableLookupFailed(pid, code)
        }
        guard let path = String(bytes: buffer.prefix(Int(length)), encoding: .utf8) else {
            throw DaemonProcessError.executableLookupFailed(pid, EILSEQ)
        }
        return path
    }

    /// Escapes the characters pgrep reads as regular expression syntax, so a path matches only itself.
    static func literalPattern(_ text: String) -> String {
        let metacharacters: Set<Character> = [".", "[", "]", "(", ")", "*", "+", "?", "{", "}", "|", "^", "$", "\\"]
        return String(text.flatMap { metacharacters.contains($0) ? ["\\", $0] : [$0] })
    }
}
