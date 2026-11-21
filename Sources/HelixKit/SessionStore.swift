// ABOUTME: Observable state container for all mutagen sessions.
// ABOUTME: Polls CLI periodically and exposes typed session arrays for SwiftUI binding.

import Foundation

public enum GitRepoStatus: Sendable, Equatable {
    case symmetric   // Both or neither have .git
    case alphaOnly   // Only alpha has .git
    case betaOnly    // Only beta has .git
    case unknown     // Transport error
}

public struct GitRepoCheck: Sendable, Equatable {
    public let status: GitRepoStatus
    public let subpath: String  // Relative path from sync root ("" for root)
    public let hasRemote: Bool  // Whether the source .git has a remote configured

    public init(status: GitRepoStatus, subpath: String = "", hasRemote: Bool = false) {
        self.status = status
        self.subpath = subpath
        self.hasRemote = hasRemote
    }
}

/// Sync sessions paused together by Pause All, resumed together later.
public struct BulkPause: Codable, Equatable, Sendable {
    public let sessionIdentifiers: [String]
    /// When the sessions resume on their own; nil keeps them paused until resumed by hand.
    public let resumeAt: Date?

    public init(sessionIdentifiers: [String], resumeAt: Date?) {
        self.sessionIdentifiers = sessionIdentifiers
        self.resumeAt = resumeAt
    }
}

public enum HealthStatus: Sendable {
    case healthy
    case active
    case warning
    case error
    case idle
}

@MainActor
@Observable
public final class SessionStore {
    public private(set) var syncSessions: [SyncSession] = []
    public private(set) var forwardSessions: [ForwardSession] = []
    public private(set) var daemonRunning = false
    public private(set) var daemonAutoStart = false
    public private(set) var mutagenVersion: String?
    public private(set) var lastError: String?
    public private(set) var refreshCount = 0
    public var pendingSessionSelection: String?
    public private(set) var bulkPause: BulkPause? {
        didSet { persistBulkPause() }
    }
    /// Why a sync session is kept paused, by session identifier: a conflict replacement left a path that
    /// could not be shown to hold either version, and the message names where the data is. While a session
    /// has an entry the store never resumes it on its own; only `resumeSync` on that session does.
    public private(set) var sessionHolds: [String: String] = [:] {
        didSet { persist(sessionHolds, forKey: Self.sessionHoldsKey) }
    }
    /// Set-aside originals that resolved conflicts left on disk for the user to delete, by session identifier.
    /// A notice does not stop its session from syncing; it stays until dismissed or until the session is gone.
    public private(set) var leftoverNotices: [String: String] = [:] {
        didSet { persist(leftoverNotices, forKey: Self.leftoverNoticesKey) }
    }
    /// Whether background priority is confirmed for the running daemon.
    public var daemonBackgroundPriority: Bool {
        backgroundPriorityPID != nil && daemonPriorityError == nil
    }
    public private(set) var daemonBackgroundPriorityRequested: Bool
    public private(set) var daemonPriorityError: String?

    private var provider: any SessionProvider
    private var pollingTask: Task<Void, Never>?
    private let fileTransport: FileTransport
    private let defaults: UserDefaults
    private let now: () -> Date
    private var daemonProcess: any DaemonProcess
    @ObservationIgnored private var bulkPauseInFlight = false
    /// The resolve requested last on each session; the next one on that session waits for it to end.
    @ObservationIgnored private var lastResolve: [String: Task<Set<String>, Never>] = [:]
    /// The daemon process whose background priority Helix last set successfully.
    private var backgroundPriorityPID: ProcessID?
    @ObservationIgnored private var daemonPriorityInFlight = false
    private static let bulkPauseKey = "bulkPause"
    private static let sessionHoldsKey = "sessionHolds"
    private static let leftoverNoticesKey = "leftoverNotices"
    private static let daemonBackgroundPriorityKey = "daemonBackgroundPriority"

