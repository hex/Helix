// ABOUTME: Process wrapper for executing mutagen CLI commands.
// ABOUTME: Each method spawns a fresh Process, enabling concurrent CLI calls.

import Foundation

public struct CLIError: LocalizedError, Sendable {
    public let exitCode: Int32
    public let stderr: String

    public var errorDescription: String? { stderr }
}

private struct SyncCreateReceiptError: LocalizedError {
    var errorDescription: String? {
        "Mutagen did not report a valid identifier for the created sync session."
    }
}

public struct CLI: Sendable {
    public static let defaultExecutablePath = "/opt/homebrew/bin/mutagen"

    let executablePath: String
    let baseArguments: [String]
    private let execute: @Sendable (String, [String], Duration) async throws -> String

    public init(executablePath: String = CLI.defaultExecutablePath, baseArguments: [String] = []) {
        self.init(executablePath: executablePath, baseArguments: baseArguments) { path, arguments, deadline in
            try await runProcess(executablePath: path, arguments: arguments, deadline: deadline)
        }
    }

    init(
        executablePath: String, baseArguments: [String],
        execute: @escaping @Sendable (String, [String], Duration) async throws -> String
    ) {
        self.executablePath = executablePath
        self.baseArguments = baseArguments
        self.execute = execute
    }

    public func syncList() async throws -> [SyncSession] {
        let output = try await run(["sync", "list", "--template", "{{json .}}"], deadline: CommandDeadline.query)
        return try JSONDecoder().decode([SyncSession].self, from: Data(output.utf8))
    }

    public func forwardList() async throws -> [ForwardSession] {
        let output = try await run(["forward", "list", "--template", "{{json .}}"], deadline: CommandDeadline.query)
        return try JSONDecoder().decode([ForwardSession].self, from: Data(output.utf8))
    }

    public func version() async throws -> String {
        let output = try await run(["version"], deadline: CommandDeadline.query)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Session Creation

    public func syncCreate(arguments: [String]) async throws -> String {
        let output = try await run(arguments, deadline: CommandDeadline.transfer)
        let prefix = "Created session "
        guard let receipt = output.split(whereSeparator: \.isNewline).last, receipt.hasPrefix(prefix) else {
            throw SyncCreateReceiptError()
        }

        let identifier = String(receipt.dropFirst(prefix.count))
        guard identifier.range(of: #"^sync_[0-9a-zA-Z]{43}$"#, options: .regularExpression) != nil else {
            throw SyncCreateReceiptError()
        }
        return identifier
    }

    public func forwardCreate(arguments: [String]) async throws {
        _ = try await run(arguments, deadline: CommandDeadline.operation)
    }

    // MARK: - Sync Actions

    public func syncPause(_ identifier: String) async throws {
        _ = try await run(["sync", "pause", identifier], deadline: CommandDeadline.operation)
    }

    public func syncResume(_ identifier: String) async throws {
        _ = try await run(["sync", "resume", identifier], deadline: CommandDeadline.transfer)
    }

    public func syncFlush(_ identifier: String) async throws {
        _ = try await run(["sync", "flush", identifier], deadline: CommandDeadline.transfer)
    }

    public func syncReset(_ identifier: String) async throws {
        _ = try await run(["sync", "reset", identifier], deadline: CommandDeadline.operation)
    }

    public func syncTerminate(_ identifier: String) async throws {
        _ = try await run(["sync", "terminate", identifier], deadline: CommandDeadline.operation)
    }

    // MARK: - Forward Actions

    public func forwardPause(_ identifier: String) async throws {
        _ = try await run(["forward", "pause", identifier], deadline: CommandDeadline.operation)
    }

    public func forwardResume(_ identifier: String) async throws {
        _ = try await run(["forward", "resume", identifier], deadline: CommandDeadline.operation)
    }

    public func forwardTerminate(_ identifier: String) async throws {
        _ = try await run(["forward", "terminate", identifier], deadline: CommandDeadline.operation)
    }

    // MARK: - Daemon

    public func daemonRunning() async throws -> Bool {
        do {
            _ = try await run(["daemon", "start"], deadline: CommandDeadline.operation)
            return true
        } catch let error as CLIError {
            if error.exitCode != 0 {
                return false
            }
            throw error
        }
    }

    public func daemonStop() async throws {
        _ = try await run(["daemon", "stop"], deadline: CommandDeadline.operation)
    }

    public func daemonStart() async throws {
        _ = try await run(["daemon", "start"], deadline: CommandDeadline.operation)
    }

    public func daemonRegister() async throws {
        _ = try await run(["daemon", "register"], deadline: CommandDeadline.operation)
    }

    public func daemonUnregister() async throws {
        _ = try await run(["daemon", "unregister"], deadline: CommandDeadline.operation)
    }

    private func run(_ arguments: [String], deadline: Duration) async throws -> String {
        try await execute(executablePath, baseArguments + arguments, deadline)
    }
}
