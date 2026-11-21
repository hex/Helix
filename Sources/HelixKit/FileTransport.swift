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
        case removeCopy
        case restoreOriginal
        case inspectDisk
    }

    public struct StepFailure: Sendable {
        public let step: Step
        public let cause: any Error
    }

    /// What a failed replacement left at the destination.
    public enum Aftermath: Sendable, Equatable {
        /// The destination holds what it held before the replacement started.
        case destinationUnchanged
        /// The destination could not be shown to hold either the original or the replacement.
        case destinationUnverified
    }

    public let source: String
    public let destination: String
    public let incoming: String
    public let setAside: String
    public let aftermath: Aftermath
    public let failure: StepFailure
    public let recoveryFailures: [StepFailure]

    public var errorDescription: String? {
        let first = sentence(for: failure)
        let recoveries = recoveryFailures.map { recoveryFailure -> String in
            let text = sentence(for: recoveryFailure)
            return "Then " + text.prefix(1).lowercased() + text.dropFirst()
        }
        return ([first] + recoveries + [aftermathSentence].compactMap { $0 }).joined(separator: ". ")
    }

    /// What the user finds on disk, for a failure that came after the copy was made and kept.
    private var aftermathSentence: String? {
        switch (aftermath, failure.step) {
        case (.destinationUnverified, _):
            return "Nothing was deleted: look for the original at \(setAside) and for the replacement at \(incoming)"
        case (.destinationUnchanged, .setOriginalAside), (.destinationUnchanged, .moveCopyIntoPlace):
            return "\(destination) is unchanged, and the unused copy is still at \(incoming)"
        case (.destinationUnchanged, _):
            return nil
        }
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
        case .removeCopy:
            return "Could not remove the copy at \(incoming): \(cause)"
        case .restoreOriginal:
            return "Could not move the original back from \(setAside) to \(destination): \(cause)"
        case .inspectDisk:
            return "Could not check what the failed move left on disk: \(cause)"
        }
    }
}

/// How a replacement that put the copy in place ended.
public enum ReplaceOutcome: Sendable, Equatable {
    case replaced
    /// The destination holds the copy; the original it displaced is still beside it at `path`.
    case replacedLeavingOriginal(path: String, reason: String)
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

