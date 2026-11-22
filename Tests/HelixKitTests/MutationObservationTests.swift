// ABOUTME: Tests recovery when a Mutagen command loses its receipt.
// ABOUTME: Runs the session store and CLI against a stateful command fixture.

import Foundation
import Testing
@testable import HelixKit

@MainActor
struct MutationObservationTests {
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
        let store = SessionStore(provider: commands.cli, defaults: fixture.defaults)

        await store.refresh()

        #expect(await commands.sessions.map(\.paused) == [false, true])
        #expect(store.bulkPause == pause)
        #expect(store.lastError?.contains("while \"Original\" is running on the same endpoints") == true)
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

private actor MutationCommands {
    enum Interruption {
        case none, pauseSucceeded, pauseFailed, recoveryLeavesReplacementRunning
    }

    static let replacementID = "sync_" + String(repeating: "R", count: 43)
    let interruption: Interruption
    private let stopGate: Gate?
    private(set) var calls: [[String]] = []
    private(set) var sessions: [SyncSession]

    init(sessions: [SyncSession] = [], interruption: Interruption = .none, stopGate: Gate? = nil) {
        self.sessions = sessions
        self.interruption = interruption
        self.stopGate = stopGate
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
            sessions.append(makeSyncSession(id: Self.replacementID, name: "Edited Project", paused: true))
            return "Created session \(Self.replacementID)"
        case ["sync", "pause"]:
            if identifier == Self.replacementID && interruption == .recoveryLeavesReplacementRunning { break }
            if interruption != .pauseFailed { setPaused(true, identifier: identifier) }
            if interruption == .pauseSucceeded || interruption == .pauseFailed { throw timeout }
        case ["sync", "resume"]:
            if identifier == Self.replacementID && interruption == .recoveryLeavesReplacementRunning {
                throw CLIError(exitCode: 1, stderr: "The exit receipt was lost.")
            }
            setPaused(false, identifier: identifier)
        case ["sync", "terminate"]:
            if identifier == Self.replacementID && interruption == .recoveryLeavesReplacementRunning {
                setPaused(false, identifier: identifier)
                throw CLIError(exitCode: 1, stderr: "The session could not be removed.")
            }
            sessions.removeAll { $0.identifier == identifier }
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
