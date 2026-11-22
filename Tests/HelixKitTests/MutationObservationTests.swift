// ABOUTME: Tests recovery when a Mutagen command loses its receipt.
// ABOUTME: Runs the session store and CLI against a stateful command fixture.

import Foundation
import Testing
@testable import HelixKit

@MainActor
struct MutationObservationTests {
    @Test("A connection error during edit activation restores the original even if the replacement became unpaused")
    func ordinaryResumeFailureRecoversEdit() async throws {
        let original = makeSyncSession(id: "original", name: "Project")
        let commands = MutationCommands(
            sessions: [original], interruption: .resumeConnectFailure(MutationCommands.replacementID)
        )
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }

        let notice = await fixture.store.recreateSync(
            original, options: SyncCreateOptions(from: original), alpha: "/tmp/a", beta: "user@unreachable.invalid:/tmp/b"
        )

        let sessions = await commands.sessions
        #expect(sessions.map(\.identifier) == [original.identifier])
        #expect(sessions.first?.paused == false)
        #expect(notice == "Could not start the edited session: unable to connect to beta: connection refused. The original session was restored.")
    }

    @Test("Manual Resume clears a hold only when the command succeeds or its deadline is reconciled", arguments: [false, true])
    func heldResumeUsesCommandOutcome(deadline: Bool) async throws {
        let session = makeSyncSession(id: "held", name: "Held", paused: true)
        let interruption: MutationCommands.Interruption = deadline
            ? .resumeDeadline(session.identifier) : .resumeConnectFailure(session.identifier)
        let commands = MutationCommands(sessions: [session], interruption: interruption)
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }
        let holds = [session.identifier: "Check the conflict files before resuming."]
        fixture.defaults.set(holds, forKey: "sessionHolds")
        let store = SessionStore(provider: commands.cli, defaults: fixture.defaults)

        #expect(store.sessionHolds == holds)
        await store.resumeSync(session.identifier)

        #expect(await commands.sessions.first?.paused == false)
        if deadline {
            #expect(store.sessionHolds.isEmpty)
            #expect(store.lastError == nil)
        } else {
            #expect(store.sessionHolds == holds)
            #expect(store.lastError == "unable to connect to beta: connection refused")
        }
    }

    @Test("Pause reports a save error even if the session became paused")
    func ordinaryPauseFailureReportsError() async throws {
        let session = makeSyncSession(id: "project", name: "Project")
        let commands = MutationCommands(sessions: [session], interruption: .pauseSaveFailure)
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }

        await fixture.store.pauseSync(session.identifier)

        #expect(await commands.sessions.first?.paused == true)
        #expect(fixture.store.lastError == "unable to save session")
    }

    @Test("Terminate reports an archive error even if the session left the list")
    func ordinaryTerminateFailureReportsError() async throws {
        let session = makeSyncSession(id: "project", name: "Project")
        let commands = MutationCommands(sessions: [session], interruption: .terminateArchiveFailure)
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }

        await fixture.store.terminateSync(session.identifier)

        #expect(await commands.sessions.isEmpty)
        #expect(fixture.store.lastError == "unable to remove archive from disk")
    }

    @Test("A failed Start leaves Helix stopped even if the process is present")
    func ordinaryStartFailureKeepsStopFence() async throws {
        let commands = MutationCommands(interruption: .daemonStartFailed)
        let daemon = RecordingDaemonProcess(pid: 123)
        let fixture = try MutationStoreFixture(commands: commands, daemon: daemon)
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "daemonStoppedByHelix")
        let store = SessionStore(provider: commands.cli, defaults: fixture.defaults, daemonProcess: daemon)

        await store.startDaemon()

        #expect(store.daemonStatus == .startedOutside)
        #expect(fixture.defaults.bool(forKey: "daemonStoppedByHelix"))
        #expect(store.lastError == "unable to start daemon")
    }

    @Test("Manual Resume protects shared paths without an edit record", arguments: [false, true])
    func manualResumeChecksBothEndpointOrders(reversed: Bool) async throws {
        let original = makeSyncSession(id: "original", name: "Original", paused: true)
        let replacement = makeSyncSession(
            id: "replacement", name: "Replacement",
            alpha: reversed ? original.beta : original.alpha, beta: reversed ? original.alpha : original.beta
        )
        let commands = MutationCommands(sessions: [original])
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }

        await fixture.store.refresh()
        #expect(fixture.store.syncSessions.map(\.identifier) == [original.identifier])
        #expect(fixture.store.leftoverSyncOriginals.isEmpty)
        await commands.addSession(replacement)
        await fixture.store.resumeSync(original.identifier)

        #expect(await commands.sessions.map(\.paused) == [true, false])
        #expect(fixture.store.lastError == "Cannot resume \"Original\" while \"Replacement\" is running on the same endpoints.")
    }

    @Test("A timed Pause All resume leaves the replacement paused while the original runs")
    func timedResumeChecksSharedEndpoints() async throws {
        let original = makeSyncSession(id: "original", name: "Original")
        let replacement = makeSyncSession(id: "replacement", name: "Replacement", paused: true)
        let commands = MutationCommands(sessions: [original, replacement])
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }
        let pause = BulkPause(sessionIdentifiers: [replacement.identifier], resumeAt: .distantPast)
        fixture.defaults.set(try JSONEncoder().encode(pause), forKey: "bulkPause")
        let cleanup = "A displaced conflict file is still on disk."
        fixture.defaults.set([replacement.identifier: cleanup], forKey: "leftoverNotices")
        let store = SessionStore(provider: commands.cli, defaults: fixture.defaults)
        let warning = "Timed Pause All left this session paused. Cannot resume \"Replacement\" while \"Original\" is running on the same endpoints."
        let combinedNotice = "\(warning)\n\n\(cleanup)"

        await store.refresh()

        #expect(await commands.sessions.map(\.paused) == [false, true])
        #expect(store.bulkPause == nil)
        #expect(store.leftoverNotices[replacement.identifier] == combinedNotice)
        #expect(ConsoleLog.shared.entries.contains { $0.message == warning && $0.level == .error })
        await store.refresh()
        await store.refresh()
        #expect(store.leftoverNotices[replacement.identifier] == combinedNotice)

        await store.pauseSync(original.identifier)
        await store.resumeSync(replacement.identifier)
        #expect(await commands.sessions.map(\.paused) == [true, false])
        #expect(store.leftoverNotices[replacement.identifier] == cleanup)
    }

    @Test("Resume Anyway applies once and a held session needs separate consent")
    func manualResumeOverrideAppliesOnce() async throws {
        let target = makeSyncSession(id: "target", name: "Target", paused: true)
        let peer = makeSyncSession(id: "peer", name: "Other")
        let different = makeSyncSession(id: "different", name: "Different", paused: true)
        let commands = MutationCommands(sessions: [target, peer, different])
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }
        let hold = "Check the conflict files before resuming."
        fixture.defaults.set([target.identifier: hold], forKey: "sessionHolds")
        let store = SessionStore(provider: commands.cli, defaults: fixture.defaults)

        guard case .held(let reason)? = await store.requestSyncResume(target.identifier) else {
            Issue.record("Expected a hold confirmation")
            return
        }
        #expect(reason == hold)
        guard case .overlap(let overlap)? = await store.requestSyncResume(target.identifier, confirmingHold: hold) else {
            Issue.record("Expected a separate same-endpoint confirmation")
            return
        }
        #expect(overlap.localizedDescription == "Cannot resume \"Target\" while \"Other\" is running on the same endpoints.")
        #expect(await commands.sessions.map(\.paused) == [true, false, true])
        #expect(store.sessionHolds == [target.identifier: hold])

        guard case .overlap(let differentRefusal)? = await store.requestSyncResume(different.identifier, overriding: overlap) else {
            Issue.record("The approval for Target must leave Different paused")
            return
        }
        #expect(differentRefusal.message == "Cannot resume \"Different\" while \"Other\" is running on the same endpoints.")
        #expect(await commands.sessions.map(\.paused) == [true, false, true])

        #expect(await store.requestSyncResume(target.identifier, confirmingHold: hold, overriding: overlap) == nil)
        #expect(await commands.sessions.map(\.paused) == [false, false, true])
        #expect(store.sessionHolds.isEmpty)

        await store.pauseSync(target.identifier)
        guard case .overlap(let freshApproval)? = await store.requestSyncResume(target.identifier, overriding: overlap) else {
            Issue.record("A spent approval must produce another refusal")
            return
        }
        #expect(freshApproval.message == overlap.message)
        #expect(await commands.sessions.map(\.paused) == [true, false, true])

        await store.pauseSync(peer.identifier)
        let replacementPeer = makeSyncSession(id: "replacement-peer", name: "Replacement Peer")
        await commands.addSession(replacementPeer)
        guard case .overlap(let changedPeerRefusal)? = await store.requestSyncResume(target.identifier, overriding: freshApproval) else {
            Issue.record("Approval for the first peer must leave Target paused beside the replacement peer")
            return
        }
        #expect(changedPeerRefusal.message == "Cannot resume \"Target\" while \"Replacement Peer\" is running on the same endpoints.")
        #expect(await commands.sessions.map(\.paused) == [true, true, true, false])
    }

    @Test("New Sync finds paused sessions through either temporary path spelling in reverse order", arguments: [false, true])
    func warnsAboutExistingSyncEndpoints(listedWithPrivatePrefix: Bool) async throws {
        let suffix = "helix-duplicate-warning-\(UUID())"
        let alias = "/tmp/\(suffix)"
        let resolved = "/private/tmp/\(suffix)"
        let existing = makeSyncSession(
            id: "existing", name: "Existing", paused: true,
            alpha: makeEndpoint(path: listedWithPrivatePrefix ? resolved : alias)
        )
        let other = makeSyncSession(id: "other", name: "Other", beta: makeEndpoint(path: "/tmp/other"))
        let commands = MutationCommands(sessions: [existing, other])
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }

        let names = try await fixture.store.duplicateSyncSessionNames(
            alpha: .local(path: "/tmp/b"), beta: .local(path: listedWithPrivatePrefix ? alias : resolved)
        )

        #expect(names == ["Existing"])
        #expect(await commands.sessions.map(\.identifier) == [existing.identifier, other.identifier])
    }

    @Test("An edit can restore overlap that existed before it paused the original")
    func editRestoresPreviouslyRunningOverlap() async throws {
        let original = makeSyncSession(id: "original", name: "Project")
        let peer = makeSyncSession(id: "peer", name: "Other")
        let commands = MutationCommands(sessions: [original, peer])
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }

        let notice = await fixture.store.recreateSync(
            original, options: SyncCreateOptions(from: original), alpha: "/tmp/a", beta: "/tmp/b"
        )

        #expect(notice == nil)
        #expect(await commands.sessions.map(\.identifier) == [peer.identifier, MutationCommands.replacementID])
        #expect(await commands.sessions.map(\.paused) == [false, false])
    }

    @Test("An edit cannot restore a late overlap or carry approval to changed endpoints", arguments: [false, true])
    func editKeepsOriginalWhenOverlapCannotBeRestored(changedEndpoints: Bool) async throws {
        let original = makeSyncSession(id: "original", name: "Project")
        let beta = makeEndpoint(path: changedEndpoints ? "/tmp/changed" : "/tmp/b")
        let peer = makeSyncSession(id: "peer", name: "Other", paused: !changedEndpoints, beta: beta)
        let previous = makeSyncSession(id: "previous", name: "Previous")
        let commands = MutationCommands(
            sessions: changedEndpoints ? [original, previous, peer] : [original, peer],
            startingPeerOnPause: changedEndpoints ? nil : peer.identifier, replacementBeta: beta
        )
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }

        await fixture.store.recreateSync(
            original, options: SyncCreateOptions(from: original), alpha: "/tmp/a", beta: try #require(beta.path)
        )

        let sessions = await commands.sessions
        let resumeCommands = await commands.calls.filter { $0.prefix(2) == ["sync", "resume"] }
        if changedEndpoints {
            #expect(sessions.map(\.identifier) == [original.identifier, previous.identifier, peer.identifier])
            #expect(sessions.map(\.paused) == [false, false, false])
            #expect(resumeCommands == [["sync", "resume", original.identifier]])
        } else {
            #expect(sessions.map(\.identifier) == [original.identifier, peer.identifier])
            #expect(sessions.map(\.paused) == [true, false])
            #expect(resumeCommands.isEmpty)
        }
    }

    @Test("Resume protects the oldest original after the edit records disappear")
    func resumeChecksPathsAfterEditChainDisappears() async throws {
        let oldest = makeSyncSession(id: "O0", name: "Oldest", paused: true)
        let previous = makeSyncSession(id: "P", name: "Previous")
        let newest = makeSyncSession(id: "R", name: "Newest", paused: true)
        let commands = MutationCommands(sessions: [oldest, previous, newest])
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }
        let pairs = [oldest.identifier: newest.identifier, previous.identifier: newest.identifier]
        fixture.defaults.set(pairs, forKey: "leftoverSyncOriginals")
        let store = SessionStore(provider: commands.cli, defaults: fixture.defaults)

        #expect(store.leftoverSyncOriginals == pairs)
        await store.terminateSync(newest.identifier)
        #expect(store.leftoverSyncOriginals.isEmpty)
        await store.resumeSync(oldest.identifier)

        #expect(await commands.sessions.map(\.paused) == [true, false])
        #expect(store.lastError == "Cannot resume \"Oldest\" while \"Previous\" is running on the same endpoints.")
    }

    @Test("An interrupted edit proceeds only if the original is observed paused", arguments: [true, false])
    func interruptedOriginalPause(pausesOriginal: Bool) async throws {
        let original = makeSyncSession(id: "original", name: "Project")
        let commands = MutationCommands(sessions: [original], interruption: pausesOriginal ? .pauseSucceeded : .pauseFailed)
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }

        let notice = await fixture.store.recreateSync(
            original, options: SyncCreateOptions(from: original), alpha: "/tmp/a", beta: "/tmp/b"
        )

        let sessions = await commands.sessions
        if pausesOriginal {
            #expect(notice == nil)
            #expect(sessions.map(\.identifier) == [MutationCommands.replacementID])
            #expect(sessions.first?.paused == false)
        } else {
            #expect(notice?.contains("is still running") == true)
            #expect(sessions.map(\.paused) == [false, true])
        }
    }

    @Test("An unknown Stop result stays fenced across refresh and relaunch")
    func unknownStopStaysFenced() async throws {
        let commands = MutationCommands()
        let fixture = try MutationStoreFixture(commands: commands, daemon: UnreadableDaemonProcess())
        defer { fixture.cleanUp() }

        #expect(await fixture.store.stopDaemon() == false)
        #expect(fixture.store.daemonStatus == .unknown)
        #expect(fixture.defaults.bool(forKey: "daemonStoppedByHelix"))

        await fixture.store.refresh()
        let relaunched = SessionStore(provider: commands.cli, defaults: fixture.defaults, daemonProcess: UnreadableDaemonProcess())
        await relaunched.refresh()

        #expect(relaunched.daemonStatus == .unknown)
        #expect(await commands.calls == [["daemon", "stop"]])
    }

    @Test("Quitting during Stop keeps the daemon fenced even if Mutagen is still running")
    func quittingDuringStopKeepsIntent() async throws {
        let gate = Gate()
        let commands = MutationCommands(stopGate: gate)
        let daemon = RecordingDaemonProcess(pid: 123)
        let fixture = try MutationStoreFixture(commands: commands, daemon: daemon)
        defer { fixture.cleanUp() }

        let stop = Task { await fixture.store.stopDaemon() }
        await gate.reached()
        fixture.store.prepareToQuit()
        await gate.open()

        #expect(await stop.value == false)
        #expect(fixture.defaults.bool(forKey: "daemonStoppedByHelix"))
        let relaunched = SessionStore(provider: commands.cli, defaults: fixture.defaults, daemonProcess: daemon)
        await relaunched.refresh()
        #expect(relaunched.daemonStatus == .startedOutside)
        #expect(await commands.calls == [["daemon", "stop"]])
    }

    @Test("Edit recovery leaves the original paused while its replacement is still running")
    func failedReplacementRemovalChecksState() async throws {
        let original = makeSyncSession(id: "original", name: "Project")
        let commands = MutationCommands(sessions: [original], interruption: .recoveryLeavesReplacementRunning)
        let fixture = try MutationStoreFixture(commands: commands)
        defer { fixture.cleanUp() }

        let notice = await fixture.store.recreateSync(
            original, options: SyncCreateOptions(from: original), alpha: "/tmp/a", beta: "/tmp/b"
        )

        let sessions = await commands.sessions
        #expect(sessions.map(\.paused) == [true, false])
        #expect(notice?.contains("Check both sessions before resuming original session original") == true)
    }
}