    public init(
        provider: any SessionProvider,
        fileTransport: FileTransport = FileTransport(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        daemonProcess: any DaemonProcess = MutagenDaemon(cliPath: CLI.defaultExecutablePath)
    ) {
        self.provider = provider
        self.fileTransport = fileTransport
        self.defaults = defaults
        self.now = now
        self.daemonProcess = daemonProcess
        daemonBackgroundPriorityRequested = defaults.bool(forKey: Self.daemonBackgroundPriorityKey)
        if let data = defaults.data(forKey: Self.bulkPauseKey) {
            do {
                bulkPause = try JSONDecoder().decode(BulkPause.self, from: data)
            } catch {
                let message = "Ignoring the saved Pause All record: \(error.localizedDescription)"
                ConsoleLog.shared.log(message, level: .error)
                lastError = message
            }
        }
        sessionHolds = savedMessages(forKey: Self.sessionHoldsKey, called: "sessions kept paused after a conflict")
        leftoverNotices = savedMessages(forKey: Self.leftoverNoticesKey, called: "originals left on disk after a conflict")
    }

    /// Reads messages by session identifier saved under `key`. A value of another shape is reported and read as none.
    private func savedMessages(forKey key: String, called description: String) -> [String: String] {
        guard let saved = defaults.object(forKey: key) else { return [:] }
        guard let messages = saved as? [String: String] else {
            let message = "Ignoring the saved record of \(description): it is not a list of messages by session."
            ConsoleLog.shared.log(message, level: .error)
            lastError = message
            return [:]
        }
        return messages
    }

    public func replaceProvider(_ provider: any SessionProvider) {
        self.provider = provider
    }

    public func replaceDaemonProcess(_ daemonProcess: any DaemonProcess) {
        self.daemonProcess = daemonProcess
    }

    public var totalSessionCount: Int {
        syncSessions.count + forwardSessions.count
    }

    /// Names held by sync sessions, for rejecting a colliding name.
    /// - Parameter identifier: the session being renamed, whose own name is not a collision.
    public func syncSessionNames(excluding identifier: String? = nil) -> [String] {
        syncSessions
            .filter { $0.identifier != identifier }
            .compactMap(\.name)
    }

    /// Names held by forward sessions. Forwards occupy a namespace of their own —
    /// `mutagen forward pause` never resolves against sync sessions.
    public func forwardSessionNames(excluding identifier: String? = nil) -> [String] {
        forwardSessions
            .filter { $0.identifier != identifier }
            .compactMap(\.name)
    }

    public var totalConflictCount: Int {
        syncSessions.reduce(0) { $0 + ($1.conflicts?.count ?? 0) }
    }

    public var overallHealth: HealthStatus {
        if !daemonRunning {
            return .error
        }
        if syncSessions.isEmpty && forwardSessions.isEmpty {
            return .idle
        }
        let running = syncSessions.filter { !$0.paused }
        let hasDisconnected = running.contains { $0.phase == .disconnected }
            || forwardSessions.contains { $0.source.connected == false || $0.destination.connected == false }
        if hasDisconnected {
            return .error
        }
        let hasConflicts = totalConflictCount > 0
        let hasHalted = running.contains { $0.phase == .halted }
        let failsToConnect = running.contains { $0.phase == .connecting && !($0.lastError ?? "").isEmpty }
        if hasConflicts || hasHalted || failsToConnect {
            return .warning
        }
        let hasActive = running.contains { $0.phase == .working || $0.phase == .connecting }
        if hasActive {
            return .active
        }
        return .healthy
    }

    public func refresh() async {
        if await reloadSessions(), let resumeAt = bulkPause?.resumeAt, now() >= resumeAt {
            await resumeBulkPause()
        }
        await reapplyDaemonBackgroundPriority()
    }

    /// Fetches the session lists. Returns false when the daemon could not be reached.
    @discardableResult
    private func reloadSessions() async -> Bool {
        do {
            async let syncs = provider.syncList()
            async let forwards = provider.forwardList()
            let newSyncs = try await syncs
            let newForwards = try await forwards
            if syncDigest(newSyncs) != syncDigest(syncSessions) { syncSessions = newSyncs }
            if forwardDigest(newForwards) != forwardDigest(forwardSessions) { forwardSessions = newForwards }
            forgetSessions(notListedIn: newSyncs)
            if !daemonRunning { daemonRunning = true }
            if lastError != nil { lastError = nil }
            return true
        } catch {
            if !daemonRunning || lastError != error.localizedDescription {
                daemonRunning = false
                lastError = error.localizedDescription
            }
            return false
        }
    }

    /// Ends the holds and drops the leftover notices of sessions the daemon no longer lists.
    private func forgetSessions(notListedIn listed: [SyncSession]) {
        let identifiers = Set(listed.map(\.identifier))
        let holds = sessionHolds.filter { identifiers.contains($0.key) }
        if holds != sessionHolds { sessionHolds = holds }
        let notices = leftoverNotices.filter { identifiers.contains($0.key) }
        if notices != leftoverNotices { leftoverNotices = notices }
    }

    public func manualRefresh() async {
        do {
            async let syncs = provider.syncList()
            async let forwards = provider.forwardList()
            syncSessions = try await syncs
            forwardSessions = try await forwards
            forgetSessions(notListedIn: syncSessions)
            if !daemonRunning { daemonRunning = true }
            if lastError != nil { lastError = nil }
        } catch {
            if !daemonRunning || lastError != error.localizedDescription {
                daemonRunning = false
                lastError = error.localizedDescription
            }
        }
        refreshCount += 1
    }

    // MARK: - Session Creation

    public func createSync(options: SyncCreateOptions, alpha: String, beta: String) async {
        let args = options.arguments(alpha: alpha, beta: beta)
        await performAction { try await provider.syncCreate(arguments: args) }
    }

    public func createForward(options: ForwardCreateOptions, source: String, destination: String) async {
        let args = options.arguments(source: source, destination: destination)
        await performAction { try await provider.forwardCreate(arguments: args) }
    }

    // MARK: - Sync Edit (Terminate + Recreate)

    public func recreateSync(
        _ session: SyncSession,
        options: SyncCreateOptions,
        alpha: String,
        beta: String
    ) async {
        do {
            try await provider.syncTerminate(session.identifier)
        } catch {
            lastError = "Terminate failed: \(error.localizedDescription). No changes were made."
            return
        }

        let args = options.arguments(alpha: alpha, beta: beta)
        let identifiersBefore = Set(syncSessions.map(\.identifier))
        do {
            try await provider.syncCreate(arguments: args)
            lastError = nil
            await refresh()
            // Recreation mints a new identifier, so whatever the caller had selected
            // no longer resolves. Hand the replacement back to the list.
            if let recreated = syncSessions.first(where: { !identifiersBefore.contains($0.identifier) }) {
                pendingSessionSelection = recreated.identifier
            }
        } catch {
            lastError = "Session terminated but recreation failed: \(error.localizedDescription). Use Create Session to recreate manually."
        }
    }

    // MARK: - Ignore List

    public func addToIgnoreList(session: SyncSession, path: String) async {
        var opts = SyncCreateOptions(from: session)
        opts.ignorePaths.append(path)
        await recreateSync(
            session,
            options: opts,
            alpha: session.alpha.endpointURL.formatted,
            beta: session.beta.endpointURL.formatted
        )
    }

    // MARK: - Bulk Pause

    /// Pauses every running sync session and records which ones it paused.
    /// - Parameter resumeAt: when `refresh()` resumes them on its own; nil waits for `resumeBulkPause()`.
    public func pauseAllSync(until resumeAt: Date? = nil) async {
        guard !bulkPauseInFlight else { return }
        bulkPauseInFlight = true
        defer { bulkPauseInFlight = false }
        guard await reloadSessions() else { return }

        var paused = bulkPause?.sessionIdentifiers ?? []
        let existingRecord = paused.isEmpty ? nil : BulkPause(sessionIdentifiers: paused, resumeAt: resumeAt)
        if bulkPause != existingRecord { bulkPause = existingRecord }

        var failures: [String] = []
        for session in syncSessions where !session.paused {
            do {
                try await provider.syncPause(session.identifier)
                if !paused.contains(session.identifier) { paused.append(session.identifier) }
                bulkPause = BulkPause(sessionIdentifiers: paused, resumeAt: resumeAt)
            } catch {
                failures.append("Could not pause \(session.name ?? session.identifier): \(error.localizedDescription)")
            }
        }
        await finishBulkAction(failures: failures)
    }

    /// Resumes the sessions Pause All paused that are still paused, except held ones. A session that fails
    /// to resume, or that a conflict resolve is working on, stays in the record so the next attempt retries it.
    public func resumeBulkPause() async {
        guard let record = bulkPause, !bulkPauseInFlight else { return }
        bulkPauseInFlight = true
        defer { bulkPauseInFlight = false }
        guard await reloadSessions() else { return }

        var unresumed: [String] = []
        var failures: [String] = []
        for session in syncSessions where session.paused && record.sessionIdentifiers.contains(session.identifier) {
            // A session whose conflict resolve is still moving files stays in the record, so the next
            // attempt resumes it if the resolve left it paused without holding it.
            if lastResolve[session.identifier] != nil {
                unresumed.append(session.identifier)
                continue
            }
            do {
                // A held session leaves the record without being resumed: its hold keeps it paused from here on.
                switch try await resumeUnlessHeld(session.identifier) {
                case .resumed, .heldBack: break
                }
            } catch {
                unresumed.append(session.identifier)
                failures.append("Could not resume \(session.name ?? session.identifier): \(error.localizedDescription)")
            }
        }
        bulkPause = unresumed.isEmpty ? nil : BulkPause(sessionIdentifiers: unresumed, resumeAt: record.resumeAt)
        await finishBulkAction(failures: failures)
    }

    /// How the store's own attempt to resume a session ended.
    private enum UnpromptedResume {
        case resumed
        case heldBack(message: String)
    }

    /// The only way the store resumes a session that the user did not ask it by name to resume: at the end
    /// of a conflict resolve, for Resume after Pause All, and at a timed pause's deadline. A held session
    /// stays paused.
    private func resumeUnlessHeld(_ identifier: String) async throws -> UnpromptedResume {
        if let message = sessionHolds[identifier] {
            return .heldBack(message: message)
        }
        try await provider.syncResume(identifier)
        return .resumed
    }

    private func persistBulkPause() {
        guard let bulkPause else {
            defaults.removeObject(forKey: Self.bulkPauseKey)
            return
        }
        // Encoding an array of strings and an optional date cannot fail.
        defaults.set(try! JSONEncoder().encode(bulkPause), forKey: Self.bulkPauseKey)
    }

    private func persist(_ messagesBySession: [String: String], forKey key: String) {
        if messagesBySession.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(messagesBySession, forKey: key)
        }
    }

