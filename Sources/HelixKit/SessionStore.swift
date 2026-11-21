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

public enum DaemonStatus: String, Sendable {
    case running = "Running"
    case stopped = "Stopped"
    case startedOutside = "Mutagen was started outside Helix"
    case unknown = "Status unknown"
}

@MainActor
@Observable
public final class SessionStore {
    private typealias SessionLists = (sync: [SyncSession], forward: [ForwardSession])

    public private(set) var syncSessions: [SyncSession] = []
    public private(set) var forwardSessions: [ForwardSession] = []
    public private(set) var daemonStatus = DaemonStatus.stopped
    public var daemonRunning: Bool { daemonStatus == .running }
    public private(set) var daemonStopProgress: String?
    public private(set) var daemonAutoStart = false
    public private(set) var mutagenVersion: String?
    public private(set) var lastError: String?
    public private(set) var interruptedEditNotice: String?
    public private(set) var refreshCount = 0
    public var pendingSessionSelection: String?
    public private(set) var bulkPause: BulkPause? {
        didSet { persistBulkPause() }
    }
    /// Why a sync session is kept paused, by session identifier: a conflict replacement left a path that
    /// could not be shown to hold either version,
    /// or Helix quit while a replacement was under way, and the message names where the data is. While a session
    /// has an entry the store never resumes it on its own; only `resumeSync` on that session does.
    public private(set) var sessionHolds: [String: String] = [:] {
        didSet { persist(sessionHolds, forKey: Self.sessionHoldsKey) }
    }
    /// The replacement each session's conflict resolve is making right now, by session identifier, as the hold
    /// message for the case that Helix quits before the replacement ends. An entry is saved before the first
    /// command of its replacement and removed once the outcome is known; one found at launch becomes a hold.
    @ObservationIgnored private var replacementsUnderWay: [String: String] = [:] {
        didSet { persist(replacementsUnderWay, forKey: Self.replacementsUnderWayKey) }
    }
    /// Set-aside originals that resolved conflicts left on disk for the user to delete, by session identifier.
    /// A notice does not stop its session from syncing; it stays until dismissed or until the session is gone.
    public private(set) var leftoverNotices: [String: String] = [:] {
        didSet { persist(leftoverNotices, forKey: Self.leftoverNoticesKey) }
    }
    /// Original sync sessions that survived an edit, mapped to their replacement identifiers.
    public private(set) var leftoverSyncOriginals: [String: String] = [:] {
        didSet { persist(leftoverSyncOriginals, forKey: Self.leftoverSyncOriginalsKey) }
    }
    /// Whether background priority is confirmed for the running daemon.
    public var daemonBackgroundPriority: Bool {
        backgroundPriorityPID != nil && daemonPriorityError == nil
    }
    public private(set) var daemonBackgroundPriorityRequested: Bool
    public private(set) var daemonPriorityError: String?

    private let provider: ManagedSessionProvider
    private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var pollingInterval: TimeInterval?
    @ObservationIgnored private var stoppedDaemonCheckInFlight = false
    private var daemonControl: ManagedSessionProvider.Control {
        get { provider.control }
        set { provider.control = newValue }
    }
    @ObservationIgnored private var activeSessionLists: [UUID: Task<SessionLists, Error>] = [:]
    private let fileTransport: FileTransport
    private let defaults: UserDefaults
    private let now: () -> Date
    private var daemonProcess: any DaemonProcess
    @ObservationIgnored private var bulkPauseInFlight = false
    /// The session `recreateSync` is replacing right now. No resolve or resume is started on it meanwhile.
    @ObservationIgnored private var sessionBeingEdited: String?
    @ObservationIgnored private var replacementBeingEdited: String?
    @ObservationIgnored private var hasUnreviewedSyncEdit = false
    @ObservationIgnored private var interruptedEditPairs: [String: String] = [:] {
        didSet { persist(interruptedEditPairs, forKey: Self.interruptedEditPairsKey) }
    }
    /// The end of the resolve or resume requested last on each session; the next one on that session waits for it.
    @ObservationIgnored private var lastTurn: [String: Task<Void, Never>] = [:]
    /// How many conflict resolves are running or waiting their turn, by session identifier.
    private var resolvesInFlight: [String: Int] = [:]
    /// The daemon process whose background priority Helix last set successfully.
    private var backgroundPriorityPID: ProcessID?
    @ObservationIgnored private var daemonPriorityInFlight = false
    private static let syncEditInProgressKey = "syncEditInProgress"
    private static let interruptedSyncEditNoticeKey = "interruptedSyncEditNotice"
    private static let interruptedEditPairsKey = "interruptedSyncEditPairs"
    private static let bulkPauseKey = "bulkPause"
    private static let sessionHoldsKey = "sessionHolds"
    private static let replacementsUnderWayKey = "replacementsUnderWay"
    private static let leftoverNoticesKey = "leftoverNotices"
    private static let leftoverSyncOriginalsKey = "leftoverSyncOriginals"
    private static let daemonBackgroundPriorityKey = "daemonBackgroundPriority"
    private static let daemonStoppedKey = "daemonStoppedByHelix"

