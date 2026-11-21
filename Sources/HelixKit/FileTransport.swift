// ABOUTME: Copies files between local, SSH, and Docker endpoints for conflict resolution.
// ABOUTME: Uses cp, scp, and docker-cp with an injectable executor for testability.

import Foundation

public enum FileTransportError: Error {
    case malformedStatOutput(String)
}

public struct FileInfo: Sendable {
    public let size: Int64
    public let modifiedAt: Date
    public let isSymlink: Bool
    public let symlinkTarget: String?
}

public enum ConflictWinner: Sendable {
    case alpha
    case beta
}

public struct FileTransport: Sendable {
    let runCommand: @Sendable (String, [String]) async throws -> String

    public init() {
        self.runCommand = { executable, arguments in
            try await runProcess(executablePath: executable, arguments: arguments)
        }
    }

    public init(execute: @escaping @Sendable (String, [String]) async throws -> String) {
        self.runCommand = execute
    }

    /// Runs a command and logs it and its outcome to the console.
    /// - Parameter exitOneAnswer: what exit status 1 means for a command that answers a yes-or-no
    ///   question, logged in place of "(exit 1)".
    private func execute(_ executable: String, _ arguments: [String], exitOneAnswer: String? = nil) async throws -> String {
        let cmd = "\(executable) \(arguments.joined(separator: " "))"
        await MainActor.run { ConsoleLog.shared.log(cmd, level: .command) }
        do {
            let result = try await runCommand(executable, arguments)
            await MainActor.run { ConsoleLog.shared.log(String(result.prefix(200))) }
            return result
        } catch let error as CLIError where error.exitCode == 1 {
            await MainActor.run { ConsoleLog.shared.log(exitOneAnswer ?? "(exit 1)", level: .info) }
            throw error
        } catch {
            await MainActor.run { ConsoleLog.shared.log("FAILED: \(error)", level: .error) }
            throw error
        }
    }

    // MARK: - Copy

    public func copy(from source: EndpointURL, to destination: EndpointURL) async throws {
        switch (source, destination) {
        case (.local(let src), .local(let dst)):
            _ = try await execute("/bin/cp", ["-Rp", src, dst])

        case (.local(let src), .ssh(let user, let host, let port, let path)):
            _ = try await execute("/usr/bin/scp", scpArgs(port: port, recursive: true, from: src, to: scpRemote(user: user, host: host, path: path)))

        case (.ssh(let user, let host, let port, let path), .local(let dst)):
            _ = try await execute("/usr/bin/scp", scpArgs(port: port, recursive: true, from: scpRemote(user: user, host: host, path: path), to: dst))

        case (.local(let src), .docker(let container, let path)):
            _ = try await execute("/usr/bin/docker", ["cp", src, "\(container):\(path)"])

        case (.docker(let container, let path), .local(let dst)):
            _ = try await execute("/usr/bin/docker", ["cp", "\(container):\(path)", dst])

        case (.ssh(let u1, let h1, let p1, let path1), .ssh(let u2, let h2, let p2, let path2)):
            var args = ["-3", "-r"]
            if let port = p1 ?? p2 {
                args += ["-P", "\(port)"]
            }
            args += [scpRemote(user: u1, host: h1, path: path1), scpRemote(user: u2, host: h2, path: path2)]
            _ = try await execute("/usr/bin/scp", args)

        default:
            // Cross-transport (ssh<->docker, docker<->docker): relay via temp file
            try await copyViaTemp(from: source, to: destination)
        }
    }

    // MARK: - Stat

    public func stat(endpoint: EndpointURL) async throws -> FileInfo {
        let output: String
        switch endpoint {
        case .local(let path):
            output = try await execute("/usr/bin/stat", ["-f", "%z %m", path])
        case .ssh(let user, let host, let port, let path):
            var args: [String] = []
            if let port {
                args += ["-p", "\(port)"]
            }
            // GNU stat uses -c, macOS stat uses -f with different format specifiers
            args += [sshTarget(user: user, host: host), "stat -c '%s %Y' \(path) 2>/dev/null || stat -f '%z %m' \(path)"]
            output = try await execute("/usr/bin/ssh", args)
        case .docker(let container, let path):
            output = try await execute("/usr/bin/docker", ["exec", container, "stat", "-c", "%s %Y", path])
        }
        return try parseStatOutput(output)
    }

    // MARK: - Read File

    public func readFile(endpoint: EndpointURL) async throws -> String {
        switch endpoint {
        case .local(let path):
            return try await execute("/bin/cat", [path])
        case .ssh(let user, let host, let port, let path):
            var args: [String] = []
            if let port {
                args += ["-p", "\(port)"]
            }
            args += [sshTarget(user: user, host: host), "cat \(shellQuoted(path))"]
            return try await execute("/usr/bin/ssh", args)
        case .docker(let container, let path):
            return try await execute("/usr/bin/docker", ["exec", container, "cat", path])
        }
    }

    // MARK: - Remove

    public func remove(endpoint: EndpointURL) async throws {
        switch endpoint {
        case .local(let path):
            _ = try await execute("/bin/rm", ["-rf", path])
        case .ssh(let user, let host, let port, let path):
            var args: [String] = []
            if let port {
                args += ["-p", "\(port)"]
            }
            args += [sshTarget(user: user, host: host), "rm -rf \(shellQuoted(path))"]
            _ = try await execute("/usr/bin/ssh", args)
        case .docker(let container, let path):
            _ = try await execute("/usr/bin/docker", ["exec", container, "rm", "-rf", path])
        }
    }

    // MARK: - Directory Exists

    private static let noSuchDirectory = "no such directory"

