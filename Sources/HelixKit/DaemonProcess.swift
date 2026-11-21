// ABOUTME: Finds the running mutagen daemon and moves it between normal and background priority.
// ABOUTME: Runs pgrep and taskpolicy with argument arrays; SessionStore reaches them through DaemonProcess.

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
    case severalDaemons([ProcessID])

    public var errorDescription: String? {
        switch self {
        case .unreadablePID(let text):
            return "pgrep printed \"\(text)\", which is not a process ID"
        case .severalDaemons(let pids):
            return "Several mutagen daemons are running (pids \(pids.map(\.description).joined(separator: ", ")))"
        }
    }
}

/// The current user's mutagen daemon started from one mutagen executable,
/// found by its exact command line so short-lived `mutagen sync list` calls never match.
public struct MutagenDaemon: DaemonProcess {
    let cliPath: String

    public init(cliPath: String) {
        self.cliPath = cliPath
    }

    public func pid() async throws -> ProcessID? {
        let output: String
        do {
            output = try await runProcess(
                executablePath: "/usr/bin/pgrep",
                arguments: ["-U", String(getuid()), "-f", "-x", "--", Self.literalPattern("\(cliPath) daemon run")]
            )
        } catch let error as CLIError where error.exitCode == 1 {
            // pgrep exits 1 when no process matches.
            return nil
        }
        let pids = try output.split(whereSeparator: \.isNewline).map { line in
            guard let pid = ProcessID(parsing: String(line)) else {
                throw DaemonProcessError.unreadablePID(String(line))
            }
            return pid
        }
        guard pids.count <= 1 else { throw DaemonProcessError.severalDaemons(pids) }
        return pids.first
    }

    public func setBackgroundPriority(_ enabled: Bool, pid: ProcessID) async throws {
        _ = try await runProcess(
            executablePath: "/usr/sbin/taskpolicy",
            arguments: [enabled ? "-b" : "-B", "-p", pid.description]
        )
    }

    /// Escapes the characters pgrep reads as regular expression syntax, so a path matches only itself.
    static func literalPattern(_ text: String) -> String {
        let metacharacters: Set<Character> = [".", "[", "]", "(", ")", "*", "+", "?", "{", "}", "|", "^", "$", "\\"]
        return String(text.flatMap { metacharacters.contains($0) ? ["\\", $0] : [$0] })
    }
}