    public init(
        provider: any SessionProvider,
        fileTransport: FileTransport = FileTransport(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        daemonProcess: any DaemonProcess = MutagenDaemon(cliPath: CLI.defaultExecutablePath)
    ) {
        self.provider = ManagedSessionProvider(provider)
        if defaults.bool(forKey: Self.daemonStoppedKey) {
            self.provider.control = .stopped
        }
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
        leftoverSyncOriginals = savedMessages(forKey: Self.leftoverSyncOriginalsKey, called: "original sessions left after an edit")
        interruptedEditPairs = savedMessages(forKey: Self.interruptedEditPairsKey, called: "interrupted sync edits")
        holdSessionsWhoseReplacementWasCutShort()
        restoreInterruptedEditNotice()
    }

    private func restoreInterruptedEditNotice() {
        interruptedEditNotice = defaults.string(forKey: Self.interruptedSyncEditNoticeKey)
        guard defaults.object(forKey: Self.syncEditInProgressKey) != nil else { return }
        let edit = defaults.dictionary(forKey: Self.syncEditInProgressKey)
        let notice: String
        if let original = edit?["original"] as? String, let name = edit?["name"] as? String {
            if let replacement = edit?["replacement"] as? String, replacement != original {
                interruptedEditPairs[original] = replacement
            }
            let replacementName = edit?["replacementName"] as? String ?? name
            let candidate = replacementName.isEmpty
                ? "an unnamed paused edited session"
                : "a paused edited session named \"\(replacementName)\""
            let replacement = (edit?["replacement"] as? String).map { "Edited session: \($0)." }
                ?? "Look for \(candidate)."
            notice = "Helix quit while editing \"\(name)\". Original session: \(original). \(replacement) Inspect both sessions before resuming either one. Keep only the session you want to sync."
        } else {
            notice = "Helix quit during a sync edit and could not read the saved session details. Inspect the session list before resuming any edited session."
        }
        interruptedEditNotice = notice
        defaults.set(notice, forKey: Self.interruptedSyncEditNoticeKey)
        defaults.removeObject(forKey: Self.syncEditInProgressKey)
    }

    public func dismissInterruptedEditNotice() {
        interruptedEditNotice = nil
        defaults.removeObject(forKey: Self.interruptedSyncEditNoticeKey)
    }

    /// Turns each replacement that the last launch saved and never settled into a hold, unless its session
    /// already has one. The hold is saved before the record goes, so quitting in between loses neither.
    private func holdSessionsWhoseReplacementWasCutShort() {
        guard defaults.object(forKey: Self.replacementsUnderWayKey) != nil else { return }
        let cutShort = savedMessages(forKey: Self.replacementsUnderWayKey, called: "replacements Helix was making when it quit")
        // Every message is logged, also that of a session that keeps an older hold: the log is then the only record of its paths.
        for message in cutShort.values.sorted() {
            ConsoleLog.shared.log(message, level: .error)
        }
        let holds = sessionHolds.merging(cutShort) { held, _ in held }
        sessionHolds = holds
        persist(holds, forKey: Self.sessionHoldsKey)
        defaults.removeObject(forKey: Self.replacementsUnderWayKey)
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
        self.provider.replace(with: provider)
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
            .filter { !isPartOfSyncEdit($0.identifier, editing: identifier) }
            .compactMap(\.name)
    }

    private func isPartOfSyncEdit(_ identifier: String, editing edited: String?) -> Bool {
        guard let edited else { return false }
        return identifier == edited || leftoverSyncOriginals[identifier] == edited
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
        let hasConflicts = running.contains { $0.conflicts?.isEmpty == false || ($0.excludedConflicts ?? 0) > 0 }
        let hasProblems = running.contains { $0.alpha.hasProblems || $0.beta.hasProblems }
        let hasHalted = running.contains { $0.phase == .halted }
        let failsToConnect = running.contains { $0.phase == .connecting && !($0.lastError ?? "").isEmpty }
        if hasConflicts || hasProblems || hasHalted || failsToConnect {
            return .warning
        }
        let hasActive = running.contains { $0.phase == .working || $0.phase == .connecting }
        if hasActive {
            return .active
        }
        return .healthy
    }

    public func refresh() async {
        if daemonControl == .stopped {
            await checkStoppedDaemonStatus()
            return
        }
        if await reloadSessions(), let resumeAt = bulkPause?.resumeAt, now() >= resumeAt {
            await resumeBulkPause()
        }
        guard daemonControl == .managed else { return }
        await reapplyDaemonBackgroundPriority()
    }

    /// Fetches the session lists while Helix is managing the daemon. Returns false when they were not fetched:
    /// Helix has stopped the daemon, the daemon could not be reached, or the task was cancelled.
    @discardableResult
    private func reloadSessions(force: Bool = false) async -> Bool {
        guard daemonControl == .managed else { return false }

        let existingEditPairs = leftoverSyncOriginals
        let id = UUID()
        let request = Task<SessionLists, Error> { [provider] in
            async let syncs = provider.syncList()
            async let forwards = provider.forwardList()
            return try await (syncs, forwards)
        }
        activeSessionLists[id] = request
        defer { activeSessionLists.removeValue(forKey: id) }

        do {
            let lists = try await request.value
            guard activeSessionLists[id] != nil else { return false }
            if force || syncDigest(lists.sync) != syncDigest(syncSessions) { syncSessions = lists.sync }
            if force || forwardDigest(lists.forward) != forwardDigest(forwardSessions) { forwardSessions = lists.forward }
            forgetSessions(notListedIn: lists.sync)
            recoverInterruptedEditPairs(listed: lists.sync)
            forgetMissingEditPairs(existingEditPairs, listed: lists.sync)
            if !daemonRunning { daemonStatus = .running }
            if lastError != nil { lastError = nil }
            return true
        } catch is CancellationError {
            // A cancelled fetch says nothing about the daemon.
            return false
        } catch {
            guard activeSessionLists[id] != nil else { return false }
            if !daemonRunning || lastError != error.localizedDescription {
                daemonStatus = .stopped
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

    private func forgetMissingEditPairs(_ existingPairs: [String: String], listed: [SyncSession]) {
        guard !existingPairs.isEmpty else { return }
        let identifiers = Set(listed.map(\.identifier))
        for (original, replacement) in existingPairs where leftoverSyncOriginals[original] == replacement {
            if !identifiers.contains(original) || !identifiers.contains(replacement) {
                leftoverSyncOriginals[original] = nil
            }
        }
    }

    private func recoverInterruptedEditPairs(listed: [SyncSession]) {
        guard !interruptedEditPairs.isEmpty else { return }
        let identifiers = Set(listed.map(\.identifier))
        for (original, replacement) in interruptedEditPairs where identifiers.contains(replacement) {
            retargetLeftoverOriginals(from: original, to: replacement)
            if identifiers.contains(original) {
                leftoverSyncOriginals[original] = replacement
            }
        }
        interruptedEditPairs.removeAll()
    }

    private func retargetLeftoverOriginals(from original: String, to replacement: String) {
        let retargeted = leftoverSyncOriginals.mapValues { $0 == original ? replacement : $0 }
        if retargeted != leftoverSyncOriginals { leftoverSyncOriginals = retargeted }
    }

    public func manualRefresh() async {
        if daemonControl == .stopped {
            await checkStoppedDaemonStatus()
        } else {
            await reloadSessions(force: true)
        }
        refreshCount += 1
    }

    private func checkStoppedDaemonStatus() async {
        guard !stoppedDaemonCheckInFlight else { return }
        stoppedDaemonCheckInFlight = true
        defer { stoppedDaemonCheckInFlight = false }
        do {
            let running = try await daemonProcess.pid() != nil
            guard daemonControl == .stopped else { return }
            daemonStatus = running ? .startedOutside : .stopped
        } catch is CancellationError {
            return
        } catch {
            guard daemonControl == .stopped else { return }
            ConsoleLog.shared.log("Could not check the Mutagen process: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Session Creation

    @discardableResult
    public func createSync(options: SyncCreateOptions, alpha: String, beta: String) async -> String? {
        let args = options.arguments(alpha: alpha, beta: beta)
        do {
            _ = try await provider.syncCreate(arguments: args)
            lastError = nil
            await refresh()
        } catch {
            lastError = syncCreateFailure(error, name: options.name)
        }
        return lastError
    }

    private func syncCreateFailure(_ error: Error, name: String?, originalKept: Bool = false) -> String {
        if let unavailable = error as? SessionCommandsUnavailable {
            return unavailable.localizedDescription
        }
        let session = name.map { "Sync session \"\($0)\"" } ?? "An unnamed sync session"
        let original = originalKept ? " The original session was kept." : ""
        return "\(session) may have been created. Check the session list before retrying.\(original) Mutagen reported: \(error.localizedDescription)"
    }

    @discardableResult
    public func createForward(options: ForwardCreateOptions, source: String, destination: String) async -> String? {
        let args = options.arguments(source: source, destination: destination)
        return await performAction { try await provider.forwardCreate(arguments: args) }
    }

    // MARK: - Sync Edit

    @discardableResult
    public func recreateSync(
        _ session: SyncSession,
        options: SyncCreateOptions,
        alpha: String,
        beta: String
    ) async -> String? {
        if let unavailable = provider.unavailable {
            lastError = unavailable.localizedDescription
            return lastError
        }
        // Recreation mints a new identifier, which a running resolve and a hold both refer to by the old one.
        let sessionName = session.name ?? session.identifier
        if isResolving(session.identifier) {
            let message = "The session \"\(sessionName)\" was not recreated: a conflict resolve is running on it."
            lastError = message
            return message
        }
        if let hold = sessionHolds[session.identifier] {
            let message = "The session \"\(sessionName)\" was not recreated: it is kept paused after a conflict. Resume it first. \(hold)"
            lastError = message
            return message
        }
        guard sessionBeingEdited == nil else { return "Another sync edit is already in progress." }
        guard !hasUnreviewedSyncEdit else {
            return "Reopen Helix to review the interrupted sync edit before starting another edit."
        }
        guard !bulkPauseInFlight else { return "Wait for Pause All or Resume to finish before editing a session." }
        // Mutagen parses numeric byte sizes as floating point before converting to an integer.
        if let size = options.maxStagingFileSize, let bytes = UInt64(size),
           UInt64(exactly: Double(bytes)) != bytes {
            let message = "Mutagen cannot recreate the staging file limit of \(bytes) bytes exactly. The original session was kept."
            lastError = message
            return message
        }
        sessionBeingEdited = session.identifier
        defer {
            sessionBeingEdited = nil
            replacementBeingEdited = nil
        }

        let provider = self.provider
        let existingEditPairs = leftoverSyncOriginals
        let listed: [SyncSession]
        do {
            listed = try await provider.syncList()
        } catch {
            return await finishSyncEdit("Could not check the original session: \(error.localizedDescription).")
        }

        recoverInterruptedEditPairs(listed: listed)
        let original = session.identifier
        guard let current = listed.first(where: { $0.identifier == original }) else {
            return await finishSyncEdit("The original session \(original) is no longer listed by Mutagen.")
        }
        forgetMissingEditPairs(existingEditPairs, listed: listed)
        if let replacement = leftoverSyncOriginals[original] {
            let message = "Original session \(original) cannot be edited while its edited replacement \(replacement) is listed. Use Remove original instead."
            return await finishSyncEdit(message)
        }
        if let name = options.name, listed.contains(where: { $0.name == name && !isPartOfSyncEdit($0.identifier, editing: original) }) {
            return await finishSyncEdit("Another sync session already uses the name \"\(name)\". The original session was kept.")
        }

        var staged = options
        staged.preserveEndpointOverrides(from: current)
        let unsupported = staged.unsupportedEndpointOverrides
        if !unsupported.isEmpty {
            let settings = unsupported.joined(separator: ", ")
            return await finishSyncEdit("Mutagen cannot recreate these endpoint settings: \(settings). The original session was kept.")
        }
        staged.paused = true
        var edit = ["original": original, "name": sessionName]
        if staged.name != sessionName { edit["replacementName"] = staged.name ?? "" }
        defaults.set(edit, forKey: Self.syncEditInProgressKey)
        var keepEditRecord = false
        defer {
            if !keepEditRecord { defaults.removeObject(forKey: Self.syncEditInProgressKey) }
        }

        let replacement: String
        do {
            replacement = try await provider.syncCreate(arguments: staged.arguments(alpha: alpha, beta: beta))
        } catch {
            let message = syncCreateFailure(error, name: options.name, originalKept: true)
            keepEditRecord = error.isCommandInterruption
            if keepEditRecord { return reportInterruptedEdit(message) }
            return await finishSyncEdit(message)
        }
        guard !listed.contains(where: { $0.identifier == replacement }) else {
            return await finishSyncEdit("Mutagen returned existing session identifier \(replacement). The original session was kept.")
        }
        replacementBeingEdited = replacement
        updateBulkPause(replacing: original, with: replacement)
        edit["replacement"] = replacement
        defaults.set(edit, forKey: Self.syncEditInProgressKey)

        if !current.paused {
            do {
                try await provider.syncPause(original)
            } catch {
                let message = "Could not pause the original session: \(error.localizedDescription)."
                if error.isCommandInterruption {
                    keepEditRecord = true
                    return reportInterruptedEdit(message, original: original, replacement: replacement)
                }
                let recovery = await recoverSyncEdit(original: original, replacement: replacement, activationAttempted: false, provider: provider)
                keepEditRecord = !recovery.observedEnd
                if keepEditRecord { return reportInterruptedEdit("\(message) \(recovery.message)", original: original, replacement: replacement) }
                return await finishSyncEdit("\(message) \(recovery.message)")
            }
            do {
                try await provider.syncResume(replacement)
            } catch {
                let message = "Could not start the edited session: \(error.localizedDescription)."
                if error.isCommandInterruption {
                    keepEditRecord = true
                    return reportInterruptedEdit(message, original: original, replacement: replacement)
                }
                let recovery = await recoverSyncEdit(original: original, replacement: replacement, activationAttempted: true, provider: provider)
                keepEditRecord = !recovery.observedEnd
                if keepEditRecord { return reportInterruptedEdit("\(message) \(recovery.message)", original: original, replacement: replacement) }
                return await finishSyncEdit("\(message) \(recovery.message)")
            }
        }

        retargetLeftoverOriginals(from: original, to: replacement)
        do {
            try await provider.syncTerminate(original)
        } catch {
            if error.isCommandInterruption {
                keepEditRecord = true
                return reportInterruptedEdit(
                    "Could not confirm removal of the original session \(original): \(error.localizedDescription).",
                    original: original, replacement: replacement
                )
            }
            leftoverSyncOriginals[original] = replacement
            return await finishSyncEdit(
                "The edited session \(replacement) is ready. Could not remove original session \(original): \(error.localizedDescription).",
                replacement: replacement
            )
        }
        return await finishSyncEdit(nil, replacement: replacement)
    }

    private func reportInterruptedEdit(_ message: String, original: String? = nil, replacement: String? = nil) -> String {
        hasUnreviewedSyncEdit = true
        if let original, let replacement {
            interruptedEditPairs[original] = replacement
        }
        let notice = "\(message) Reopen Helix to review the interrupted edit."
        lastError = notice
        return notice
    }

    private func recoverSyncEdit(
        original: String,
        replacement: String,
        activationAttempted: Bool,
        provider: any SessionProvider
    ) async -> (message: String, observedEnd: Bool) {
        var messages: [String] = []
        do {
            try await provider.syncTerminate(replacement)
        } catch {
            messages.append("Could not remove edited session \(replacement): \(error.localizedDescription).")
            if error.isCommandInterruption { return (messages.joined(separator: " "), false) }
            if activationAttempted {
                // Mutagen may start reconnecting even when Resume returns an error.
                do {
                    try await provider.syncPause(replacement)
                } catch {
                    messages.append("Could not confirm that \(replacement) stopped: \(error.localizedDescription). Check both sessions before resuming original session \(original).")
                    return (messages.joined(separator: " "), false)
                }
            }
        }

        updateBulkPause(replacing: replacement, with: original)
        do {
            switch try await resumeUnlessHeld(original) {
            case .resumed:
                messages.append("The original session was restored.")
            case .heldBack(let hold):
                messages.append("Original session \(original) was kept and stays paused. \(hold)")
            }
        } catch {
            messages.append("Original session \(original) was kept. Could not resume it: \(error.localizedDescription).")
            return (messages.joined(separator: " "), false)
        }
        return (messages.joined(separator: " "), true)
    }

    private func finishSyncEdit(_ message: String?, replacement: String? = nil) async -> String? {
        if await reloadSessions(), let replacement, syncSessions.contains(where: { $0.identifier == replacement }) {
            pendingSessionSelection = replacement
        }
        if let message { lastError = message }
        return lastError
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
        if let unavailable = provider.unavailable {
            lastError = unavailable.localizedDescription
            return
        }
        guard sessionBeingEdited == nil else {
            lastError = "Wait for the edit to finish before using Pause All."
            return
        }
        guard !bulkPauseInFlight else { return }
        bulkPauseInFlight = true
        defer { bulkPauseInFlight = false }
        guard await reloadSessions() else { return }

        if let record = bulkPause, record.resumeAt != resumeAt {
            bulkPause = BulkPause(sessionIdentifiers: record.sessionIdentifiers, resumeAt: resumeAt)
        }

        var failures: [String] = []
        for session in syncSessions where !session.paused {
            let identifier = session.identifier
            do {
                try await provider.syncPause(identifier)
                let paused = bulkPause?.sessionIdentifiers ?? []
                if !paused.contains(identifier) {
                    bulkPause = BulkPause(sessionIdentifiers: paused + [identifier], resumeAt: resumeAt)
                }
            } catch {
                failures.append("Could not pause \(session.name ?? session.identifier): \(error.localizedDescription)")
            }
        }
        await finishBulkAction(failures: failures)
    }

    /// Resumes the sessions Pause All paused that are still paused, except held ones. A session that fails
    /// to resume, that a conflict resolve is working on, or that is being edited stays in the record so the
    /// next attempt retries it.
    public func resumeBulkPause() async {
        if let unavailable = provider.unavailable {
            lastError = unavailable.localizedDescription
            return
        }
        guard let record = bulkPause, !bulkPauseInFlight else { return }
        bulkPauseInFlight = true
        defer { bulkPauseInFlight = false }
        guard await reloadSessions() else { return }

        let listed = Dictionary(uniqueKeysWithValues: syncSessions.map { ($0.identifier, $0) })
        var failures: [String] = []
        for identifier in record.sessionIdentifiers {
            guard bulkPause?.sessionIdentifiers.contains(identifier) == true else { continue }
            // Leave sessions owned by an edit or a conflict resolve for the next bulk resume.
            if isResolving(identifier) || sessionBeingEdited == identifier || replacementBeingEdited == identifier {
                continue
            }
            guard let session = listed[identifier], session.paused else {
                updateBulkPause(replacing: identifier)
                continue
            }
            // The resume takes a turn, so a resolve requested while it is in flight pauses after it.
            let failure: String? = await inTurn(on: identifier) {
                if self.leftoverSyncOriginals[identifier] != nil { return nil }
                do {
                    // A held session leaves the record without being resumed: its hold keeps it paused from here on.
                    switch try await self.resumeUnlessHeld(identifier) {
                    case .resumed, .heldBack: return nil
                    }
                } catch {
                    return error.localizedDescription
                }
            }
            if let failure {
                failures.append("Could not resume \(session.name ?? identifier): \(failure)")
            } else {
                updateBulkPause(replacing: identifier)
            }
        }
        await finishBulkAction(failures: failures)
    }

    private func updateBulkPause(replacing identifier: String, with replacement: String? = nil) {
        guard let record = bulkPause, record.sessionIdentifiers.contains(identifier) else { return }
        let identifiers = record.sessionIdentifiers.compactMap { $0 == identifier ? replacement : $0 }
        bulkPause = identifiers.isEmpty ? nil : BulkPause(sessionIdentifiers: identifiers, resumeAt: record.resumeAt)
    }

    /// How the store's own attempt to resume a session ended.
    private enum UnpromptedResume {
        case resumed
        case heldBack(message: String)
    }

    /// The only way the store resumes a session that the user did not ask it by name to resume: at the end
    /// of a conflict resolve, for Resume after Pause All, at a timed pause's deadline, and to restore the
    /// original of a failed edit. A held session stays paused.
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

    /// Whether a conflict resolve is running, or waiting its turn, on the session.
    public func isResolving(_ identifier: String) -> Bool {
        resolvesInFlight[identifier] != nil
    }

    private func displayName(of identifier: String) -> String {
        syncSessions.first { $0.identifier == identifier }?.name ?? identifier
    }

    /// Resumes a session because the user asked for that session; this is what ends its hold.
    /// Refused while a conflict resolve is moving the session's files, and while the session is being edited.
    public func resumeSync(_ identifier: String) async {
        guard sessionBeingEdited != identifier else {
            lastError = "The session \"\(displayName(of: identifier))\" was not resumed: it is being edited."
            return
        }
        guard !isResolving(identifier) else {
            lastError = "The session \"\(displayName(of: identifier))\" was not resumed: a conflict resolve is running on it."
            return
        }
        // The resume takes a turn, so a resolve requested while it is in flight pauses after it.
        let failure: String? = await inTurn(on: identifier) {
            do {
                if !self.interruptedEditPairs.isEmpty {
                    let listed = try await self.provider.syncList()
                    self.recoverInterruptedEditPairs(listed: listed)
                }
                if let replacement = self.leftoverSyncOriginals[identifier] {
                    let pair = try await self.checkEditPair(original: identifier, replacement: replacement)
                    if let currentReplacement = self.leftoverSyncOriginals[identifier] {
                        return self.leftoverResumeRefusal(original: identifier, replacement: currentReplacement)
                    }
                    if pair.replacement != nil {
                        return self.leftoverResumeRefusal(original: identifier, replacement: replacement)
                    }
                }
                try await self.provider.syncResume(identifier)
                // The hold ends inside the turn, before a resolve waiting behind this resume can set another.
                self.sessionHolds[identifier] = nil
                self.replacementsUnderWay[identifier] = nil
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if let failure {
            lastError = failure
            return
        }
        lastError = nil
        await refresh()
    }

    private func leftoverResumeRefusal(original: String, replacement: String) -> String {
        "Original session \(original) cannot resume while its edited replacement \(replacement) is listed."
    }

    private func checkEditPair(
        original: String,
        replacement: String
    ) async throws -> (originalExists: Bool, replacement: SyncSession?) {
        let listed = try await provider.syncList()
        let originalExists = listed.contains { $0.identifier == original }
        let replacementSession = listed.first { $0.identifier == replacement }
        forgetMissingEditPairs([original: replacement], listed: listed)
        return (originalExists, replacementSession)
    }

    public func removeLeftoverSyncOriginal(_ identifier: String) async {
        let failure: String? = await inTurn(on: identifier) {
            guard let replacement = self.leftoverSyncOriginals[identifier] else {
                return "Session \(identifier) is no longer tracked as a leftover original."
            }
            do {
                let pair = try await self.checkEditPair(original: identifier, replacement: replacement)
                guard let replacementSession = pair.replacement else {
                    return "Original session \(identifier) was kept because its edited replacement \(replacement) is no longer listed."
                }
                guard pair.originalExists, self.leftoverSyncOriginals[identifier] == replacement else {
                    return "Original session \(identifier) is no longer tracked as a leftover original."
                }
                guard !replacementSession.paused else {
                    return "Original session \(identifier) was kept because its edited replacement \(replacement) is paused."
                }
                try await self.provider.syncTerminate(identifier)
                self.leftoverSyncOriginals[identifier] = nil
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        if let failure {
            lastError = failure
        } else {
            lastError = nil
            await reloadSessions(force: true)
        }
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
        guard daemonControl == .managed || daemonControl == .stopped else { return }
        let previousControl = daemonControl
        daemonControl = .starting
        do {
            try await provider.daemonStart()
            defaults.removeObject(forKey: Self.daemonStoppedKey)
            daemonControl = .managed
            daemonStatus = .running
            lastError = nil
            await refresh()
            schedulePolling(refreshImmediately: false)
        } catch {
            daemonControl = previousControl
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    public func stopDaemon() async -> Bool {
        if daemonControl == .stopping {
            lastError = "Mutagen is already stopping."
            return false
        }
        guard daemonControl == .managed else { return false }

        if let operation = operationBlockingDaemonStop {
            lastError = "Wait for the \(operation) to finish before stopping the Mutagen daemon."
            return false
        }
        daemonControl = .stopping
        lastError = nil
        cancelPolling()
        defer { daemonStopProgress = nil }

        // List commands can autostart Mutagen; their results must not update the UI after Stop begins.
        activeSessionLists.removeAll()
        if provider.hasPendingCommands {
            daemonStopProgress = "Waiting for running Mutagen commands to finish."
            await provider.waitForPendingCommands()
        }

        daemonStopProgress = "Stopping Mutagen."
        defaults.set(true, forKey: Self.daemonStoppedKey)
        do {
            try await provider.daemonStop()
        } catch {
            daemonStopProgress = "Checking whether Mutagen is running."
            let stopError = "Could not stop Mutagen: \(error.localizedDescription)"
            do {
                if try await daemonProcess.pid() != nil {
                    resumeManagingDaemon(status: .running, error: stopError)
                    return false
                }
            } catch {
                resumeManagingDaemon(
                    status: .unknown, error: "\(stopError). Could not verify its status: \(error.localizedDescription)"
                )
                return false
            }
        }

        daemonControl = .stopped
        daemonStatus = .stopped
        syncSessions = []
        forwardSessions = []
        backgroundPriorityPID = nil
        setDaemonPriorityError(daemonBackgroundPriorityRequested ? "Mutagen daemon not found." : nil)
        lastError = nil
        schedulePolling(refreshImmediately: false)
        return true
    }

    private func resumeManagingDaemon(status: DaemonStatus, error: String) {
        defaults.removeObject(forKey: Self.daemonStoppedKey)
        daemonStatus = status
        daemonControl = .managed
        lastError = error
        schedulePolling(refreshImmediately: false)
    }

    private var operationBlockingDaemonStop: String? {
        if sessionBeingEdited != nil { return "edit" }
        if bulkPauseInFlight { return "bulk pause" }
        if !resolvesInFlight.isEmpty { return "conflict resolve" }
        return nil
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
        guard daemonControl == .managed else { return }
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

    /// Runs `work` once every resolve and resume requested earlier on the same session has ended, so that
    /// none of them resumes the session while a resolve is moving its files. Requests run in the order they were made.
    private func inTurn<Outcome: Sendable>(
        on identifier: String,
        _ work: @escaping @MainActor () async -> Outcome
    ) async -> Outcome {
        let earlier = lastTurn[identifier]
        let turn = Task { @MainActor in
            await earlier?.value
            return await work()
        }
        let ended = Task { @MainActor in _ = await turn.value }
        lastTurn[identifier] = ended
        let outcome = await turn.value
        if lastTurn[identifier] == ended { lastTurn[identifier] = nil }
        return outcome
    }

    /// Runs `resolve` in the session's turn order.
    /// A session that is being edited when the resolve is requested, or that is held when its turn comes,
    /// is refused before anything is paused or run.
    /// - Returns: the roots left unresolved: what `resolve` returns, or all of `roots` for a refusal.
    private func resolveInTurn(
        on session: SyncSession,
        roots: Set<String>,
        _ resolve: @escaping @MainActor () async -> Set<String>
    ) async -> Set<String> {
        if let unavailable = provider.unavailable {
            lastError = unavailable.localizedDescription
            return roots
        }
        let identifier = session.identifier
        if sessionBeingEdited == identifier {
            let message = "No conflict in the session \"\(session.name ?? identifier)\" was resolved: the session is being edited."
            ConsoleLog.shared.log("resolve refused: \(message)", level: .error)
            lastError = message
            return roots
        }
        resolvesInFlight[identifier, default: 0] += 1
        let unresolved = await inTurn(on: identifier) {
            if let hold = self.sessionHolds[identifier] {
                ConsoleLog.shared.log("resolve refused: \"\(session.name ?? identifier)\" is held paused", level: .error)
                self.lastError = hold
                return roots
            }
            if let replacement = self.leftoverSyncOriginals[identifier] ?? self.interruptedEditPairs[identifier] {
                self.lastError = self.leftoverResumeRefusal(original: identifier, replacement: replacement)
                return roots
            }
            return await resolve()
        }
        // The entry exists: this call added one to it above, and only this line takes one away.
        let remaining = resolvesInFlight[identifier]! - 1
        resolvesInFlight[identifier] = remaining > 0 ? remaining : nil
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
                lastError = notice
                return unresolved
            case .winnerMissing(let winnerURL):
                ConsoleLog.shared.log("  winner file no longer exists at \(winnerURL.formatted)", level: .error)
                lastError = "The file \"\(conflict.root)\" no longer exists at the source. It may have been renamed or deleted. Try refreshing sessions."
                _ = await resumeAfterConflict(session, keeping: lastError)
                return unresolved
            }
        } catch {
            ConsoleLog.shared.log("  transport FAILED: \(error.localizedDescription)", level: .error)
            lastError = error.localizedDescription
            _ = await resumeAfterConflict(session, keeping: lastError)
            return unresolved
        }

        // Resume and flush to let mutagen re-scan with the resolved state.
        // Don't call refresh() here — syncList() right after flush catches mutagen mid-scan
        // with empty conflicts, causing UI flicker. The polling cycle brings authoritative data.
        guard await resumeAfterConflict(session, keeping: leftoverNotice) else { return unresolved }
        ConsoleLog.shared.log("  resumed session")
        do {
            try await provider.syncFlush(session.identifier)
            ConsoleLog.shared.log("  flush succeeded")
            lastError = leftoverNotice
        } catch {
            ConsoleLog.shared.log("  flush FAILED: \(error.localizedDescription)", level: .error)
            lastError = ([error.localizedDescription] + [leftoverNotice].compactMap { $0 }).joined(separator: " ")
        }
        return []
    }

    private func resumeAfterConflict(_ session: SyncSession, keeping priorNotice: String?) async -> Bool {
        do {
            if case .heldBack(let hold) = try await resumeUnlessHeld(session.identifier) {
                lastError = hold
                return false
            }
            return true
        } catch {
            let name = session.name ?? session.identifier
            let message = "Could not confirm that Mutagen resumed \"\(name)\". Flush was skipped. Check the session status before retrying. \(error.localizedDescription)"
            ConsoleLog.shared.log(message, level: .error)
            lastError = ([message] + [priorNotice].compactMap { $0 }).joined(separator: " ")
            return false
        }
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

        let priorNotice = notices.isEmpty ? nil : notices.joined(separator: " ")
        guard await resumeAfterConflict(session, keeping: priorNotice) else { return Set(conflicts.map(\.root)) }
        do {
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
        /// is held paused; `notice` is its hold message and names the paths that hold the data.
        case leftUnverified(notice: String)
        /// The winner's file is gone, so neither side was touched.
        case winnerMissing(EndpointURL)
    }

    /// Makes the loser's side of one conflict match the winner's: removes it when the winner deleted the
    /// conflict root, and otherwise replaces it with a copy of the winner. Throws the transport's error
    /// when the session is safe to resume; a replacement that is not holds the session and comes back as `leftUnverified`.
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
            replacementsUnderWay[session.identifier] = "Helix quit while removing \(loserURL.formatted); check whether that path was partly deleted."
            do {
                try await fileTransport.remove(endpoint: loserURL)
                replacementsUnderWay[session.identifier] = nil
                return .applied
            } catch {
                if error.isCommandInterruption {
                    return holdAfterConflictInterruption(
                        "Could not confirm removal of \(loserURL.formatted): \(error.localizedDescription)",
                        session: session, root: conflict.root
                    )
                }
                replacementsUnderWay[session.identifier] = nil
                throw error
            }
        }
        guard try await fileTransport.pathExists(endpoint: winnerURL) else {
            return .winnerMissing(winnerURL)
        }
        ConsoleLog.shared.log("  action: REPLACE \(loserURL.formatted) with a copy of \(winnerURL.formatted)")
        let plan = ReplacePlan(replacing: loserURL, withCopyOf: winnerURL)
        replacementsUnderWay[session.identifier] = "Helix quit while replacing \(plan.destination.formatted); check \(plan.incoming.formatted) and \(plan.setAside.formatted)"
        do {
            let outcome = try await fileTransport.replace(plan)
            switch outcome {
            case .replaced:
                replacementsUnderWay[session.identifier] = nil
                return .applied
            case .replacedLeavingOriginal(let path, let reason):
                replacementsUnderWay[session.identifier] = nil
                return .appliedLeavingOriginal(
                    notice: "Resolved \"\(conflict.root)\", but left the original it replaced at \(path): \(reason). Delete that path by hand."
                )
            case .replacedWithInterruptedRemoval(let path, let reason):
                return holdAfterConflictInterruption(
                    "The set-aside tree at \(path) may be partly deleted: \(reason)", session: session, root: conflict.root
                )
            }
        } catch {
            if error.wasInterrupted {
                let message = "\(error.localizedDescription). Check \(plan.incoming.formatted) and \(plan.setAside.formatted)"
                return holdAfterConflictInterruption(message, session: session, root: conflict.root)
            }
            switch error.aftermath {
            case .destinationUnchanged:
                if case .unverified = error.incomingCopy {
                    return holdAfterConflictInterruption(error.localizedDescription, session: session, root: conflict.root)
                }
                replacementsUnderWay[session.identifier] = nil
                throw error
            case .destinationUnverified:
                let notice = "\(error.localizedDescription). The session \"\(session.name ?? session.identifier)\" was left paused so that sync cannot overwrite or delete those paths. Put \"\(conflict.root)\" in order, then resume the session."
                // The hold is saved before the record of the replacement goes, so quitting in between loses neither.
                sessionHolds[session.identifier] = notice
                replacementsUnderWay[session.identifier] = nil
                return .leftUnverified(notice: notice)
            }
        }
    }

    private func holdAfterConflictInterruption(_ message: String, session: SyncSession, root: String) -> ConflictFileOutcome {
        let notice = "\(message). The session \"\(session.name ?? session.identifier)\" was left paused. Put \"\(root)\" in order, then resume the session."
        sessionHolds[session.identifier] = notice
        return .leftUnverified(notice: notice)
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
            command: "find . -maxdepth 2 -name .git -type d 2>/dev/null", deadline: CommandDeadline.query
        )
        async let betaOutput = try? fileTransport.run(
            on: session.beta.endpointURL,
            command: "find . -maxdepth 2 -name .git -type d 2>/dev/null", deadline: CommandDeadline.query
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
            command: "git config --get remote.origin.url", deadline: CommandDeadline.query
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
            on: sourceEndpoint, command: "git config --get remote.origin.url", deadline: CommandDeadline.query
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = (try? await fileTransport.run(
            on: sourceEndpoint, command: "git branch --show-current", deadline: CommandDeadline.query
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
            remoteURL = try await fileTransport.run(on: sourceEndpoint, command: "git config --get remote.origin.url", deadline: CommandDeadline.query).trimmingCharacters(in: .whitespacesAndNewlines)
            branch = try await fileTransport.run(on: sourceEndpoint, command: "git branch --show-current", deadline: CommandDeadline.query).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            lastError = "Could not read git info: \(error.localizedDescription)"
            return false
        }

        guard !remoteURL.isEmpty, !branch.isEmpty else {
            lastError = "No git remote or branch found on the source endpoint"
            return false
        }

        do {
            _ = try await fileTransport.run(on: targetEndpoint, command: "git init", deadline: CommandDeadline.operation)
            _ = try await fileTransport.run(on: targetEndpoint, command: "git remote add origin '\(remoteURL)'", deadline: CommandDeadline.operation)
            _ = try await fileTransport.run(on: targetEndpoint, command: "git fetch origin", deadline: CommandDeadline.transfer)
            _ = try await fileTransport.run(on: targetEndpoint, command: "git reset --mixed 'origin/\(branch)'", deadline: CommandDeadline.operation)
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
        cancelPolling()
        pollingInterval = interval
        schedulePolling(refreshImmediately: true)
    }

    public func stopPolling() {
        pollingInterval = nil
        cancelPolling()
    }

    private func cancelPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func schedulePolling(refreshImmediately: Bool) {
        guard daemonControl == .managed || daemonControl == .stopped else { return }
        guard pollingTask == nil, let interval = pollingInterval else { return }
        pollingTask = Task { [weak self] in
            if refreshImmediately { await self?.refresh() }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                await self?.refresh()
            }
        }
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
            hasher.combine(s.configuration)
            hasher.combine(s.conflicts ?? [])
            hasher.combine(s.excludedConflicts)
            for endpoint in [s.alpha, s.beta] {
                hasher.combine(endpoint.connected)
                hasher.combine(endpoint.configuration)
                hasher.combine(endpoint.stagingProgress)
                hasher.combine(endpoint.scanProblems)
                hasher.combine(endpoint.excludedScanProblems)
                hasher.combine(endpoint.transitionProblems)
                hasher.combine(endpoint.excludedTransitionProblems)
            }
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

    @discardableResult
    private func performAction(_ action: @Sendable () async throws -> Void) async -> String? {
        do {
            try await action()
            lastError = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
        return lastError
    }
}