    public func directoryExists(endpoint: EndpointURL) async throws -> Bool {
        do {
            switch endpoint {
            case .local(let path):
                _ = try await execute("/bin/test", ["-d", path], exitOneAnswer: Self.noSuchDirectory)
            case .ssh(let user, let host, let port, let path):
                var args: [String] = []
                if let port { args += ["-p", "\(port)"] }
                args += [sshTarget(user: user, host: host), "test -d \(shellQuoted(path))"]
                _ = try await execute("/usr/bin/ssh", args, exitOneAnswer: Self.noSuchDirectory)
            case .docker(let container, let path):
                _ = try await execute("/usr/bin/docker", ["exec", container, "test", "-d", path], exitOneAnswer: Self.noSuchDirectory)
            }
            return true
        } catch let error as CLIError where error.exitCode == 1 {
            return false
        }
    }

    // MARK: - Symlink Detection

    public func isSymlink(endpoint: EndpointURL) async throws -> Bool {
        do {
            switch endpoint {
            case .local(let path):
                _ = try await execute("/bin/test", ["-L", path])
            case .ssh(let user, let host, let port, let path):
                var args: [String] = []
                if let port { args += ["-p", "\(port)"] }
                args += [sshTarget(user: user, host: host), "test -L \(shellQuoted(path))"]
                _ = try await execute("/usr/bin/ssh", args)
            case .docker(let container, let path):
                _ = try await execute("/usr/bin/docker", ["exec", container, "test", "-L", path])
            }
            return true
        } catch let error as CLIError where error.exitCode == 1 {
            return false
        }
    }

    public func readLink(endpoint: EndpointURL) async throws -> String {
        let output: String
        switch endpoint {
        case .local(let path):
            output = try await execute("/usr/bin/readlink", [path])
        case .ssh(let user, let host, let port, let path):
            var args: [String] = []
            if let port { args += ["-p", "\(port)"] }
            args += [sshTarget(user: user, host: host), "readlink \(shellQuoted(path))"]
            output = try await execute("/usr/bin/ssh", args)
        case .docker(let container, let path):
            output = try await execute("/usr/bin/docker", ["exec", container, "readlink", path])
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Path Exists

    public func pathExists(endpoint: EndpointURL) async throws -> Bool {
        do {
            switch endpoint {
            case .local(let path):
                _ = try await execute("/bin/test", ["-e", path])
            case .ssh(let user, let host, let port, let path):
                var args: [String] = []
                if let port { args += ["-p", "\(port)"] }
                args += [sshTarget(user: user, host: host), "test -e \(shellQuoted(path))"]
                _ = try await execute("/usr/bin/ssh", args)
            case .docker(let container, let path):
                _ = try await execute("/usr/bin/docker", ["exec", container, "test", "-e", path])
            }
            return true
        } catch let error as CLIError where error.exitCode == 1 {
            return false
        }
    }

    // MARK: - Run Command

    public func run(on endpoint: EndpointURL, command: String) async throws -> String {
        switch endpoint {
        case .local(let path):
            return try await execute("/bin/sh", ["-c", "cd '\(path)' && \(command)"])
        case .ssh(let user, let host, let port, let path):
            var args: [String] = []
            if let port { args += ["-p", "\(port)"] }
            args += [sshTarget(user: user, host: host), "cd \(shellQuoted(path)) && \(command)"]
            return try await execute("/usr/bin/ssh", args)
        case .docker(let container, let path):
            return try await execute("/usr/bin/docker", ["exec", container, "sh", "-c", "cd '\(path)' && \(command)"])
        }
    }

    // MARK: - Private

    private func copyViaTemp(from source: EndpointURL, to destination: EndpointURL) async throws {
        let tempPath = NSTemporaryDirectory() + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        try await copy(from: source, to: .local(path: tempPath))
        try await copy(from: .local(path: tempPath), to: destination)
    }

    private func scpRemote(user: String?, host: String, path: String) -> String {
        if let user {
            return "\(user)@\(host):\(path)"
        }
        return "\(host):\(path)"
    }

    private func scpArgs(port: Int?, recursive: Bool = false, from: String, to: String) -> [String] {
        var args: [String] = []
        if recursive {
            args.append("-r")
        }
        if let port {
            args += ["-P", "\(port)"]
        }
        args += [from, to]
        return args
    }

    /// Quotes a path for remote shell execution, handling tilde expansion.
    /// `~/foo` becomes `"$HOME/foo"` (double quotes allow $HOME expansion).
    /// Other paths use single quotes to protect special characters.
    private func shellQuoted(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return "\"$HOME/\(path.dropFirst(2))\""
        }
        if path == "~" {
            return "\"$HOME\""
        }
        return "'\(path)'"
    }

    /// Makes a path exactly one inert word for a POSIX shell on a remote host.
    /// Single quotes stop every expansion; an embedded single quote is written as `'\''`.
    /// A leading `~/` becomes `"$HOME"/` followed by the single-quoted rest, so only `$HOME` expands.
    static func shellWord(_ path: String) -> String {
        if path == "~" {
            return "\"$HOME\""
        }
        if path.hasPrefix("~/") {
            return "\"$HOME\"/" + singleQuoted(String(path.dropFirst(2)))
        }
        return singleQuoted(path)
    }

    private static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func sshTarget(user: String?, host: String) -> String {
        if let user {
            return "\(user)@\(host)"
        }
        return host
    }

    private func parseStatOutput(_ raw: String) throws -> FileInfo {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ")
        guard parts.count == 2,
              let size = Int64(parts[0]),
              let mtime = TimeInterval(parts[1]) else {
            throw FileTransportError.malformedStatOutput(trimmed)
        }
        return FileInfo(size: size, modifiedAt: Date(timeIntervalSince1970: mtime), isSymlink: false, symlinkTarget: nil)
    }
}