@MainActor
private struct MutationStoreFixture {
    private let suite = "MutationObservationTests.\(UUID())"
    let defaults: UserDefaults
    let store: SessionStore

    init(commands: MutationCommands, daemon: any DaemonProcess = RecordingDaemonProcess(pid: nil)) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        store = SessionStore(provider: commands.cli, defaults: defaults, daemonProcess: daemon)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private struct UnreadableDaemonProcess: DaemonProcess {
    func pid() async throws -> ProcessID? {
        throw DaemonProcessError.unreadablePID("invalid")
    }

    func setBackgroundPriority(_ enabled: Bool, pid: ProcessID) async throws {}
}

actor MutationCommands {
    enum Interruption: Equatable {
        case none, pauseSucceeded, pauseFailed, recoveryLeavesReplacementRunning
        case resumeConnectFailure(String), resumeDeadline(String)
        case pauseSaveFailure, terminateArchiveFailure, daemonStartFailed
    }

    static let replacementID = "sync_" + String(repeating: "R", count: 43)
    let interruption: Interruption
    private let stopGate: Gate?
    private let startingPeerOnPause: String?
    private let replacementBeta: Endpoint
    private(set) var calls: [[String]] = []
    private(set) var sessions: [SyncSession]

    init(
        sessions: [SyncSession] = [], interruption: Interruption = .none, stopGate: Gate? = nil,
        startingPeerOnPause: String? = nil, replacementBeta: Endpoint = makeEndpoint(path: "/tmp/b")
    ) {
        self.sessions = sessions
        self.interruption = interruption
        self.stopGate = stopGate
        self.startingPeerOnPause = startingPeerOnPause
        self.replacementBeta = replacementBeta
    }

    nonisolated var cli: CLI {
        CLI(executablePath: "/test/mutagen", baseArguments: []) { path, arguments, deadline in
            try await self.execute(arguments, timeout: ProcessDeadlineError(executablePath: path, deadline: deadline))
        }
    }

    private func execute(_ arguments: [String], timeout: ProcessDeadlineError) async throws -> String {
        calls.append(arguments)
        let command = Array(arguments.prefix(2))
        let identifier = arguments.dropFirst(2).first ?? ""
        switch command {
        case ["sync", "list"]:
            return String(decoding: try JSONEncoder().encode(sessions), as: UTF8.self)
        case ["forward", "list"]:
            return "[]"
        case ["sync", "create"]:
            sessions.append(makeSyncSession(id: Self.replacementID, name: "Edited Project", paused: true, beta: replacementBeta))
            return "Created session \(Self.replacementID)"
        case ["sync", "pause"]:
            if identifier == Self.replacementID && interruption == .recoveryLeavesReplacementRunning { break }
            if interruption != .pauseFailed { setPaused(true, identifier: identifier) }
            if let startingPeerOnPause { setPaused(false, identifier: startingPeerOnPause) }
            if interruption == .pauseSucceeded || interruption == .pauseFailed { throw timeout }
            if interruption == .pauseSaveFailure { throw CLIError(exitCode: 1, stderr: "unable to save session") }
        case ["sync", "resume"]:
            if identifier == Self.replacementID && interruption == .recoveryLeavesReplacementRunning {
                throw CLIError(exitCode: 1, stderr: "The exit receipt was lost.")
            }
            setPaused(false, identifier: identifier)
            if interruption == .resumeConnectFailure(identifier) {
                throw CLIError(exitCode: 1, stderr: "unable to connect to beta: connection refused")
            }
            if interruption == .resumeDeadline(identifier) { throw timeout }
        case ["sync", "flush"]:
            break
        case ["sync", "terminate"]:
            if identifier == Self.replacementID && interruption == .recoveryLeavesReplacementRunning {
                setPaused(false, identifier: identifier)
                throw CLIError(exitCode: 1, stderr: "The session could not be removed.")
            }
            sessions.removeAll { $0.identifier == identifier }
            if interruption == .terminateArchiveFailure {
                throw CLIError(exitCode: 1, stderr: "unable to remove archive from disk")
            }
        case ["daemon", "start"] where interruption == .daemonStartFailed:
            throw CLIError(exitCode: 1, stderr: "unable to start daemon")
        case ["daemon", "stop"]:
            await stopGate?.pass()
            throw timeout
        default:
            throw CLIError(exitCode: 1, stderr: "Unexpected test command \(arguments)")
        }
        return ""
    }

    func addSession(_ session: SyncSession) {
        sessions.append(session)
    }

    private func setPaused(_ paused: Bool, identifier: String) {
        guard let index = sessions.firstIndex(where: { $0.identifier == identifier }) else { return }
        let session = sessions[index]
        sessions[index] = makeSyncSession(
            id: identifier, name: session.name, paused: paused, alpha: session.alpha, beta: session.beta
        )
    }
}
