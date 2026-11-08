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

public enum HealthStatus: Sendable, CaseIterable {
    case healthy
    case active
    case partiallyPaused
    case paused
    case warning
    case error
    case daemonStopped
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

    private var provider: any SessionProvider
    private var pollingTask: Task<Void, Never>?
    private let fileTransport: FileTransport

    public init(provider: any SessionProvider, fileTransport: FileTransport = FileTransport()) {
        self.provider = provider
        self.fileTransport = fileTransport
    }

    public func replaceProvider(_ provider: any SessionProvider) {
        self.provider = provider
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

    /// Health of the sessions that are not paused, or a paused state when the user paused some or all of them.
    public var overallHealth: HealthStatus {
        if !daemonRunning {
            return .daemonStopped
        }
        if syncSessions.isEmpty && forwardSessions.isEmpty {
            return .idle
        }
        let runningSyncs = syncSessions.filter { !$0.paused }
        let runningForwards = forwardSessions.filter { !$0.paused }
        if runningSyncs.isEmpty && runningForwards.isEmpty {
            return .paused
        }
        let hasDisconnected = runningSyncs.contains { $0.phase == .disconnected || $0.phase == .connecting }
            || runningForwards.contains { $0.source.connected == false || $0.destination.connected == false }
        if hasDisconnected {
            return .error
        }
        let hasConflicts = runningSyncs.contains { !($0.conflicts ?? []).isEmpty }
        let hasStalled = runningSyncs.contains { $0.phase == .stalled }
        if hasConflicts || hasStalled {
            return .warning
        }
        let hasActive = runningSyncs.contains { $0.phase == .syncing }
        if hasActive {
            return .active
        }
        let hasPaused = runningSyncs.count < syncSessions.count || runningForwards.count < forwardSessions.count
        return hasPaused ? .partiallyPaused : .healthy
    }

    public func refresh() async {
        do {
            async let syncs = provider.syncList()
            async let forwards = provider.forwardList()
            let newSyncs = preserveConflicts(old: syncSessions, new: try await syncs)
            let newForwards = try await forwards
            if syncDigest(newSyncs) != syncDigest(syncSessions) { syncSessions = newSyncs }
            if forwardDigest(newForwards) != forwardDigest(forwardSessions) { forwardSessions = newForwards }
            if !daemonRunning { daemonRunning = true }
            if lastError != nil { lastError = nil }
        } catch {
            if !daemonRunning || lastError != error.localizedDescription {
                daemonRunning = false
                lastError = error.localizedDescription
            }
        }
    }

    public func manualRefresh() async {
        do {
            async let syncs = provider.syncList()
            async let forwards = provider.forwardList()
            syncSessions = try await syncs
            forwardSessions = try await forwards
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

    // MARK: - Sync Actions

    public func pauseSync(_ identifier: String) async {
        await performAction { try await provider.syncPause(identifier) }
    }

    public func resumeSync(_ identifier: String) async {
        await performAction { try await provider.syncResume(identifier) }
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

    public func resolveConflict(
        session: SyncSession,
        conflict: Conflict,
        winner: ConflictWinner
    ) async {
        let alphaURL = appendingSubpath(to: session.alpha.endpointURL, subpath: conflict.root)
        let betaURL = appendingSubpath(to: session.beta.endpointURL, subpath: conflict.root)

        let (winnerURL, loserURL) = switch winner {
        case .alpha: (alphaURL, betaURL)
        case .beta: (betaURL, alphaURL)
        }

        let winnerChanges = winner == .alpha ? conflict.alphaChanges : conflict.betaChanges
        ConsoleLog.shared.log("resolveConflict: \(winner) wins for root '\(conflict.root)'")
        ConsoleLog.shared.log("  winnerURL: \(winnerURL.formatted)")
        ConsoleLog.shared.log("  loserURL: \(loserURL.formatted)")
        ConsoleLog.shared.log("  winnerChanges: \(winnerChanges.map { "path='\($0.path)' old=\($0.old?.kind ?? "nil") new=\($0.new?.kind ?? "nil")" }.joined(separator: ", "))")

        let winnerDeletedRoot = winnerChanges.contains { $0.path == conflict.root && $0.new == nil }
        ConsoleLog.shared.log("  winnerDeletedRoot: \(winnerDeletedRoot)")

        // Pause the session to prevent mutagen from syncing while we modify files
        do {
            try await provider.syncPause(session.identifier)
            ConsoleLog.shared.log("  paused session")
        } catch {
            ConsoleLog.shared.log("  pause FAILED: \(error.localizedDescription)", level: .error)
            lastError = "Failed to pause session: \(error.localizedDescription)"
            return
        }

        do {
            if winnerDeletedRoot {
                ConsoleLog.shared.log("  action: REMOVE \(loserURL.formatted)")
                try await fileTransport.remove(endpoint: loserURL)
            } else {
                let exists = try await fileTransport.pathExists(endpoint: winnerURL)
                guard exists else {
                    ConsoleLog.shared.log("  winner file no longer exists at \(winnerURL.formatted)", level: .error)
                    lastError = "The file \"\(conflict.root)\" no longer exists at the source. It may have been renamed or deleted. Try refreshing sessions."
                    try? await provider.syncResume(session.identifier)
                    return
                }
                ConsoleLog.shared.log("  action: REMOVE \(loserURL.formatted) then COPY \(winnerURL.formatted)")
                try await fileTransport.remove(endpoint: loserURL)
                try await fileTransport.copy(from: winnerURL, to: loserURL)
            }
            ConsoleLog.shared.log("  transport succeeded")
        } catch {
            ConsoleLog.shared.log("  transport FAILED: \(error.localizedDescription)", level: .error)
            lastError = error.localizedDescription
            try? await provider.syncResume(session.identifier)
            return
        }

        // Resume and flush to let mutagen re-scan with the resolved state.
        // Don't call refresh() here — syncList() right after flush catches mutagen mid-scan
        // with empty conflicts, causing UI flicker. The polling cycle brings authoritative data.
        do {
            try await provider.syncResume(session.identifier)
            ConsoleLog.shared.log("  resumed session")
            try await provider.syncFlush(session.identifier)
            ConsoleLog.shared.log("  flush succeeded")
            lastError = nil
        } catch {
            ConsoleLog.shared.log("  flush FAILED: \(error.localizedDescription)", level: .error)
            lastError = error.localizedDescription
        }
    }

    public func resolveConflicts(
        session: SyncSession,
        conflicts: [Conflict],
        winner: ConflictWinner
    ) async {
        guard !conflicts.isEmpty else { return }

        ConsoleLog.shared.log("resolveConflicts: \(winner) wins for \(conflicts.count) conflicts")

        do {
            try await provider.syncPause(session.identifier)
            ConsoleLog.shared.log("  paused session")
        } catch {
            ConsoleLog.shared.log("  pause FAILED: \(error.localizedDescription)", level: .error)
            lastError = "Failed to pause session: \(error.localizedDescription)"
            return
        }

        var resolved = 0
        var failed = 0
        for conflict in conflicts {
            let alphaURL = appendingSubpath(to: session.alpha.endpointURL, subpath: conflict.root)
            let betaURL = appendingSubpath(to: session.beta.endpointURL, subpath: conflict.root)
            let (winnerURL, loserURL) = switch winner {
            case .alpha: (alphaURL, betaURL)
            case .beta: (betaURL, alphaURL)
            }
            let winnerChanges = winner == .alpha ? conflict.alphaChanges : conflict.betaChanges
            let winnerDeletedRoot = winnerChanges.contains { $0.path == conflict.root && $0.new == nil }

            do {
                if winnerDeletedRoot {
                    try await fileTransport.remove(endpoint: loserURL)
                } else {
                    let exists = try await fileTransport.pathExists(endpoint: winnerURL)
                    guard exists else {
                        ConsoleLog.shared.log("  skipped '\(conflict.root)': winner file no longer exists", level: .error)
                        failed += 1
                        continue
                    }
                    try await fileTransport.remove(endpoint: loserURL)
                    try await fileTransport.copy(from: winnerURL, to: loserURL)
                }
                resolved += 1
            } catch {
                ConsoleLog.shared.log("  failed '\(conflict.root)': \(error.localizedDescription)", level: .error)
                failed += 1
            }
        }

        ConsoleLog.shared.log("  resolved \(resolved)/\(conflicts.count) conflicts (\(failed) failed)")

        do {
            try await provider.syncResume(session.identifier)
            try await provider.syncFlush(session.identifier)
            if failed > 0 {
                lastError = "\(failed) of \(conflicts.count) conflicts could not be resolved."
            } else {
                lastError = nil
            }
        } catch {
            ConsoleLog.shared.log("  flush FAILED: \(error.localizedDescription)", level: .error)
            lastError = error.localizedDescription
        }
    }

    // MARK: - Git Repo Detection

    public func gitRepoStatus(for session: SyncSession) async -> GitRepoCheck {
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

    /// Carries forward known conflicts when new poll data has nil conflicts (mid-scan).
    /// Go protobuf omits empty repeated fields, so mid-scan JSON has `conflicts: null`.
    private func preserveConflicts(old: [SyncSession], new: [SyncSession]) -> [SyncSession] {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.identifier, $0) })
        return new.map { session in
            guard session.conflicts == nil,
                  let previous = oldByID[session.identifier],
                  previous.conflicts != nil else {
                return session
            }
            var patched = session
            patched.conflicts = previous.conflicts
            return patched
        }
    }

    /// Hashes fields that affect the UI (identity, status, conflicts, connectivity).
    /// Excludes volatile counters like successfulCycles and endpoint scan statistics
    /// that change every mutagen scan cycle.
    private func syncDigest(_ sessions: [SyncSession]) -> Int {
        var hasher = Hasher()
        for s in sessions {
            hasher.combine(s.identifier)
            hasher.combine(s.name)
            hasher.combine(s.status)
            hasher.combine(s.paused)
            hasher.combine(s.mode)
            hasher.combine(s.conflicts?.count ?? 0)
            hasher.combine(s.alpha.connected)
            hasher.combine(s.beta.connected)
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
