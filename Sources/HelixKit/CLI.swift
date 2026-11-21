// ABOUTME: Process wrapper for executing mutagen CLI commands.
// ABOUTME: Each method spawns a fresh Process, enabling concurrent CLI calls.

import Foundation

public struct CLIError: LocalizedError, Sendable {
    public let exitCode: Int32
    public let stderr: String

    public var errorDescription: String? { stderr }
}

public struct CLI: Sendable {
    public static let defaultExecutablePath = "/opt/homebrew/bin/mutagen"

    let executablePath: String
    let baseArguments: [String]

    public init(executablePath: String = CLI.defaultExecutablePath, baseArguments: [String] = []) {
        self.executablePath = executablePath
        self.baseArguments = baseArguments
    }

    public func syncList() async throws -> [SyncSession] {
        let output = try await run(["sync", "list", "--template", "{{json .}}"])
        return try JSONDecoder().decode([SyncSession].self, from: Data(output.utf8))
    }

    public func forwardList() async throws -> [ForwardSession] {
        let output = try await run(["forward", "list", "--template", "{{json .}}"])
        return try JSONDecoder().decode([ForwardSession].self, from: Data(output.utf8))
    }

    public func version() async throws -> String {
        let output = try await run(["version"])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Session Creation

    public func syncCreate(arguments: [String]) async throws {
        _ = try await run(arguments)
    }

    public func forwardCreate(arguments: [String]) async throws {
        _ = try await run(arguments)
    }

    // MARK: - Sync Actions

    public func syncPause(_ identifier: String) async throws {
        _ = try await run(["sync", "pause", identifier])
    }

    public func syncResume(_ identifier: String) async throws {
        _ = try await run(["sync", "resume", identifier])
    }

    public func syncFlush(_ identifier: String) async throws {
        _ = try await run(["sync", "flush", identifier])
    }

    public func syncReset(_ identifier: String) async throws {
        _ = try await run(["sync", "reset", identifier])
    }

    public func syncTerminate(_ identifier: String) async throws {
        _ = try await run(["sync", "terminate", identifier])
    }

    // MARK: - Forward Actions

    public func forwardPause(_ identifier: String) async throws {
        _ = try await run(["forward", "pause", identifier])
    }

    public func forwardResume(_ identifier: String) async throws {
        _ = try await run(["forward", "resume", identifier])
    }

    public func forwardTerminate(_ identifier: String) async throws {
        _ = try await run(["forward", "terminate", identifier])
    }

    // MARK: - Daemon

    public func daemonRunning() async throws -> Bool {
        do {
            _ = try await run(["daemon", "start"])
            return true
        } catch let error as CLIError {
            if error.exitCode != 0 {
                return false
            }
            throw error
        }
    }

    public func daemonStop() async throws {
        _ = try await run(["daemon", "stop"])
    }

    public func daemonStart() async throws {
        _ = try await run(["daemon", "start"])
    }

    public func daemonRegister() async throws {
        _ = try await run(["daemon", "register"])
    }

    public func daemonUnregister() async throws {
        _ = try await run(["daemon", "unregister"])
    }

    func run(_ arguments: [String]) async throws -> String {
        try await runProcess(executablePath: executablePath, arguments: baseArguments + arguments)
    }
}