    /// Replaces `destination` with a copy of `source`. The copy lands beside it as
    /// `<name>.helix-incoming-<uuid>` and then takes its name. Where one rename can do that (nothing at the
    /// destination, or neither side a directory) the destination never goes missing. Otherwise the original
    /// first moves aside to `<name>.helix-replaced-<uuid>` and is removed once the copy is in place.
    ///
    /// A failure before anything at the destination is touched removes the copy and throws. From the first
    /// move onward a failure deletes nothing: what is on disk decides whether the replacement happened, the
    /// original is still or again in place, or neither can be shown, and the thrown `ReplaceError` says which.
    /// A set-aside original that cannot be removed does not undo the replacement: it is returned in the outcome.
    public func replace(_ destination: EndpointURL, withCopyOf source: EndpointURL) async throws -> ReplaceOutcome {
        let token = UUID().uuidString
        let incoming = destination.withPath(destination.path + ".helix-incoming-\(token)")
        let setAside = destination.withPath(destination.path + ".helix-replaced-\(token)")

        func failure(
            _ step: ReplaceError.Step, _ cause: any Error,
            aftermath: ReplaceError.Aftermath, recoveryFailures: [ReplaceError.StepFailure] = []
        ) -> ReplaceError {
            ReplaceError(
                source: source.formatted, destination: destination.formatted,
                incoming: incoming.formatted, setAside: setAside.formatted, aftermath: aftermath,
                failure: ReplaceError.StepFailure(step: step, cause: cause), recoveryFailures: recoveryFailures
            )
        }
        func removeCopy() async -> [ReplaceError.StepFailure] {
            do {
                try await remove(endpoint: incoming)
                return []
            } catch {
                return [ReplaceError.StepFailure(step: .removeCopy, cause: error)]
            }
        }
        /// Whether anything, a dangling symlink included, holds the name.
        func holdsName(_ endpoint: EndpointURL) async throws -> Bool {
            if try await pathExists(endpoint: endpoint) { return true }
            return try await isSymlink(endpoint: endpoint)
        }
        /// Ends a replacement whose move at `step` failed, by reading what the move left on disk.
        func settle(_ step: ReplaceError.Step, _ cause: any Error, swap: Swap) async throws -> ReplaceOutcome {
            let onDisk: (destination: Bool, incoming: Bool, setAside: Bool)
            do {
                onDisk = (try await holdsName(destination), try await holdsName(incoming), try await holdsName(setAside))
            } catch {
                throw failure(step, cause, aftermath: .destinationUnverified, recoveryFailures: [ReplaceError.StepFailure(step: .inspectDisk, cause: error)])
            }
            switch (onDisk.destination, onDisk.incoming, onDisk.setAside, swap) {
            case (true, false, true, .setAsideThenRename):
                return .replacedLeavingOriginal(path: setAside.formatted, reason: cause.localizedDescription)
            case (true, false, false, .renameOverOriginal), (true, false, false, .renameIntoFreeName):
                return .replaced
            case (true, true, false, .setAsideThenRename), (true, true, false, .renameOverOriginal),
                 (false, true, false, .renameIntoFreeName):
                throw failure(step, cause, aftermath: .destinationUnchanged)
            case (false, true, true, .setAsideThenRename):
                do {
                    try await move(setAside, toPath: destination.path)
                } catch {
                    throw failure(step, cause, aftermath: .destinationUnverified, recoveryFailures: [ReplaceError.StepFailure(step: .restoreOriginal, cause: error)])
                }
                throw failure(step, cause, aftermath: .destinationUnchanged)
            default:
                throw failure(step, cause, aftermath: .destinationUnverified)
            }
        }

        do {
            try await copy(from: source, to: incoming)
        } catch {
            throw failure(.copySource, error, aftermath: .destinationUnchanged, recoveryFailures: await removeCopy())
        }
        let swap: Swap
        do {
            if try await !holdsName(destination) {
                swap = .renameIntoFreeName
            } else if try await directoryExists(endpoint: destination) {
                // mv moves its source inside a destination that is a directory or a symlink to one.
                swap = .setAsideThenRename
            } else if try await directoryExists(endpoint: incoming) {
                // mv cannot rename a directory over a file or a symlink.
                swap = .setAsideThenRename
            } else {
                swap = .renameOverOriginal
            }
        } catch {
            throw failure(.checkDestination, error, aftermath: .destinationUnchanged, recoveryFailures: await removeCopy())
        }

        if swap == .setAsideThenRename {
            do {
                try await move(destination, toPath: setAside.path)
            } catch {
                return try await settle(.setOriginalAside, error, swap: swap)
            }
        }
        do {
            try await move(incoming, toPath: destination.path)
        } catch {
            return try await settle(.moveCopyIntoPlace, error, swap: swap)
        }
        guard swap == .setAsideThenRename else { return .replaced }
        do {
            try await remove(endpoint: setAside)
        } catch {
            return .replacedLeavingOriginal(path: setAside.formatted, reason: error.localizedDescription)
        }
        return .replaced
    }

    /// How the incoming copy takes the destination's name.
    private enum Swap {
        /// Nothing holds the name, so one rename puts the copy there.
        case renameIntoFreeName
        /// Neither side is a directory, so one rename replaces the original with no moment in which the name is free.
        case renameOverOriginal
        /// A directory is involved, which one rename cannot replace: the original moves aside first.
        case setAsideThenRename
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
            return try await execute("/bin/sh", ["-c", "cd \(Self.shellWord(path)) && \(command)"])
        case .ssh(let user, let host, let port, let path):
            var args: [String] = []
            if let port { args += ["-p", "\(port)"] }
            args += [sshTarget(user: user, host: host), "cd \(Self.shellWord(path)) && \(command)"]
            return try await execute("/usr/bin/ssh", args)
        case .docker(let container, let path):
            return try await execute("/usr/bin/docker", ["exec", container, "sh", "-c", "cd \(Self.shellWord(path)) && \(command)"])
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

    /// Makes a path exactly one inert word for a POSIX shell.
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
