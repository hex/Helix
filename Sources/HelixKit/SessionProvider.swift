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

enum ObservedMutationState: Equatable {
    case absent, paused, running, unknown

    var description: String {
        switch self {
        case .absent: "is no longer listed"
        case .paused: "is paused"
        case .running: "is still running"
        case .unknown: "could not be verified"
        }
    }
}

struct MutationNotConfirmed: LocalizedError {
    let cause: any Error
    let observation: ObservedMutationState

    var errorDescription: String? { cause.localizedDescription }
}

private enum SyncResumeRefusal: LocalizedError {
    case notListed(String)
    case matchingSession(target: String, running: String)

    var errorDescription: String? {
        switch self {
        case .notListed(let identifier):
            "Cannot resume session \(identifier) because Mutagen does not list it."
        case .matchingSession(let target, let running):
            "Cannot resume \"\(target)\" while \"\(running)\" is running on the same endpoints."
        }
    }
}

private extension Endpoint {
    var location: (String, String?, String?, Int?, String?) {
        (protocol_, user, host, port, path)
    }
}

private extension SyncSession {
    func sharesEndpoints(with other: SyncSession) -> Bool {
        (alpha.location == other.alpha.location && beta.location == other.beta.location)
            || (alpha.location == other.beta.location && beta.location == other.alpha.location)
    }
}

/// Wraps every provider operation that can start Mutagen implicitly. The underlying provider
/// is available only here, so commands added to SessionProvider have to go through this boundary.
@MainActor
final class ManagedSessionProvider {
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
    private var resuming = false
    private var waitingToResume: [CheckedContinuation<Void, Never>] = []

    var hasPendingCommands: Bool { pendingCommands > 0 }

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

    private func confirmMutation(
        _ expected: ObservedMutationState,
        run: () async throws -> Void,
        observe: () async -> ObservedMutationState
    ) async throws {
        do {
            try await run()
        } catch {
            let observed = await observe()
            guard observed == expected else {
                throw MutationNotConfirmed(cause: error, observation: observed)
            }
        }
    }

    func observeSyncState(_ identifier: String) async -> ObservedMutationState {
        await observeSyncState(identifier, on: underlying)
    }

    private func observeSyncState(_ identifier: String, on provider: any SessionProvider) async -> ObservedMutationState {
        // A cancelled caller still needs an answer, and a list must respect the Stop fence.
        await Task { @MainActor in
            do {
                let sessions = try await command { _ in try await provider.syncList() }
                guard let session = sessions.first(where: { $0.identifier == identifier }) else { return .absent }
                return session.paused ? .paused : .running
            } catch {
                return .unknown
            }
        }.value
    }

    func syncPause(_ identifier: String) async throws {
        try await command { provider in
            try await confirmMutation(.paused) {
                try await provider.syncPause(identifier)
            } observe: {
                await observeSyncState(identifier, on: provider)
            }
        }
    }

    func syncResume(_ identifier: String) async throws {
        // Keep the list and the command together across concurrent resumes.
        if resuming { await withCheckedContinuation { waitingToResume.append($0) } }
        resuming = true
        defer {
            if waitingToResume.isEmpty {
                resuming = false
            } else {
                waitingToResume.removeFirst().resume()
            }
        }

        try Task.checkCancellation()
        try await command { provider in
            let listed = try await provider.syncList()
            guard let target = listed.first(where: { $0.identifier == identifier }) else {
                throw SyncResumeRefusal.notListed(identifier)
            }
            if let running = listed.first(where: {
                $0.identifier != identifier && !$0.paused && target.sharesEndpoints(with: $0)
            }) {
                let targetName = target.name ?? identifier
                let runningName = running.name ?? running.identifier
                throw SyncResumeRefusal.matchingSession(
                    target: targetName, running: runningName == targetName ? "\(runningName) (\(running.identifier))" : runningName
                )
            }

            if let unavailable { throw unavailable }
            try Task.checkCancellation()
            try await confirmMutation(.running) {
                try await provider.syncResume(identifier)
            } observe: {
                await observeSyncState(identifier, on: provider)
            }
        }
    }

    func syncFlush(_ identifier: String) async throws {
        try await command { try await $0.syncFlush(identifier) }
    }

    func syncReset(_ identifier: String) async throws {
        try await command { try await $0.syncReset(identifier) }
    }

    func syncTerminate(_ identifier: String) async throws {
        try await command { provider in
            try await confirmMutation(.absent) {
                try await provider.syncTerminate(identifier)
            } observe: {
                await observeSyncState(identifier, on: provider)
            }
        }
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

    private func observeDaemon(_ daemon: any DaemonProcess) async -> ObservedMutationState {
        await Task {
            do {
                return try await daemon.pid() == nil ? .absent : .running
            } catch {
                return .unknown
            }
        }.value
    }

    func daemonStart(observing daemon: any DaemonProcess) async throws {
        try await confirmMutation(.running) {
            try await underlying.daemonStart()
        } observe: {
            await observeDaemon(daemon)
        }
    }

    func waitForPendingCommands() async {
        precondition(control == .stopping && commandsDrained == nil)
        if hasPendingCommands {
            await withCheckedContinuation { commandsDrained = $0 }
        }
    }

    func daemonStop(observing daemon: any DaemonProcess, checkingStatus: () -> Void) async throws {
        precondition(control == .stopping && !hasPendingCommands)
        try await confirmMutation(.absent) {
            try await underlying.daemonStop()
        } observe: {
            checkingStatus()
            return await observeDaemon(daemon)
        }
    }

    func daemonRegister() async throws {
        try await command { try await $0.daemonRegister() }
    }

    func daemonUnregister() async throws {
        try await command { try await $0.daemonUnregister() }
    }
}
