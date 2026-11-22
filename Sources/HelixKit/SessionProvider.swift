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
    case absent, paused, running, unconnected, unknown

    var description: String {
        switch self {
        case .absent: "is no longer listed"
        case .paused: "is paused"
        case .running: "is still running"
        case .unconnected: "does not show both endpoints connected"
        case .unknown: "could not be verified"
        }
    }
}

struct MutationNotConfirmed: LocalizedError {
    let cause: any Error
    let observation: ObservedMutationState

    var errorDescription: String? { cause.localizedDescription }
}

public struct SyncResumeConflict: LocalizedError {
    @MainActor
    fileprivate final class Approval {
        var used = false
    }

    let identifier: String
    fileprivate let endpoints: SyncEndpointPair
    fileprivate let peers: Set<String>
    fileprivate let approval: Approval
    public let message: String

    public var errorDescription: String? { message }
}

public enum SyncResumePrompt: Sendable {
    case held(String)
    case overlap(SyncResumeConflict)
}

struct SyncEndpointPair: Equatable, Sendable {
    private typealias Location = (String, String?, String?, Int?, String?)
    private let alpha: Location
    private let beta: Location

    init(_ session: SyncSession) {
        self.init(alpha: Self.location(session.alpha), beta: Self.location(session.beta))
    }

    init(alpha: EndpointURL, beta: EndpointURL) {
        self.init(alpha: Self.location(alpha), beta: Self.location(beta))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.alpha == rhs.alpha && lhs.beta == rhs.beta)
            || (lhs.alpha == rhs.beta && lhs.beta == rhs.alpha)
    }

    private init(alpha: Location, beta: Location) {
        self.alpha = Self.normalizingTemporaryPath(alpha)
        self.beta = Self.normalizingTemporaryPath(beta)
    }

    private static func normalizingTemporaryPath(_ location: Location) -> Location {
        let (transport, user, host, port, path) = location
        // macOS exposes the same temporary directory at both paths, even for an uncreated child.
        guard transport == "local", let path, path == "/private/tmp" || path.hasPrefix("/private/tmp/") else {
            return location
        }
        return (transport, user, host, port, String(path.dropFirst("/private".count)))
    }

    private static func location(_ endpoint: Endpoint) -> Location {
        (endpoint.protocol_, endpoint.user, endpoint.host, endpoint.port, endpoint.path)
    }

    private static func location(_ endpoint: EndpointURL) -> Location {
        switch endpoint {
        case .local(let path):
            let expanded = (path as NSString).expandingTildeInPath
            return ("local", nil, nil, nil, URL(fileURLWithPath: expanded).standardizedFileURL.path)
        case .ssh(let user, let host, let port, let path):
            return ("ssh", user, host, port, path)
        case .docker(let container, let path):
            return ("docker", nil, container, nil, path)
        }
    }
}

struct SyncResumeRestoration: Sendable {
    let endpoints: SyncEndpointPair
    let peers: Set<String>

    init?(identifier: String, listed: [SyncSession]) {
        guard let target = listed.first(where: { $0.identifier == identifier }), !target.paused else { return nil }
        let endpoints = SyncEndpointPair(target)
        self.endpoints = endpoints
        peers = Set(listed.lazy.filter {
            $0.identifier != identifier && !$0.paused && SyncEndpointPair($0) == endpoints
        }.map(\.identifier))
    }
}

enum SyncResumeContext {
    case ordinary
    case restoring(SyncResumeRestoration?)
    case approved(SyncResumeConflict)

    @MainActor
    func allowedPeers(for target: SyncSession, endpoints: SyncEndpointPair) -> Set<String> {
        switch self {
        case .ordinary:
            return []
        case .restoring(let snapshot):
            guard let snapshot, snapshot.endpoints == endpoints else { return [] }
            return snapshot.peers
        case .approved(let conflict):
            guard conflict.identifier == target.identifier, conflict.endpoints == endpoints, !conflict.approval.used else { return [] }
            conflict.approval.used = true
            return conflict.peers
        }
    }
}

private struct UnlistedSyncSession: LocalizedError {
    let identifier: String
    var errorDescription: String? { "Cannot resume session \(identifier) because Mutagen does not list it." }
}

/// Wraps every provider operation that can start Mutagen implicitly. The underlying provider
/// is available only here, so commands added to SessionProvider have to go through this boundary.
@MainActor
final class ManagedSessionProvider {
    enum Control {
        case managed, starting, stopping, stopped
    }

    enum ResumeReadback {
        case unpaused, connectedEndpoints
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
            guard error.isCommandInterruption, observed == expected else {
                throw MutationNotConfirmed(cause: error, observation: observed)
            }
        }
    }

    func observeSyncState(_ identifier: String) async -> ObservedMutationState {
        await observeSyncState(identifier, on: underlying)
    }

    private func observeSyncState(
        _ identifier: String, on provider: any SessionProvider, readback: ResumeReadback = .unpaused
    ) async -> ObservedMutationState {
        // A cancelled caller still needs an answer, and a list must respect the Stop fence.
        await Task { @MainActor in
            do {
                let sessions = try await command { _ in try await provider.syncList() }
                guard let session = sessions.first(where: { $0.identifier == identifier }) else { return .absent }
                if session.paused { return .paused }
                if readback == .connectedEndpoints, session.alpha.connected != true || session.beta.connected != true {
                    return .unconnected
                }
                return .running
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

    func pauseForRestoration(_ identifier: String) async throws -> SyncResumeRestoration? {
        let snapshot = SyncResumeRestoration(identifier: identifier, listed: try await syncList())
        try await syncPause(identifier)
        return snapshot
    }

    func syncResume(
        _ identifier: String, context: SyncResumeContext = .ordinary, readback: ResumeReadback = .unpaused
    ) async throws {
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
                throw UnlistedSyncSession(identifier: identifier)
            }
            let endpoints = SyncEndpointPair(target)
            let allowed = context.allowedPeers(for: target, endpoints: endpoints)
            let running = listed.filter {
                $0.identifier != identifier && !$0.paused && SyncEndpointPair($0) == endpoints
            }
            if running.contains(where: { !allowed.contains($0.identifier) }) {
                let targetName = target.name ?? identifier
                let names = running.map { session in
                    let name = session.name ?? session.identifier
                    return name == targetName ? "\"\(name) (\(session.identifier))\"" : "\"\(name)\""
                }.joined(separator: ", ")
                let verb = running.count == 1 ? "is" : "are"
                throw SyncResumeConflict(
                    identifier: identifier, endpoints: endpoints, peers: Set(running.map(\.identifier)),
                    approval: SyncResumeConflict.Approval(),
                    message: "Cannot resume \"\(targetName)\" while \(names) \(verb) running on the same endpoints."
                )
            }

            if let unavailable { throw unavailable }
            try Task.checkCancellation()
            try await confirmMutation(.running) {
                try await provider.syncResume(identifier)
            } observe: {
                await observeSyncState(identifier, on: provider, readback: readback)
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