    private func finishBulkAction(failures: [String]) async {
        await reloadSessions()
        if !failures.isEmpty {
            lastError = failures.joined(separator: "; ")
        }
    }

    // MARK: - Sync Actions

    public func pauseSync(_ identifier: String) async {
        await performAction { try await provider.syncPause(identifier) }
    }

    /// Resumes a session because the user asked for that session; this is what ends its hold.
    public func resumeSync(_ identifier: String) async {
        do {
            try await provider.syncResume(identifier)
        } catch {
            lastError = error.localizedDescription
            return
        }
        sessionHolds[identifier] = nil
        lastError = nil
        await refresh()
    }

    public func flushSync(_ identifier: String) async {
        await performAction { try await provider.syncFlush(identifier) }
    }

    public func resetSync(_ identifier: String) async {
        await performAction { try await provider.syncReset(identifier) }
    }

    public func terminateSync(_ identifier: String) async {
        await performAction { try await provider.syncTerminate(identifier) }
    }

    // MARK: - Forward Actions

    public func pauseForward(_ identifier: String) async {
        await performAction { try await provider.forwardPause(identifier) }
    }

    public func resumeForward(_ identifier: String) async {
        await performAction { try await provider.forwardResume(identifier) }
    }

    public func terminateForward(_ identifier: String) async {
        await performAction { try await provider.forwardTerminate(identifier) }
    }

