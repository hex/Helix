// ABOUTME: Tests recovery when a Mutagen command loses its receipt.
// ABOUTME: Runs the session store and CLI against a stateful command fixture.

import Foundation
import Testing
@testable import HelixKit

@MainActor
struct MutationObservationTests {
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

    private func setPaused(_ paused: Bool, identifier: String) {
        guard let index = sessions.firstIndex(where: { $0.identifier == identifier }) else { return }
        let session = sessions[index]
        sessions[index] = makeSyncSession(
            id: identifier, name: session.name, paused: paused, alpha: session.alpha, beta: session.beta
        )
    }
}
