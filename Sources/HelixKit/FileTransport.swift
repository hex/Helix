// ABOUTME: Copies files between local, SSH, and Docker endpoints for conflict resolution.
// ABOUTME: Uses cp, scp, and docker-cp with an injectable executor for testability.

import Foundation

public enum FileTransportError: Error {
    case malformedStatOutput(String)
}

/// A replacement that stopped: the step that failed, and each recovery step that failed after it.
public struct ReplaceError: LocalizedError {
    public enum Step: Sendable, Equatable {
        case copySource
        case checkDestination
        case setOriginalAside
        case moveCopyIntoPlace
        case removeSetAsideOriginal
        case removeCopy
        case restoreOriginal
    }

    public struct StepFailure: Sendable {
        public let step: Step
        public let cause: any Error
    }

    public let source: String
    public let destination: String
    public let incoming: String
    public let setAside: String
    public let failure: StepFailure
    public let recoveryFailures: [StepFailure]

    public var errorDescription: String? {
        let first = sentence(for: failure)
        let recoveries = recoveryFailures.map { recoveryFailure -> String in
            let text = sentence(for: recoveryFailure)
            return "Then " + text.prefix(1).lowercased() + text.dropFirst()
        }
        return ([first] + recoveries).joined(separator: ". ")
    }

    private func sentence(for failure: StepFailure) -> String {
        let cause = failure.cause.localizedDescription
        switch failure.step {
        case .copySource:
            return "Could not copy \(source) to \(incoming): \(cause)"
        case .checkDestination:
            return "Could not check whether \(destination) exists: \(cause)"
        case .setOriginalAside:
            return "Could not move \(destination) aside to \(setAside): \(cause)"
        case .moveCopyIntoPlace:
            return "Could not move \(incoming) into place at \(destination): \(cause)"
        case .removeSetAsideOriginal:
            return "Replaced \(destination), but could not remove the original set aside at \(setAside): \(cause)"
        case .removeCopy:
            return "Could not remove the copy at \(incoming): \(cause)"
        case .restoreOriginal:
            return "Could not move the original back from \(setAside) to \(destination): \(cause)"
        }
    }
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

    // MARK: - Replace

    /// Replaces `destination` with a copy of `source` without a moment in which `destination` is missing.
    /// The copy lands beside it as `<name>.helix-incoming-<uuid>`, an existing destination moves aside
    /// to `<name>.helix-replaced-<uuid>`, the copy moves into place, and the set-aside original is removed.
    /// A failed copy leaves `destination` untouched and a failed move into place moves the original back;
    /// every failure, recovery failures included, is thrown as a `ReplaceError`.
    public func replace(_ destination: EndpointURL, withCopyOf source: EndpointURL) async throws {
        let token = UUID().uuidString
        let incoming = destination.withPath(destination.path + ".helix-incoming-\(token)")
        let setAside = destination.withPath(destination.path + ".helix-replaced-\(token)")

        func failure(_ step: ReplaceError.Step, _ cause: any Error, recoveryFailures: [ReplaceError.StepFailure] = []) -> ReplaceError {
            ReplaceError(
                source: source.formatted, destination: destination.formatted,
                incoming: incoming.formatted, setAside: setAside.formatted,
                failure: ReplaceError.StepFailure(step: step, cause: cause), recoveryFailures: recoveryFailures
            )
        }
        func recover(_ step: ReplaceError.Step, _ action: () async throws -> Void) async -> [ReplaceError.StepFailure] {
            do {
                try await action()
                return []
            } catch {
                return [ReplaceError.StepFailure(step: step, cause: error)]
            }
        }
        func removeCopy() async -> [ReplaceError.StepFailure] {
            await recover(.removeCopy) { try await remove(endpoint: incoming) }
        }

        do {
            try await copy(from: source, to: incoming)
        } catch {
            throw failure(.copySource, error, recoveryFailures: await removeCopy())
        }
        let destinationExists: Bool
        do {
            // A dangling symlink fails `test -e` yet still holds the name, and mv cannot rename a directory over it.
            if try await pathExists(endpoint: destination) {
                destinationExists = true
            } else {
                destinationExists = try await isSymlink(endpoint: destination)
            }
        } catch {
            throw failure(.checkDestination, error, recoveryFailures: await removeCopy())
        }
        if destinationExists {
            do {
                try await move(destination, toPath: setAside.path)
            } catch {
                throw failure(.setOriginalAside, error, recoveryFailures: await removeCopy())
            }
        }
        do {
            try await move(incoming, toPath: destination.path)
        } catch {
            var recoveryFailures: [ReplaceError.StepFailure] = []
            if destinationExists {
                recoveryFailures += await recover(.restoreOriginal) { try await move(setAside, toPath: destination.path) }
            }
            recoveryFailures += await removeCopy()
            throw failure(.moveCopyIntoPlace, error, recoveryFailures: recoveryFailures)
        }
        if destinationExists {
            do {
                try await remove(endpoint: setAside)
            } catch {
                throw failure(.removeSetAsideOriginal, error)
            }
        }
    }

    /// Renames a path on its own host; source and target always share the endpoint's machine.
    private func move(_ item: EndpointURL, toPath newPath: String) async throws {
        switch item {
        case .local(let path):
            _ = try await execute("/bin/mv", [path, newPath])
        case .ssh(let user, let host, let port, let path):
            var args: [String] = []
            if let port { args += ["-p", "\(port)"] }
            args += [sshTarget(user: user, host: host), "mv \(Self.shellWord(path)) \(Self.shellWord(newPath))"]
            _ = try await execute("/usr/bin/ssh", args)
        case .docker(let container, let path):
            _ = try await execute("/usr/bin/docker", ["exec", container, "mv", path, newPath])
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
            args += [sshTarget(user: user, host: host), "stat -c '%s %Y' \(Self.shellWord(path)) 2>/dev/null || stat -f '%z %m' \(Self.shellWord(path))"]
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
            args += [sshTarget(user: user, host: host), "cat \(Self.shellWord(path))"]
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
            args += [sshTarget(user: user, host: host), "rm -rf \(Self.shellWord(path))"]
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
                args += [sshTarget(user: user, host: host), "test -d \(Self.shellWord(path))"]
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
                args += [sshTarget(user: user, host: host), "test -L \(Self.shellWord(path))"]
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
            args += [sshTarget(user: user, host: host), "readlink \(Self.shellWord(path))"]
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
                args += [sshTarget(user: user, host: host), "test -e \(Self.shellWord(path))"]
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
            args += [sshTarget(user: user, host: host), "cd \(Self.shellWord(path)) && \(command)"]
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

private extension EndpointURL {
    var path: String {
        switch self {
        case .local(let path), .ssh(_, _, _, let path), .docker(_, let path):
            return path
        }
    }

    func withPath(_ newPath: String) -> EndpointURL {
        switch self {
        case .local:
            return .local(path: newPath)
        case .ssh(let user, let host, let port, _):
            return .ssh(user: user, host: host, port: port, path: newPath)
        case .docker(let container, _):
            return .docker(container: container, path: newPath)
        }
    }
}