    // MARK: - Daemon

    public func startDaemon() async {
        do {
            try await provider.daemonStart()
            daemonRunning = true
            lastError = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func stopDaemon() async {
        do {
            try await provider.daemonStop()
            daemonRunning = false
            syncSessions = []
            forwardSessions = []
            backgroundPriorityPID = nil
            setDaemonPriorityError(daemonBackgroundPriorityRequested ? "Mutagen daemon not found." : nil)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func registerDaemon() async {
        do {
            try await provider.daemonRegister()
            daemonAutoStart = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func unregisterDaemon() async {
        do {
            try await provider.daemonUnregister()
            daemonAutoStart = false
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Daemon Priority

    /// Saves the setting and applies it to the running daemon when possible.
    public func setDaemonBackgroundPriority(_ enabled: Bool) async {
        daemonBackgroundPriorityRequested = enabled
        defaults.set(enabled, forKey: Self.daemonBackgroundPriorityKey)
        await reapplyDaemonBackgroundPriority()
    }

    /// Applies the requested priority to the current daemon and retries after a restart or failure.
    private func reapplyDaemonBackgroundPriority() async {
        guard !daemonPriorityInFlight else { return }
        guard daemonBackgroundPriorityRequested || backgroundPriorityPID != nil else {
            setDaemonPriorityError(nil)
            return
        }
        daemonPriorityInFlight = true
        defer { daemonPriorityInFlight = false }

        let process = daemonProcess
        let pid: ProcessID?
        do {
            pid = try await process.pid()
        } catch {
            setDaemonPriorityError("Could not find the Mutagen daemon: \(error.localizedDescription)")
            return
        }

        let requested = daemonBackgroundPriorityRequested
        if backgroundPriorityPID != pid { backgroundPriorityPID = nil }
        guard let pid else {
            setDaemonPriorityError(requested ? "Mutagen daemon not found." : nil)
            return
        }
        if requested {
            if backgroundPriorityPID == pid, daemonPriorityError == nil { return }
        } else if backgroundPriorityPID == nil {
            setDaemonPriorityError(nil)
            return
        }
        do {
            try await process.setBackgroundPriority(requested, pid: pid)
            backgroundPriorityPID = requested ? pid : nil
            setDaemonPriorityError(nil)
        } catch {
            let action = requested ? "lower" : "restore"
            setDaemonPriorityError("Could not \(action) the priority of the Mutagen daemon (PID \(pid)): \(error.localizedDescription)")
        }
    }

    private func setDaemonPriorityError(_ message: String?) {
        if daemonPriorityError != message { daemonPriorityError = message }
    }

    public func fetchVersion() async {
        do {
            mutagenVersion = try await provider.version()
        } catch {
            mutagenVersion = nil
        }
    }

    // MARK: - Conflict Resolution

    public func conflictDiff(
        session: SyncSession,
        conflict: Conflict
    ) async -> [DiffHunkResult]? {
        let alphaURL = appendingSubpath(to: session.alpha.endpointURL, subpath: conflict.root)
        let betaURL = appendingSubpath(to: session.beta.endpointURL, subpath: conflict.root)

        do {
            async let alphaContent = fileTransport.readFile(endpoint: alphaURL)
            async let betaContent = fileTransport.readFile(endpoint: betaURL)
            let (alpha, beta) = try await (alphaContent, betaContent)
            return DiffEngine.diffLines(old: alpha, new: beta)
        } catch {
            return nil
        }
    }

    public func conflictFileInfo(
        session: SyncSession,
        conflict: Conflict
    ) async -> (alpha: FileInfo?, beta: FileInfo?) {
        let alphaURL = appendingSubpath(to: session.alpha.endpointURL, subpath: conflict.root)
        let betaURL = appendingSubpath(to: session.beta.endpointURL, subpath: conflict.root)

        async let alphaStat = try? fileTransport.stat(endpoint: alphaURL)
        async let betaStat = try? fileTransport.stat(endpoint: betaURL)
        async let alphaIsLink = try? fileTransport.isSymlink(endpoint: alphaURL)
        async let betaIsLink = try? fileTransport.isSymlink(endpoint: betaURL)

        let (aStat, bStat, aIsLink, bIsLink) = await (alphaStat, betaStat, alphaIsLink, betaIsLink)

        let alphaTarget: String? = (aIsLink == true)
            ? (try? await fileTransport.readLink(endpoint: alphaURL)) : nil
        let betaTarget: String? = (bIsLink == true)
            ? (try? await fileTransport.readLink(endpoint: betaURL)) : nil

        let alphaInfo = aStat.map {
            FileInfo(size: $0.size, modifiedAt: $0.modifiedAt, isSymlink: aIsLink ?? false, symlinkTarget: alphaTarget)
        }
        let betaInfo = bStat.map {
            FileInfo(size: $0.size, modifiedAt: $0.modifiedAt, isSymlink: bIsLink ?? false, symlinkTarget: betaTarget)
        }

        return (alpha: alphaInfo, beta: betaInfo)
    }

    /// Makes the loser's side of a conflict match the winner's, with the session paused meanwhile.
    /// - Returns: the conflict's root when it was left unresolved, and nothing when it was resolved.
    @discardableResult
    public func resolveConflict(
        session: SyncSession,
        conflict: Conflict,
        winner: ConflictWinner
    ) async -> Set<String> {
        await resolveInTurn(on: session, roots: [conflict.root]) {
            await self.applyResolve(session: session, conflict: conflict, winner: winner)
        }
    }

    /// Resolves several conflicts of one session under a single pause.
    /// - Returns: the roots of the conflicts left unresolved.
    @discardableResult
    public func resolveConflicts(
        session: SyncSession,
        conflicts: [Conflict],
        winner: ConflictWinner
    ) async -> Set<String> {
        await resolveInTurn(on: session, roots: Set(conflicts.map(\.root))) {
            await self.applyResolve(session: session, conflicts: conflicts, winner: winner)
        }
    }

    /// Runs `resolve` once every resolve requested earlier on the same session has ended, so that no resolve
    /// resumes the session while another is moving its files. Requests run in the order they were made.
    /// A session that is held when its turn comes is refused before anything is paused or run.
    /// - Returns: the roots left unresolved: what `resolve` returns, or all of `roots` for a refusal.
    private func resolveInTurn(
        on session: SyncSession,
        roots: Set<String>,
        _ resolve: @escaping @MainActor () async -> Set<String>
    ) async -> Set<String> {
        let identifier = session.identifier
        let earlier = lastResolve[identifier]
        let turn = Task { @MainActor in
            _ = await earlier?.value
            if let hold = self.sessionHolds[identifier] {
                ConsoleLog.shared.log("resolve refused: \"\(session.name ?? identifier)\" is held paused", level: .error)
                self.lastError = hold
                return roots
            }
            return await resolve()
        }
        lastResolve[identifier] = turn
        let unresolved = await turn.value
        if lastResolve[identifier] == turn { lastResolve[identifier] = nil }
        return unresolved
    }

    private func applyResolve(
        session: SyncSession,
        conflict: Conflict,
        winner: ConflictWinner
    ) async -> Set<String> {
        let unresolved: Set<String> = [conflict.root]
        guard !conflict.root.isEmpty else {
            ConsoleLog.shared.log("resolveConflict: refused the conflict at the sync root", level: .error)
            lastError = rootConflictRefusal(in: session)
            return unresolved
        }

        ConsoleLog.shared.log("resolveConflict: \(winner) wins for root '\(conflict.root)'")

        // Pause the session to prevent mutagen from syncing while we modify files
        do {
            try await provider.syncPause(session.identifier)
            ConsoleLog.shared.log("  paused session")
        } catch {
            ConsoleLog.shared.log("  pause FAILED: \(error.localizedDescription)", level: .error)
            lastError = "Failed to pause session: \(error.localizedDescription)"
            return unresolved
        }

        let leftoverNotice: String?
        do {
            switch try await applyWinner(winner, to: conflict, in: session) {
            case .applied:
                ConsoleLog.shared.log("  transport succeeded")
                leftoverNotice = nil
            case .appliedLeavingOriginal(let notice):
                ConsoleLog.shared.log("  \(notice)", level: .error)
                addLeftoverNotice(notice, for: session.identifier)
                leftoverNotice = notice
            case .leftUnverified(let notice):
                ConsoleLog.shared.log("  \(notice)", level: .error)
                sessionHolds[session.identifier] = notice
                lastError = notice
                return unresolved
            case .winnerMissing(let winnerURL):
                ConsoleLog.shared.log("  winner file no longer exists at \(winnerURL.formatted)", level: .error)
                lastError = "The file \"\(conflict.root)\" no longer exists at the source. It may have been renamed or deleted. Try refreshing sessions."
                _ = try? await resumeUnlessHeld(session.identifier)
                return unresolved
            }
        } catch {
            ConsoleLog.shared.log("  transport FAILED: \(error.localizedDescription)", level: .error)
            lastError = error.localizedDescription
            _ = try? await resumeUnlessHeld(session.identifier)
            return unresolved
        }

        // Resume and flush to let mutagen re-scan with the resolved state.
        // Don't call refresh() here — syncList() right after flush catches mutagen mid-scan
        // with empty conflicts, causing UI flicker. The polling cycle brings authoritative data.
        do {
            if case .heldBack(let message) = try await resumeUnlessHeld(session.identifier) {
                lastError = message
                return unresolved
            }
            ConsoleLog.shared.log("  resumed session")
            try await provider.syncFlush(session.identifier)
            ConsoleLog.shared.log("  flush succeeded")
            lastError = leftoverNotice
        } catch {
            ConsoleLog.shared.log("  flush FAILED: \(error.localizedDescription)", level: .error)
            lastError = ([error.localizedDescription] + [leftoverNotice].compactMap { $0 }).joined(separator: " ")
        }
        return []
    }

    public func dismissLeftoverNotice(for identifier: String) {
        leftoverNotices[identifier] = nil
    }

    private func addLeftoverNotice(_ notice: String, for identifier: String) {
        leftoverNotices[identifier] = ([leftoverNotices[identifier], notice].compactMap { $0 }).joined(separator: " ")
    }

    private func applyResolve(
        session: SyncSession,
        conflicts: [Conflict],
        winner: ConflictWinner
    ) async -> Set<String> {
        var unresolved = Set(conflicts.map(\.root))
        guard !conflicts.isEmpty else { return unresolved }

        ConsoleLog.shared.log("resolveConflicts: \(winner) wins for \(conflicts.count) conflicts")

        let fileConflicts = conflicts.filter { !$0.root.isEmpty }
        let refusal = fileConflicts.count < conflicts.count ? rootConflictRefusal(in: session) : nil
        var failed = conflicts.count - fileConflicts.count
        if let refusal {
            ConsoleLog.shared.log("  refused the conflict at the sync root", level: .error)
            guard !fileConflicts.isEmpty else {
                lastError = "\(failed) of \(conflicts.count) conflicts could not be resolved. \(refusal)"
                return unresolved
            }
        }

        do {
            try await provider.syncPause(session.identifier)
            ConsoleLog.shared.log("  paused session")
        } catch {
            ConsoleLog.shared.log("  pause FAILED: \(error.localizedDescription)", level: .error)
            lastError = "Failed to pause session: \(error.localizedDescription)"
            return unresolved
        }

        var resolved = 0
        var notices: [String] = []
        for (position, conflict) in fileConflicts.enumerated() {
            do {
                switch try await applyWinner(winner, to: conflict, in: session) {
                case .applied:
                    resolved += 1
                    unresolved.remove(conflict.root)
                case .appliedLeavingOriginal(let notice):
                    ConsoleLog.shared.log("  \(notice)", level: .error)
                    resolved += 1
                    unresolved.remove(conflict.root)
                    addLeftoverNotice(notice, for: session.identifier)
                    notices.append(notice)
                case .leftUnverified(let notice):
                    ConsoleLog.shared.log("  \(notice)", level: .error)
                    let notAttempted = fileConflicts.count - position - 1
                    if notAttempted > 0 {
                        notices.append("\(notAttempted) of \(conflicts.count) conflicts \(notAttempted == 1 ? "was" : "were") not attempted.")
                    }
                    if let refusal { notices.append(refusal) }
                    let message = ([notice] + notices).joined(separator: " ")
                    sessionHolds[session.identifier] = message
                    lastError = message
                    return unresolved
                case .winnerMissing:
                    ConsoleLog.shared.log("  skipped '\(conflict.root)': winner file no longer exists", level: .error)
                    failed += 1
                }
            } catch {
                ConsoleLog.shared.log("  failed '\(conflict.root)': \(error.localizedDescription)", level: .error)
                failed += 1
            }
        }

        ConsoleLog.shared.log("  resolved \(resolved)/\(conflicts.count) conflicts (\(failed) failed)")

        do {
            if case .heldBack(let message) = try await resumeUnlessHeld(session.identifier) {
                lastError = message
                return unresolved
            }
            try await provider.syncFlush(session.identifier)
            if failed > 0 {
                notices.insert("\(failed) of \(conflicts.count) conflicts could not be resolved.", at: 0)
                if let refusal { notices.insert(refusal, at: 1) }
            }
            lastError = notices.isEmpty ? nil : notices.joined(separator: " ")
        } catch {
            ConsoleLog.shared.log("  flush FAILED: \(error.localizedDescription)", level: .error)
            lastError = ([error.localizedDescription] + notices).joined(separator: " ")
        }
        return unresolved
    }

    /// What applying a winner did to the files of one conflict.
    private enum ConflictFileOutcome {
        case applied
        /// The loser's side matches the winner's; `notice` names the displaced original still on disk for the user to delete.
        case appliedLeavingOriginal(notice: String)
        /// The loser's side could not be shown to hold either its original or the winner's copy, so the session
        /// must stay paused; `notice` names the paths that hold the data.
        case leftUnverified(notice: String)
        /// The winner's file is gone, so neither side was touched.
        case winnerMissing(EndpointURL)
    }

    /// Makes the loser's side of one conflict match the winner's: removes it when the winner deleted the
    /// conflict root, and otherwise replaces it with a copy of the winner. Throws the transport's error
    /// when the session is safe to resume; a replacement that is not comes back as `leftUnverified`.
    private func applyWinner(_ winner: ConflictWinner, to conflict: Conflict, in session: SyncSession) async throws -> ConflictFileOutcome {
        let alphaURL = appendingSubpath(to: session.alpha.endpointURL, subpath: conflict.root)
        let betaURL = appendingSubpath(to: session.beta.endpointURL, subpath: conflict.root)

        let (winnerURL, loserURL) = switch winner {
        case .alpha: (alphaURL, betaURL)
        case .beta: (betaURL, alphaURL)
        }

        let winnerChanges = winner == .alpha ? conflict.alphaChanges : conflict.betaChanges
        ConsoleLog.shared.log("  winnerURL: \(winnerURL.formatted)")
        ConsoleLog.shared.log("  loserURL: \(loserURL.formatted)")
        ConsoleLog.shared.log("  winnerChanges: \(winnerChanges.map { "path='\($0.path)' old=\($0.old?.kind ?? "nil") new=\($0.new?.kind ?? "nil")" }.joined(separator: ", "))")

        let winnerDeletedRoot = winnerChanges.contains { $0.path == conflict.root && $0.new == nil }
        ConsoleLog.shared.log("  winnerDeletedRoot: \(winnerDeletedRoot)")

        if winnerDeletedRoot {
            ConsoleLog.shared.log("  action: REMOVE \(loserURL.formatted)")
            try await fileTransport.remove(endpoint: loserURL)
            return .applied
        }
        guard try await fileTransport.pathExists(endpoint: winnerURL) else {
            return .winnerMissing(winnerURL)
        }
        ConsoleLog.shared.log("  action: REPLACE \(loserURL.formatted) with a copy of \(winnerURL.formatted)")
        do {
            switch try await fileTransport.replace(loserURL, withCopyOf: winnerURL) {
            case .replaced:
                return .applied
            case .replacedLeavingOriginal(let path, let reason):
                return .appliedLeavingOriginal(
                    notice: "Resolved \"\(conflict.root)\", but left the original it replaced at \(path): \(reason). Delete that path by hand."
                )
            }
        } catch let error as ReplaceError {
            switch error.aftermath {
            case .destinationUnchanged:
                throw error
            case .destinationUnverified:
                return .leftUnverified(
                    notice: "\(error.localizedDescription). The session \"\(session.name ?? session.identifier)\" was left paused so that sync cannot overwrite or delete those paths. Put \"\(conflict.root)\" in order, then resume the session."
                )
            }
        }
    }

    /// Why a conflict at the sync root is left alone: its loser path is the endpoint itself.
    private func rootConflictRefusal(in session: SyncSession) -> String {
        "The conflict in \"\(session.name ?? session.identifier)\" is at the sync root, where resolving it would replace a whole endpoint. Resolve a root-level conflict by hand."
    }

    // MARK: - Git Repo Detection

    public func gitRepoStatus(for session: SyncSession) async -> GitRepoCheck {
        // A session that should be connected and is not has an unreachable endpoint; probing it
        // only opens connections that fail. A paused session is disconnected by design and is still probed.
        guard session.paused || (session.alpha.connected != false && session.beta.connected != false) else {
            return GitRepoCheck(status: .unknown)
        }
        let alphaGit = appendingSubpath(to: session.alpha.endpointURL, subpath: ".git")
        let betaGit = appendingSubpath(to: session.beta.endpointURL, subpath: ".git")

        async let alphaResult = try? fileTransport.directoryExists(endpoint: alphaGit)
        async let betaResult = try? fileTransport.directoryExists(endpoint: betaGit)

        guard let alphaHas = await alphaResult, let betaHas = await betaResult else {
            return GitRepoCheck(status: .unknown)
        }

        switch (alphaHas, betaHas) {
        case (true, true): return GitRepoCheck(status: .symmetric)
        case (true, false):
            let remote = await checkHasRemote(endpoint: session.alpha.endpointURL)
            return GitRepoCheck(status: .alphaOnly, hasRemote: remote)
        case (false, true):
            let remote = await checkHasRemote(endpoint: session.beta.endpointURL)
            return GitRepoCheck(status: .betaOnly, hasRemote: remote)
        case (false, false): return await scanSubdirectoriesForGit(session: session)
        }
    }

    private func scanSubdirectoriesForGit(session: SyncSession) async -> GitRepoCheck {
        async let alphaOutput = try? fileTransport.run(
            on: session.alpha.endpointURL,
            command: "find . -maxdepth 2 -name .git -type d 2>/dev/null"
        )
        async let betaOutput = try? fileTransport.run(
            on: session.beta.endpointURL,
            command: "find . -maxdepth 2 -name .git -type d 2>/dev/null"
        )

        let alphaPaths = parseGitDirs(await alphaOutput ?? "")
        let betaPaths = parseGitDirs(await betaOutput ?? "")

        let alphaOnly = alphaPaths.subtracting(betaPaths).sorted()
        let betaOnly = betaPaths.subtracting(alphaPaths).sorted()

        if let first = alphaOnly.first {
            let remote = await checkHasRemote(endpoint: session.alpha.endpointURL, subpath: first)
            return GitRepoCheck(status: .alphaOnly, subpath: first, hasRemote: remote)
        }
        if let first = betaOnly.first {
            let remote = await checkHasRemote(endpoint: session.beta.endpointURL, subpath: first)
            return GitRepoCheck(status: .betaOnly, subpath: first, hasRemote: remote)
        }
        return GitRepoCheck(status: .symmetric)
    }

    private func parseGitDirs(_ output: String) -> Set<String> {
        var result = Set<String>()
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("/.git") else { continue }
            let parent = String(trimmed.dropLast(5))
            if parent == "." {
                result.insert("")
            } else if parent.hasPrefix("./") {
                result.insert(String(parent.dropFirst(2)))
            } else {
                result.insert(parent)
            }
        }
        return result
    }

    private func checkHasRemote(endpoint: EndpointURL, subpath: String = "") async -> Bool {
        let target = subpath.isEmpty ? endpoint : appendingSubpath(to: endpoint, subpath: subpath)
        let url = try? await fileTransport.run(
            on: target,
            command: "git config --get remote.origin.url"
        )
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    // MARK: - Git Auto-Fix

    public func gitSourceInfo(
        for session: SyncSession,
        gitCheck: GitRepoCheck
    ) async -> (remoteURL: String?, branch: String?) {
        guard gitCheck.status == .alphaOnly || gitCheck.status == .betaOnly else { return (nil, nil) }

        let sourceBase = gitCheck.status == .alphaOnly
            ? session.alpha.endpointURL
            : session.beta.endpointURL
        let sourceEndpoint = gitCheck.subpath.isEmpty
            ? sourceBase
            : appendingSubpath(to: sourceBase, subpath: gitCheck.subpath)

        let remoteURL = (try? await fileTransport.run(
            on: sourceEndpoint, command: "git config --get remote.origin.url"
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = (try? await fileTransport.run(
            on: sourceEndpoint, command: "git branch --show-current"
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            remoteURL: remoteURL?.isEmpty == true ? nil : remoteURL,
            branch: branch?.isEmpty == true ? nil : branch
        )
    }

    public func fixGitMismatch(session: SyncSession, gitCheck: GitRepoCheck) async -> Bool {
        guard gitCheck.status == .alphaOnly || gitCheck.status == .betaOnly else { return false }

        let sourceBase = gitCheck.status == .alphaOnly
            ? session.alpha.endpointURL
            : session.beta.endpointURL
        let targetBase = gitCheck.status == .alphaOnly
            ? session.beta.endpointURL
            : session.alpha.endpointURL
        let sourceEndpoint = gitCheck.subpath.isEmpty ? sourceBase : appendingSubpath(to: sourceBase, subpath: gitCheck.subpath)
        let targetEndpoint = gitCheck.subpath.isEmpty ? targetBase : appendingSubpath(to: targetBase, subpath: gitCheck.subpath)

        let remoteURL: String
        let branch: String
        do {
            remoteURL = try await fileTransport.run(on: sourceEndpoint, command: "git config --get remote.origin.url").trimmingCharacters(in: .whitespacesAndNewlines)
            branch = try await fileTransport.run(on: sourceEndpoint, command: "git branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            lastError = "Could not read git info: \(error.localizedDescription)"
            return false
        }

        guard !remoteURL.isEmpty, !branch.isEmpty else {
            lastError = "No git remote or branch found on the source endpoint"
            return false
        }

        do {
            _ = try await fileTransport.run(on: targetEndpoint, command: "git init")
            _ = try await fileTransport.run(on: targetEndpoint, command: "git remote add origin '\(remoteURL)'")
            _ = try await fileTransport.run(on: targetEndpoint, command: "git fetch origin")
            _ = try await fileTransport.run(on: targetEndpoint, command: "git reset --mixed 'origin/\(branch)'")
            lastError = nil
            return true
        } catch {
            lastError = "Git init failed: \(error.localizedDescription)"
            return false
        }
    }

    private func appendingSubpath(to endpoint: EndpointURL, subpath: String) -> EndpointURL {
        switch endpoint {
        case .local(let path):
            return .local(path: (path as NSString).appendingPathComponent(subpath))
        case .ssh(let user, let host, let port, let path):
            return .ssh(user: user, host: host, port: port, path: (path as NSString).appendingPathComponent(subpath))
        case .docker(let container, let path):
            return .docker(container: container, path: (path as NSString).appendingPathComponent(subpath))
        }
    }

    // MARK: - Polling

    public func startPolling(interval: TimeInterval = 5.0) {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Private

    /// Hashes fields that affect the UI (identity, status, conflicts, connectivity,
    /// staging progress, last error). Excludes volatile counters like successfulCycles and endpoint
    /// scan statistics that change every mutagen scan cycle.
    private func syncDigest(_ sessions: [SyncSession]) -> Int {
        var hasher = Hasher()
        for s in sessions {
            hasher.combine(s.identifier)
            hasher.combine(s.name)
            hasher.combine(s.status)
            hasher.combine(s.paused)
            hasher.combine(s.mode)
            hasher.combine(s.conflicts ?? [])
            hasher.combine(s.alpha.connected)
            hasher.combine(s.beta.connected)
            hasher.combine(s.alpha.stagingProgress)
            hasher.combine(s.beta.stagingProgress)
            hasher.combine(s.lastError)
        }
        return hasher.finalize()
    }

    private func forwardDigest(_ sessions: [ForwardSession]) -> Int {
        var hasher = Hasher()
        for s in sessions {
            hasher.combine(s.identifier)
            hasher.combine(s.name)
            hasher.combine(s.paused)
            hasher.combine(s.source.connected)
            hasher.combine(s.destination.connected)
        }
        return hasher.finalize()
    }

    private func performAction(_ action: @Sendable () async throws -> Void) async {
        do {
            try await action()
            lastError = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
