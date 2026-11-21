// ABOUTME: Protocol abstracting mutagen CLI access for testability.
// ABOUTME: SessionStore depends on this rather than CLI directly.

import Foundation

public protocol SessionProvider: Sendable {
    // Read operations
    func syncList() async throws -> [SyncSession]
    func forwardList() async throws -> [ForwardSession]
    func daemonRunning() async throws -> Bool
    func version() async throws -> String

    // Session creation
    func syncCreate(arguments: [String]) async throws -> String
    func forwardCreate(arguments: [String]) async throws

    // Sync actions
    func syncPause(_ identifier: String) async throws
    func syncResume(_ identifier: String) async throws
    func syncFlush(_ identifier: String) async throws
    func syncReset(_ identifier: String) async throws
    func syncTerminate(_ identifier: String) async throws

    // Forward actions
    func forwardPause(_ identifier: String) async throws
    func forwardResume(_ identifier: String) async throws
    func forwardTerminate(_ identifier: String) async throws

    // Daemon
    func daemonStart() async throws
    func daemonStop() async throws
    func daemonRegister() async throws
    func daemonUnregister() async throws
}

extension CLI: SessionProvider {}


struct SessionCommandsUnavailable: LocalizedError {
    var errorDescription: String? { "Start the Mutagen daemon before using session commands." }
}

/// Wraps every provider operation that can start Mutagen implicitly. The underlying provider
/// is available only here, so commands added to SessionProvider have to go through this boundary.
@MainActor
final class ManagedSessionProvider: SessionProvider {
    enum Control {
        case managed, starting, stopping, stopped
    }

    var control = Control.managed
    var unavailable: SessionCommandsUnavailable? {
        control == .managed ? nil : SessionCommandsUnavailable()
    }

    private var underlying: any SessionProvider
    private var pendingCommands = 0
    private var commandsDrained: CheckedContinuation<Void, Never>?

    init(_ underlying: any SessionProvider) {
        self.underlying = underlying
    }

    func replace(with provider: any SessionProvider) {
        underlying = provider
    }

    private func command<Result: Sendable>(
        _ run: (any SessionProvider) async throws -> Result
    ) async throws -> Result {
        if let unavailable { throw unavailable }
        pendingCommands += 1
        defer {
            pendingCommands -= 1
            if pendingCommands == 0 {
                commandsDrained?.resume()
                commandsDrained = nil
            }
        }
        return try await run(underlying)
    }

    func syncList() async throws -> [SyncSession] {
        try await command { try await $0.syncList() }
    }

    func forwardList() async throws -> [ForwardSession] {
        try await command { try await $0.forwardList() }
    }

    func daemonRunning() async throws -> Bool {
        try await command { try await $0.daemonRunning() }
    }

    func version() async throws -> String {
        try await underlying.version()
    }

    func syncCreate(arguments: [String]) async throws -> String {
        try await command { try await $0.syncCreate(arguments: arguments) }
    }

    func forwardCreate(arguments: [String]) async throws {
        try await command { try await $0.forwardCreate(arguments: arguments) }
    }

    func syncPause(_ identifier: String) async throws {
        try await command { try await $0.syncPause(identifier) }
    }

    func syncResume(_ identifier: String) async throws {
        try await command { try await $0.syncResume(identifier) }
    }

    func syncFlush(_ identifier: String) async throws {
        try await command { try await $0.syncFlush(identifier) }
    }

    func syncReset(_ identifier: String) async throws {
        try await command { try await $0.syncReset(identifier) }
    }

    func syncTerminate(_ identifier: String) async throws {
        try await command { try await $0.syncTerminate(identifier) }
    }

    func forwardPause(_ identifier: String) async throws {
        try await command { try await $0.forwardPause(identifier) }
    }

    func forwardResume(_ identifier: String) async throws {
        try await command { try await $0.forwardResume(identifier) }
    }

    func forwardTerminate(_ identifier: String) async throws {
        try await command { try await $0.forwardTerminate(identifier) }
    }

    func daemonStart() async throws {
        try await underlying.daemonStart()
    }

    func daemonStop() async throws {
        if pendingCommands > 0 {
            await withCheckedContinuation { commandsDrained = $0 }
        }
        try await underlying.daemonStop()
    }

    func daemonRegister() async throws {
        try await command { try await $0.daemonRegister() }
    }

    func daemonUnregister() async throws {
        try await command { try await $0.daemonUnregister() }
    }
}
