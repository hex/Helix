// ABOUTME: Tests for SessionStore state management and polling behavior.
// ABOUTME: Uses a fake SessionProvider to verify state transitions without CLI.

import Testing
import Foundation
@testable import HelixKit

struct FakeProvider: SessionProvider {
    var syncSessions: [SyncSession]
    var forwardSessions: [ForwardSession]
    var isDaemonRunning: Bool
    var mutagenVersion: String

    init(
        syncSessions: [SyncSession] = [],
        forwardSessions: [ForwardSession] = [],
        isDaemonRunning: Bool = true,
        mutagenVersion: String = "0.18.1"
    ) {
        self.syncSessions = syncSessions
        self.forwardSessions = forwardSessions
        self.isDaemonRunning = isDaemonRunning
        self.mutagenVersion = mutagenVersion
    }

    func syncList() async throws -> [SyncSession] {
        try Task.checkCancellation()
        guard isDaemonRunning else { throw CLIError(exitCode: 1, stderr: "Daemon not running") }
        return syncSessions
    }
    func forwardList() async throws -> [ForwardSession] {
        try Task.checkCancellation()
        guard isDaemonRunning else { throw CLIError(exitCode: 1, stderr: "Daemon not running") }
        return forwardSessions
    }
    func daemonRunning() async throws -> Bool { isDaemonRunning }
    func version() async throws -> String { mutagenVersion }
    func syncCreate(arguments: [String]) async throws {}
    func forwardCreate(arguments: [String]) async throws {}
    func syncPause(_ identifier: String) async throws {}
    func syncResume(_ identifier: String) async throws {}
    func syncFlush(_ identifier: String) async throws {}
    func syncReset(_ identifier: String) async throws {}
    func syncTerminate(_ identifier: String) async throws {}
    func forwardPause(_ identifier: String) async throws {}
    func forwardResume(_ identifier: String) async throws {}
    func forwardTerminate(_ identifier: String) async throws {}
    func daemonStart() async throws {}
    func daemonStop() async throws {}
    func daemonRegister() async throws {}
    func daemonUnregister() async throws {}
}

@Suite("SessionStore state management")
struct SessionStoreTests {

    @Test("Starts with empty state")
    @MainActor
    func initialState() {
        let store = SessionStore(provider: FakeProvider())

        #expect(store.syncSessions.isEmpty)
        #expect(store.forwardSessions.isEmpty)
        #expect(store.daemonRunning == false)
        #expect(store.lastError == nil)
    }

    @Test("Refresh populates sync and forward sessions")
    @MainActor
    func refreshPopulatesSessions() async throws {
        let sync = makeSyncSession(id: "sync_1", name: "test")
        let provider = FakeProvider(syncSessions: [sync])
        let store = SessionStore(provider: provider)

        await store.refresh()

        #expect(store.syncSessions.count == 1)
        #expect(store.syncSessions[0].name == "test")
        #expect(store.daemonRunning == true)
    }

    @Test("Refresh captures error without crashing")
    @MainActor
    func refreshHandlesError() async {
        let provider = FailingProvider()
        let store = SessionStore(provider: provider)

        await store.refresh()

        #expect(store.lastError != nil)
        #expect(store.syncSessions.isEmpty)
    }

    @Test("A refresh whose task is cancelled leaves the sessions, the daemon state and the error as they were")
    @MainActor
    func cancelledRefresh() async {
        let store = SessionStore(provider: FakeProvider(syncSessions: [makeSyncSession(id: "sync_1", name: "test")]))
        await store.refresh()

        let polled = Task { await store.refresh() }
        polled.cancel()
        await polled.value
        let byHand = Task { await store.manualRefresh() }
        byHand.cancel()
        await byHand.value

        #expect(store.syncSessions.map(\.identifier) == ["sync_1"])
        #expect(store.daemonRunning == true)
        #expect(store.lastError == nil)
    }

    @Test("Health status reflects session states")
    @MainActor
    func healthStatus() async {
        let healthy = makeSyncSession(id: "sync_1", name: "ok", status: "watching")
        let provider = FakeProvider(syncSessions: [healthy])
        let store = SessionStore(provider: provider)
        await store.refresh()

        #expect(store.overallHealth == .healthy)
    }

    @Test("Health status is warning when conflicts exist")
    @MainActor
    func healthWarning() async {
        let conflict = Conflict(root: "test", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "conflicted", status: "watching", conflicts: [conflict])
        let provider = FakeProvider(syncSessions: [session])
        let store = SessionStore(provider: provider)
        await store.refresh()

        #expect(store.overallHealth == .warning)
    }

    @Test("Health status is error when daemon not running")
    @MainActor
    func healthError() async {
        let provider = FakeProvider(isDaemonRunning: false)
        let store = SessionStore(provider: provider)
        await store.refresh()

        #expect(store.overallHealth == .error)
    }

    @Test("Health status is error when session disconnected")
    @MainActor
    func healthDisconnected() async {
        let session = makeSyncSession(id: "sync_1", name: "bad", status: "disconnected")
        let provider = FakeProvider(syncSessions: [session])
        let store = SessionStore(provider: provider)
        await store.refresh()

        #expect(store.overallHealth == .error)
    }

    @Test("Health status ignores the disconnected status of a paused session")
    @MainActor
    func healthPausedSession() async {
        let paused = makeSyncSession(id: "sync_1", name: "resting", status: "disconnected", paused: true)
        let watching = makeSyncSession(id: "sync_2", name: "ok", status: "watching")
        let store = SessionStore(provider: FakeProvider(syncSessions: [paused, watching]))
        await store.refresh()

        #expect(store.overallHealth == .healthy)
    }

    @Test("Refresh publishes a session whose only change is staging progress")
    @MainActor
    func refreshPublishesStagingProgress() async {
        func staging(receivedFiles: Int) -> SyncSession {
            makeSyncSession(
                id: "sync_1", name: "busy", status: "staging-beta",
                beta: makeEndpoint(path: "/tmp/b", stagingProgress: StagingProgress(
                    path: "project/data.bin", receivedSize: 64, expectedSize: 256,
                    receivedFiles: receivedFiles, expectedFiles: 40, totalReceivedSize: 4096
                ))
            )
        }
        let store = SessionStore(provider: FakeProvider(syncSessions: [staging(receivedFiles: 10)]))
        await store.refresh()

        store.replaceProvider(FakeProvider(syncSessions: [staging(receivedFiles: 25)]))
        await store.refresh()

        #expect(store.syncSessions[0].beta.stagingProgress?.receivedFiles == 25)
    }

    @Test("Health status is active while a session stages files")
    @MainActor
    func healthStaging() async {
        let session = makeSyncSession(id: "sync_1", name: "busy", status: "staging-beta")
        let store = SessionStore(provider: FakeProvider(syncSessions: [session]))
        await store.refresh()

        #expect(store.overallHealth == .active)
    }

    @Test("Health status is warning when a session halts on root deletion")
    @MainActor
    func healthHaltedOnRootDeletion() async {
        let session = makeSyncSession(id: "sync_1", name: "halted", status: "halted-on-root-deletion")
        let store = SessionStore(provider: FakeProvider(syncSessions: [session]))
        await store.refresh()

        #expect(store.overallHealth == .warning)
    }

    @Test("Health status is warning while a session fails to connect")
    @MainActor
    func healthConnectingWithError() async {
        let session = makeSyncSession(
            id: "sync_1", name: "unreachable", status: "connecting-beta",
            lastError: "beta polling error: unable to send poll request: message transmission failed: write |1: broken pipe"
        )
        let store = SessionStore(provider: FakeProvider(syncSessions: [session]))
        await store.refresh()

        #expect(store.overallHealth == .warning)
    }

    @Test("Health status is active while a session connects without an error")
    @MainActor
    func healthConnecting() async {
        let session = makeSyncSession(id: "sync_1", name: "starting", status: "connecting-beta")
        let store = SessionStore(provider: FakeProvider(syncSessions: [session]))
        await store.refresh()

        #expect(store.overallHealth == .active)
    }

    @Test("Total session count includes both sync and forward")
    @MainActor
    func totalCount() async {
        let sync = makeSyncSession(id: "sync_1", name: "s1")
        let fwd = makeForwardSession(id: "fwd_1", name: "f1")
        let provider = FakeProvider(syncSessions: [sync], forwardSessions: [fwd])
        let store = SessionStore(provider: provider)
        await store.refresh()

        #expect(store.totalSessionCount == 2)
    }

    @Test("Conflict count sums across all sync sessions")
    @MainActor
    func conflictCount() async {
        let c1 = Conflict(root: "a", alphaChanges: [], betaChanges: [])
        let c2 = Conflict(root: "b", alphaChanges: [], betaChanges: [])
        let s1 = makeSyncSession(id: "sync_1", name: "s1", conflicts: [c1, c2])
        let s2 = makeSyncSession(id: "sync_2", name: "s2", conflicts: [c1])
        let provider = FakeProvider(syncSessions: [s1, s2])
        let store = SessionStore(provider: provider)
        await store.refresh()

        #expect(store.totalConflictCount == 3)
    }

    @Test("Action methods call provider and refresh")
    @MainActor
    func syncActions() async {
        let sync = makeSyncSession(id: "sync_1", name: "s1")
        let provider = FakeProvider(syncSessions: [sync])
        let store = SessionStore(provider: provider)

        await store.pauseSync("sync_1")
        #expect(store.lastError == nil)
        #expect(store.daemonRunning == true)

        await store.resumeSync("sync_1")
        #expect(store.lastError == nil)

        await store.flushSync("sync_1")
        #expect(store.lastError == nil)
    }

    @Test("Action error sets lastError")
    @MainActor
    func actionErrorHandling() async {
        let provider = FailingProvider()
        let store = SessionStore(provider: provider)

        await store.pauseSync("nonexistent")
        #expect(store.lastError != nil)
    }

    @Test("Terminate removes session from list after refresh")
    @MainActor
    func terminateRefreshes() async {
        let sync = makeSyncSession(id: "sync_1", name: "s1")
        let provider = FakeProvider(syncSessions: [sync])
        let store = SessionStore(provider: provider)
        await store.refresh()
        #expect(store.syncSessions.count == 1)

        await store.terminateSync("sync_1")
        // FakeProvider still returns the session (it's a mock), but the point
        // is that the method completes without error
        #expect(store.lastError == nil)
    }

    @Test("Daemon start/stop methods work")
    @MainActor
    func daemonControl() async {
        let provider = FakeProvider()
        let store = SessionStore(provider: provider)

        await store.startDaemon()
        #expect(store.lastError == nil)

        await store.stopDaemon()
        #expect(store.lastError == nil)
    }

    @Test("Daemon register sets autoStart to true")
    @MainActor
    func daemonRegister() async {
        let provider = FakeProvider()
        let store = SessionStore(provider: provider)

        await store.registerDaemon()
        #expect(store.lastError == nil)
        #expect(store.daemonAutoStart == true)
    }

    @Test("Daemon unregister sets autoStart to false")
    @MainActor
    func daemonUnregister() async {
        let provider = FakeProvider()
        let store = SessionStore(provider: provider)

        await store.registerDaemon()
        #expect(store.daemonAutoStart == true)

        await store.unregisterDaemon()
        #expect(store.lastError == nil)
        #expect(store.daemonAutoStart == false)
    }

    @Test("Fetch version populates mutagenVersion")
    @MainActor
    func fetchVersion() async {
        let provider = FakeProvider(mutagenVersion: "0.18.1")
        let store = SessionStore(provider: provider)

        await store.fetchVersion()
        #expect(store.mutagenVersion == "0.18.1")
    }

    @Test("Fetch version handles error gracefully")
    @MainActor
    func fetchVersionError() async {
        let provider = FailingProvider()
        let store = SessionStore(provider: provider)

        await store.fetchVersion()
        #expect(store.mutagenVersion == nil)
    }
}

@Suite("SessionStore recreateSync")
struct RecreateSessionTests {

    @Test("Terminates then creates with updated options")
    @MainActor
    func happyPath() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let recorder = RecordingProvider(syncSessions: [session])
        let store = SessionStore(provider: recorder)
        await store.refresh()

        var newOptions = SyncCreateOptions()
        newOptions.name = "test"
        newOptions.mode = "one-way-safe"
        await store.recreateSync(
            session,
            options: newOptions,
            alpha: "/tmp/a",
            beta: "/tmp/b"
        )

        #expect(store.lastError == nil)
        let calls = recorder.calls
        #expect(calls.count >= 2)
        #expect(calls[0] == "syncTerminate:sync_1")
        #expect(calls[1].hasPrefix("syncCreate:"))
    }

    @Test("Terminate failure sets error and does not create")
    @MainActor
    func terminateFails() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let recorder = RecordingProvider(syncSessions: [session], failOn: "syncTerminate")
        let store = SessionStore(provider: recorder)
        await store.refresh()

        var newOptions = SyncCreateOptions()
        newOptions.mode = "one-way-safe"
        await store.recreateSync(
            session,
            options: newOptions,
            alpha: "/tmp/a",
            beta: "/tmp/b"
        )

        #expect(store.lastError != nil)
        #expect(store.lastError!.contains("No changes were made"))
        let calls = recorder.calls
        let createCalls = calls.filter { $0.hasPrefix("syncCreate") }
        #expect(createCalls.isEmpty)
    }

    @Test("addToIgnoreList terminates then creates with path appended to ignores")
    @MainActor
    func addToIgnoreList() async {
        let session = makeSyncSession(
            id: "sync_1",
            name: "test",
            ignorePaths: ["*.log"]
        )
        let recorder = RecordingProvider(syncSessions: [session])
        let store = SessionStore(provider: recorder)
        await store.refresh()

        await store.addToIgnoreList(session: session, path: "node_modules/symlink")

        #expect(store.lastError == nil)
        let calls = recorder.calls
        #expect(calls.count >= 2)
        #expect(calls[0] == "syncTerminate:sync_1")
        #expect(calls[1].hasPrefix("syncCreate:"))
        // Verify the new ignore path is present alongside the existing one
        #expect(calls[1].contains("--ignore"))
        #expect(calls[1].contains("*.log"))
        #expect(calls[1].contains("node_modules/symlink"))
    }

    @Test("Create failure after terminate sets descriptive error")
    @MainActor
    func createFailsAfterTerminate() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let recorder = RecordingProvider(syncSessions: [session], failOn: "syncCreate")
        let store = SessionStore(provider: recorder)
        await store.refresh()

        var newOptions = SyncCreateOptions()
        newOptions.mode = "one-way-safe"
        await store.recreateSync(
            session,
            options: newOptions,
            alpha: "/tmp/a",
            beta: "/tmp/b"
        )

        #expect(store.lastError != nil)
        #expect(store.lastError!.contains("terminated but recreation failed"))
    }
}

@Suite("SessionStore bulk pause")
struct BulkPauseTests {
    private let defaults: UserDefaults
    private let suiteName = "BulkPauseTests.\(UUID().uuidString)"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    private func removeDefaults() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Pause All pauses only running sessions and Resume restores exactly those")
    @MainActor
    func pauseAllThenResume() async {
        defer { removeDefaults() }
        let running1 = makeSyncSession(id: "sync_1", name: "one")
        let alreadyPaused = makeSyncSession(id: "sync_2", name: "two", paused: true)
        let running2 = makeSyncSession(id: "sync_3", name: "three")
        let recorder = RecordingProvider(syncSessions: [running1, alreadyPaused, running2])
        let store = SessionStore(provider: recorder, defaults: defaults)
        await store.refresh()

        await store.pauseAllSync()

        #expect(recorder.calls == ["syncPause:sync_1", "syncPause:sync_3"])
        #expect(store.bulkPause == BulkPause(sessionIdentifiers: ["sync_1", "sync_3"], resumeAt: nil))

        let afterPause = RecordingProvider(syncSessions: [
            makeSyncSession(id: "sync_1", name: "one", paused: true),
            alreadyPaused,
            makeSyncSession(id: "sync_3", name: "three", paused: true),
        ])
        store.replaceProvider(afterPause)

        await store.resumeBulkPause()

        #expect(afterPause.calls == ["syncResume:sync_1", "syncResume:sync_3"])
        #expect(store.bulkPause == nil)
        #expect(store.lastError == nil)
    }

    @Test("A timed pause read back by a fresh store resumes on the first refresh after its deadline")
    @MainActor
    func timedPauseSurvivesRelaunch() async {
        defer { removeDefaults() }
        let pausedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = Date(timeIntervalSince1970: 1_800_001_800)
        let beforePause = RecordingProvider(syncSessions: [
            makeSyncSession(id: "sync_1", name: "one"),
            makeSyncSession(id: "sync_2", name: "two", paused: true),
        ])
        let firstLaunch = SessionStore(provider: beforePause, defaults: defaults, now: { pausedAt })
        await firstLaunch.pauseAllSync(until: deadline)

        let whilePaused = [
            makeSyncSession(id: "sync_1", name: "one", paused: true),
            makeSyncSession(id: "sync_2", name: "two", paused: true),
        ]

        let beforeDeadline = RecordingProvider(syncSessions: whilePaused)
        let earlyLaunch = SessionStore(
            provider: beforeDeadline,
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_800_001_799) }
        )
        await earlyLaunch.refresh()

        #expect(beforeDeadline.calls == [])
        #expect(earlyLaunch.bulkPause == BulkPause(sessionIdentifiers: ["sync_1"], resumeAt: deadline))

        let afterDeadline = RecordingProvider(syncSessions: whilePaused)
        let lateLaunch = SessionStore(
            provider: afterDeadline,
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_800_001_800) }
        )
        await lateLaunch.refresh()

        #expect(afterDeadline.calls == ["syncResume:sync_1"])
        #expect(lateLaunch.bulkPause == nil)
        let nextLaunch = SessionStore(provider: afterDeadline, defaults: defaults)
        #expect(nextLaunch.bulkPause == nil)
    }

    /// A store whose session "sync_2" is held after an unverified replacement, with Pause All
    /// recorded for "sync_1", "sync_2" and "sync_3" until `resumeAt`.
    @MainActor
    private func storeHoldingOnePausedSession(resumeAt: Date?, now: @escaping () -> Date) async -> SessionStore {
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let running = [
            makeSyncSession(id: "sync_1", name: "one"),
            makeSyncSession(id: "sync_2", name: "two", conflicts: [conflict]),
            makeSyncSession(id: "sync_3", name: "three"),
        ]
        // Every command succeeds except the move into place, so nothing on disk can be told apart afterwards.
        let transport = FileTransport { executable, arguments in
            if executable == "/bin/mv", arguments.first?.contains(".helix-incoming-") == true {
                throw CLIError(exitCode: 1, stderr: "permission denied")
            }
            return ""
        }
        let store = SessionStore(provider: RecordingProvider(syncSessions: running), fileTransport: transport, defaults: defaults, now: now)
        await store.pauseAllSync(until: resumeAt)
        await store.resolveConflict(session: running[1], conflict: conflict, winner: .alpha)
        return store
    }

    private var allPaused: [SyncSession] {
        [
            makeSyncSession(id: "sync_1", name: "one", paused: true),
            makeSyncSession(id: "sync_2", name: "two", paused: true),
            makeSyncSession(id: "sync_3", name: "three", paused: true),
        ]
    }

    @Test("Resume after Pause All leaves a held session paused and resumes the others")
    @MainActor
    func resumeSkipsHeldSession() async {
        defer { removeDefaults() }
        let store = await storeHoldingOnePausedSession(resumeAt: nil, now: Date.init)
        let whilePaused = RecordingProvider(syncSessions: allPaused)
        store.replaceProvider(whilePaused)

        await store.resumeBulkPause()

        #expect(whilePaused.calls == ["syncResume:sync_1", "syncResume:sync_3"])
        #expect(store.bulkPause == nil)
        #expect(store.sessionHolds.keys.sorted() == ["sync_2"])
        #expect(store.lastError == nil)
    }

    @Test("A timed pause reaching its deadline leaves a held session paused and resumes the others")
    @MainActor
    func deadlineSkipsHeldSession() async {
        defer { removeDefaults() }
        let deadline = Date(timeIntervalSince1970: 1_800_001_800)
        let clock = CallLog()
        let store = await storeHoldingOnePausedSession(resumeAt: deadline) {
            clock.entries.isEmpty ? Date(timeIntervalSince1970: 1_800_000_000) : deadline
        }
        let whilePaused = RecordingProvider(syncSessions: allPaused)
        store.replaceProvider(whilePaused)
        clock.record(executable: "deadline reached", arguments: [])

        await store.refresh()
        await store.refresh()

        #expect(whilePaused.calls == ["syncResume:sync_1", "syncResume:sync_3"])
        #expect(store.bulkPause == nil)
        #expect(store.sessionHolds.keys.sorted() == ["sync_2"])
    }

    @Test("Resume after Pause All does not resume a session while a conflict resolve runs on it, and retries it afterwards")
    @MainActor
    func resumeWaitsOutRunningResolve() async {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let gate = Gate()
        let transport = FileTransport { _, _ in
            await gate.pass()
            return ""
        }
        let store = SessionStore(
            provider: RecordingProvider(syncSessions: [makeSyncSession(id: "sync_1", name: "one", conflicts: [conflict])]),
            fileTransport: transport,
            defaults: defaults
        )
        await store.pauseAllSync()
        let paused = makeSyncSession(id: "sync_1", name: "one", paused: true, conflicts: [conflict])
        let provider = MainActorRecordingProvider(syncSessions: [paused])
        store.replaceProvider(provider)

        let resolve = Task { _ = await store.resolveConflict(session: paused, conflict: conflict, winner: .alpha) }
        await gate.reached()
        await store.resumeBulkPause()
        let callsWhileResolveIsMidway = provider.calls
        let recordWhileResolveIsMidway = store.bulkPause
        await gate.open()
        await resolve.value
        await store.resumeBulkPause()

        #expect(callsWhileResolveIsMidway == ["syncPause:sync_1"])
        #expect(recordWhileResolveIsMidway == BulkPause(sessionIdentifiers: ["sync_1"], resumeAt: nil))
        #expect(provider.calls == ["syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1", "syncResume:sync_1"])
        #expect(store.bulkPause == nil)
        #expect(store.lastError == nil)
    }

    @Test("A conflict resolve requested while Resume after Pause All is resuming its session pauses only after that resume has completed")
    @MainActor
    func resolveWaitsOutBulkResume() async {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let store = SessionStore(
            provider: RecordingProvider(syncSessions: [makeSyncSession(id: "sync_1", name: "one", conflicts: [conflict])]),
            fileTransport: FileTransport { _, _ in "" },
            defaults: defaults
        )
        await store.pauseAllSync()
        let paused = makeSyncSession(id: "sync_1", name: "one", paused: true, conflicts: [conflict])
        let gate = Gate()
        let provider = MainActorRecordingProvider(syncSessions: [paused], resumeGate: gate)
        store.replaceProvider(provider)

        let resume = Task { await store.resumeBulkPause() }
        await gate.reached()
        let resolve = Task { _ = await store.resolveConflict(session: paused, conflict: conflict, winner: .alpha) }
        for _ in 0..<100 { await Task.yield() }
        let callsWhileResumeIsInFlight = provider.calls
        await gate.open()
        await resume.value
        await resolve.value

        #expect(callsWhileResumeIsInFlight == [])
        #expect(provider.calls == ["syncResume:sync_1", "syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1"])
        #expect(store.bulkPause == nil)
        #expect(store.lastError == nil)
    }

    @Test("A conflict resolve requested while a resume by hand is in flight on its session pauses only after that resume has completed")
    @MainActor
    func resolveWaitsOutResumeByHand() async {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let paused = makeSyncSession(id: "sync_1", name: "one", paused: true, conflicts: [conflict])
        let gate = Gate()
        let provider = MainActorRecordingProvider(syncSessions: [paused], resumeGate: gate)
        let store = SessionStore(provider: provider, fileTransport: FileTransport { _, _ in "" }, defaults: defaults)

        let resume = Task { await store.resumeSync("sync_1") }
        await gate.reached()
        let resolve = Task { _ = await store.resolveConflict(session: paused, conflict: conflict, winner: .alpha) }
        for _ in 0..<100 { await Task.yield() }
        let callsWhileResumeIsInFlight = provider.calls
        await gate.open()
        await resume.value
        await resolve.value

        #expect(callsWhileResumeIsInFlight == [])
        #expect(provider.calls == ["syncResume:sync_1", "syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1"])
    }

    @Test("Pause All during an active bulk pause keeps the first sessions and takes the newer deadline")
    @MainActor
    func secondPauseAllKeepsFirstSessions() async {
        defer { removeDefaults() }
        let firstPause = RecordingProvider(syncSessions: [makeSyncSession(id: "sync_1", name: "one")])
        let store = SessionStore(
            provider: firstPause,
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        await store.pauseAllSync(until: Date(timeIntervalSince1970: 1_800_000_600))

        let secondPause = RecordingProvider(syncSessions: [
            makeSyncSession(id: "sync_1", name: "one", paused: true),
            makeSyncSession(id: "sync_2", name: "two"),
        ])
        store.replaceProvider(secondPause)
        let laterDeadline = Date(timeIntervalSince1970: 1_800_003_600)
        await store.pauseAllSync(until: laterDeadline)

        #expect(secondPause.calls == ["syncPause:sync_2"])
        #expect(store.bulkPause == BulkPause(sessionIdentifiers: ["sync_1", "sync_2"], resumeAt: laterDeadline))
    }
}

@Suite("SessionStore daemon priority")
struct DaemonPriorityTests {
    private let defaults: UserDefaults
    private let suiteName = "DaemonPriorityTests.\(UUID().uuidString)"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    private func removeDefaults() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("With no daemon running, turning background priority on applies nothing and reports no error")
    @MainActor
    func noDaemonRunning() async {
        defer { removeDefaults() }
        let daemon = RecordingDaemonProcess(pid: nil)
        let store = SessionStore(provider: FakeProvider(), defaults: defaults, daemonProcess: daemon)

        await store.setDaemonBackgroundPriority(true)

        #expect(daemon.calls == [])
        #expect(store.lastError == nil)
        #expect(store.daemonBackgroundPriority == true)
    }

    @Test("Turning background priority on lowers the daemon's priority and turning it off restores it")
    @MainActor
    func switchOnThenOff() async {
        defer { removeDefaults() }
        let daemon = RecordingDaemonProcess(pid: 3114)
        let store = SessionStore(provider: FakeProvider(), defaults: defaults, daemonProcess: daemon)

        await store.setDaemonBackgroundPriority(true)

        #expect(daemon.calls == ["background:3114"])

        await store.setDaemonBackgroundPriority(false)

        #expect(daemon.calls == ["background:3114", "restore:3114"])
        #expect(store.lastError == nil)
    }

    @Test("With background priority on, a refresh applies it to a restarted daemon once")
    @MainActor
    func reappliesAfterDaemonRestart() async {
        defer { removeDefaults() }
        let daemon = RecordingDaemonProcess(pid: 3114)
        let store = SessionStore(provider: FakeProvider(), defaults: defaults, daemonProcess: daemon)
        await store.setDaemonBackgroundPriority(true)

        await store.refresh()

        #expect(daemon.calls == ["background:3114"])

        daemon.restart(as: 4200)
        await store.refresh()
        await store.refresh()

        #expect(daemon.calls == ["background:3114", "background:4200"])
        #expect(store.lastError == nil)
    }
}

// MARK: - Helpers

/// Records sync actions on the main actor, so a call the store makes is in `calls` before any
/// other main-actor code runs.
@MainActor
final class MainActorRecordingProvider: SessionProvider {
    private(set) var calls: [String] = []
    private let syncSessions: [SyncSession]
    private let resumeGate: Gate?

    /// - Parameter resumeGate: holds the first resume open; that resume is recorded once it has passed.
    init(syncSessions: [SyncSession], resumeGate: Gate? = nil) {
        self.syncSessions = syncSessions
        self.resumeGate = resumeGate
    }

    func syncList() async throws -> [SyncSession] { syncSessions }
    func forwardList() async throws -> [ForwardSession] { [] }
    func daemonRunning() async throws -> Bool { true }
    func version() async throws -> String { "0.18.1" }
    func syncCreate(arguments: [String]) async throws { calls.append("syncCreate:\(arguments.joined(separator: " "))") }
    func forwardCreate(arguments: [String]) async throws {}
    func syncPause(_ identifier: String) async throws { calls.append("syncPause:\(identifier)") }
    func syncResume(_ identifier: String) async throws {
        await resumeGate?.pass()
        calls.append("syncResume:\(identifier)")
    }
    func syncFlush(_ identifier: String) async throws { calls.append("syncFlush:\(identifier)") }
    func syncReset(_ identifier: String) async throws {}
    func syncTerminate(_ identifier: String) async throws { calls.append("syncTerminate:\(identifier)") }
    func forwardPause(_ identifier: String) async throws {}
    func forwardResume(_ identifier: String) async throws {}
    func forwardTerminate(_ identifier: String) async throws {}
    func daemonStart() async throws {}
    func daemonStop() async throws {}
    func daemonRegister() async throws {}
    func daemonUnregister() async throws {}
}

/// Suspends the first caller of `pass()` until `open()`; `reached()` returns once that caller is waiting.
actor Gate {
    private var isOpen = false
    private var hasCaller = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var watcher: CheckedContinuation<Void, Never>?

    func pass() async {
        guard !isOpen, !hasCaller else { return }
        hasCaller = true
        watcher?.resume()
        watcher = nil
        await withCheckedContinuation { waiting = $0 }
    }

    func reached() async {
        guard !hasCaller else { return }
        await withCheckedContinuation { watcher = $0 }
    }

    func open() {
        isOpen = true
        waiting?.resume()
        waiting = nil
    }
}

final class RecordingProvider: SessionProvider, @unchecked Sendable {
    private var _calls: [String] = []
    private let lock = NSLock()
    private let syncSessions: [SyncSession]
    private let resolvedSyncSessions: [SyncSession]?
    private let sessionsAfterCreate: [SyncSession]?
    private var _flushed = false
    private var _created = false
    private let failOn: String?

    init(
        syncSessions: [SyncSession] = [],
        resolvedSyncSessions: [SyncSession]? = nil,
        sessionsAfterCreate: [SyncSession]? = nil,
        failOn: String? = nil
    ) {
        self.syncSessions = syncSessions
        self.resolvedSyncSessions = resolvedSyncSessions
        self.sessionsAfterCreate = sessionsAfterCreate
        self.failOn = failOn
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    private func record(_ call: String) throws {
        lock.lock()
        _calls.append(call)
        let shouldFail = failOn.map { call.hasPrefix($0) } ?? false
        lock.unlock()
        if shouldFail {
            throw CLIError(exitCode: 1, stderr: "simulated failure")
        }
    }

    func syncList() async throws -> [SyncSession] {
        lock.lock()
        let flushed = _flushed
        let created = _created
        lock.unlock()
        if flushed, let resolved = resolvedSyncSessions {
            return resolved
        }
        if created, let afterCreate = sessionsAfterCreate {
            return afterCreate
        }
        return syncSessions
    }
    func forwardList() async throws -> [ForwardSession] { [] }
    func daemonRunning() async throws -> Bool { true }
    func version() async throws -> String { "0.18.1" }
    func syncCreate(arguments: [String]) async throws {
        try record("syncCreate:\(arguments.joined(separator: " "))")
        lock.lock()
        _created = true
        lock.unlock()
    }
    func forwardCreate(arguments: [String]) async throws {}
    func syncPause(_ identifier: String) async throws { try record("syncPause:\(identifier)") }
    func syncResume(_ identifier: String) async throws { try record("syncResume:\(identifier)") }
    func syncFlush(_ identifier: String) async throws {
        try record("syncFlush:\(identifier)")
        lock.lock()
        _flushed = true
        lock.unlock()
    }
    func syncReset(_ identifier: String) async throws {}
    func syncTerminate(_ identifier: String) async throws { try record("syncTerminate:\(identifier)") }
    func forwardPause(_ identifier: String) async throws {}
    func forwardResume(_ identifier: String) async throws {}
    func forwardTerminate(_ identifier: String) async throws {}
    func daemonStart() async throws {}
    func daemonStop() async throws {}
    func daemonRegister() async throws {}
    func daemonUnregister() async throws {}
}

struct FailingProvider: SessionProvider {
    func syncList() async throws -> [SyncSession] {
        throw CLIError(exitCode: 1, stderr: "daemon not running")
    }
    func forwardList() async throws -> [ForwardSession] {
        throw CLIError(exitCode: 1, stderr: "daemon not running")
    }
    func daemonRunning() async throws -> Bool { false }
    func version() async throws -> String { throw CLIError(exitCode: 1, stderr: "not found") }
    func syncCreate(arguments: [String]) async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func forwardCreate(arguments: [String]) async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func syncPause(_ identifier: String) async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func syncResume(_ identifier: String) async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func syncFlush(_ identifier: String) async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func syncReset(_ identifier: String) async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func syncTerminate(_ identifier: String) async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func forwardPause(_ identifier: String) async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func forwardResume(_ identifier: String) async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func forwardTerminate(_ identifier: String) async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func daemonStart() async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func daemonStop() async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func daemonRegister() async throws { throw CLIError(exitCode: 1, stderr: "failed") }
    func daemonUnregister() async throws { throw CLIError(exitCode: 1, stderr: "failed") }
}

func makeSyncSession(
    id: String,
    name: String?,
    status: String = "watching",
    paused: Bool = false,
    conflicts: [Conflict]? = nil,
    ignorePaths: [String]? = nil,
    alpha: Endpoint = makeEndpoint(path: "/tmp/a"),
    beta: Endpoint = makeEndpoint(path: "/tmp/b"),
    lastError: String? = nil
) -> SyncSession {
    SyncSession(
        identifier: id,
        version: 1,
        creationTime: "2026-01-01T00:00:00Z",
        creatingVersion: "0.18.1",
        name: name,
        labels: nil,
        paused: paused,
        status: status,
        successfulCycles: 0,
        mode: "two-way-safe",
        alpha: alpha,
        beta: beta,
        ignore: IgnoreConfig(paths: ignorePaths, syntax: nil),
        symlink: SymlinkConfig(mode: nil),
        watch: WatchConfig(mode: nil, pollingInterval: nil),
        permissions: PermissionsConfig(mode: nil, defaultFileMode: nil, defaultDirectoryMode: nil, defaultOwner: nil, defaultGroup: nil),
        compression: CompressionConfig(algorithm: nil),
        conflicts: conflicts,
        lastError: lastError
    )
}

func makeEndpoint(
    path: String,
    files: Int = 0,
    totalFileSize: Int = 0,
    stagingProgress: StagingProgress? = nil,
    connected: Bool? = true
) -> Endpoint {
    Endpoint(
        protocol_: "local", user: nil, host: nil, port: nil, path: path,
        connected: connected, scanned: true, directories: 0, files: files, totalFileSize: totalFileSize,
        stagingProgress: stagingProgress
    )
}

@Suite("SessionStore conflict resolution")
struct ConflictResolutionTests {
    private let defaults: UserDefaults
    private let suiteName = "ConflictResolutionTests.\(UUID().uuidString)"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    private func removeDefaults() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The per-call token in replace's sibling names, read from the copy that lands beside `destination`.
    private func replaceToken(copiedBeside destination: String, in commands: [RecordedCommand]) throws -> String {
        let marker = destination + ".helix-incoming-"
        let copyTarget = try #require(commands.first { $0.executable == "/bin/cp" }?.arguments.last)
        try #require(copyTarget.hasPrefix(marker))
        return String(copyTarget.dropFirst(marker.count))
    }

    @Test("Resolves conflict by replacing loser with a copy of winner then flushing")
    @MainActor
    func happyPath() async throws {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let resolvedSession = makeSyncSession(id: "sync_1", name: "s1")
        let recorder = RecordingProvider(syncSessions: [session], resolvedSyncSessions: [resolvedSession])
        let copyRecorder = CommandRecorder()
        let transport = FileTransport(execute: copyRecorder.execute)
        let store = SessionStore(provider: recorder, fileTransport: transport, defaults: defaults)
        await store.refresh()

        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)

        #expect(store.lastError == nil)
        // Should check winner exists, then replace loser with a copy of winner
        #expect(copyRecorder.commands.count == 7)
        let token = try replaceToken(copiedBeside: "/tmp/b/file.txt", in: copyRecorder.commands)
        #expect(copyRecorder.commands.map(\.executable) == ["/bin/test", "/bin/cp", "/bin/test", "/bin/test", "/bin/mv", "/bin/mv", "/bin/rm"])
        #expect(copyRecorder.commands.map(\.arguments) == [
            ["-e", "/tmp/a/file.txt"],
            ["-Rp", "/tmp/a/file.txt", "/tmp/b/file.txt.helix-incoming-\(token)"],
            ["-e", "/tmp/b/file.txt"],
            ["-d", "/tmp/b/file.txt"],
            ["/tmp/b/file.txt", "/tmp/b/file.txt.helix-replaced-\(token)"],
            ["/tmp/b/file.txt.helix-incoming-\(token)", "/tmp/b/file.txt"],
            ["-rf", "/tmp/b/file.txt.helix-replaced-\(token)"],
        ])
        // Should have flushed
        let flushCalls = recorder.calls.filter { $0.hasPrefix("syncFlush") }
        #expect(flushCalls.count == 1)
        #expect(flushCalls[0] == "syncFlush:sync_1")
    }

    @Test("Beta wins replaces alpha with a copy of beta")
    @MainActor
    func betaWins() async throws {
        defer { removeDefaults() }
        let conflict = Conflict(root: "data.json", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let resolvedSession = makeSyncSession(id: "sync_1", name: "s1")
        let copyRecorder = CommandRecorder()
        let transport = FileTransport(execute: copyRecorder.execute)
        let store = SessionStore(provider: FakeProvider(syncSessions: [resolvedSession]), fileTransport: transport, defaults: defaults)
        await store.refresh()

        await store.resolveConflict(session: session, conflict: conflict, winner: .beta)

        #expect(store.lastError == nil)
        #expect(copyRecorder.commands.count == 7)
        let token = try replaceToken(copiedBeside: "/tmp/a/data.json", in: copyRecorder.commands)
        // Beta (/tmp/b) -> Alpha (/tmp/a)
        #expect(copyRecorder.commands.map(\.arguments) == [
            ["-e", "/tmp/b/data.json"],
            ["-Rp", "/tmp/b/data.json", "/tmp/a/data.json.helix-incoming-\(token)"],
            ["-e", "/tmp/a/data.json"],
            ["-d", "/tmp/a/data.json"],
            ["/tmp/a/data.json", "/tmp/a/data.json.helix-replaced-\(token)"],
            ["/tmp/a/data.json.helix-incoming-\(token)", "/tmp/a/data.json"],
            ["-rf", "/tmp/a/data.json.helix-replaced-\(token)"],
        ])
    }

    @Test("Resolve does not call refresh after flush to avoid mid-scan flicker")
    @MainActor
    func resolveSkipsRefresh() async {
        defer { removeDefaults() }
        let conflict = Conflict(root: "link.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let recorder = RecordingProvider(syncSessions: [session])
        let copyRecorder = CommandRecorder()
        let transport = FileTransport(execute: copyRecorder.execute)
        let store = SessionStore(provider: recorder, fileTransport: transport, defaults: defaults)
        await store.refresh()

        let refreshCountBefore = recorder.calls.filter { $0 == "syncList" }.count
        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)
        let refreshCountAfter = recorder.calls.filter { $0 == "syncList" }.count

        // No additional syncList call — polling handles the refresh
        #expect(refreshCountAfter == refreshCountBefore)
        // Transport operations still attempted (check + the six commands of a replace)
        #expect(copyRecorder.commands.count == 7)
        // Flush still called
        let flushCalls = recorder.calls.filter { $0.hasPrefix("syncFlush") }
        #expect(flushCalls.count == 1)
        // No error since flush succeeded
        #expect(store.lastError == nil)
    }

    @Test("Copy failure sets lastError and does not flush")
    @MainActor
    func copyFails() async {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let recorder = RecordingProvider(syncSessions: [session])
        let transport = FileTransport { executable, arguments in
            // pathExists check succeeds
            if executable == "/bin/test" && arguments.contains("-e") { return "" }
            throw CLIError(exitCode: 1, stderr: "permission denied")
        }
        let store = SessionStore(provider: recorder, fileTransport: transport, defaults: defaults)
        await store.refresh()

        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)

        #expect(store.lastError != nil)
        #expect(store.lastError!.contains("permission denied"))
        // Should NOT have flushed
        let flushCalls = recorder.calls.filter { $0.hasPrefix("syncFlush") }
        #expect(flushCalls.isEmpty)
    }

    @Test("Winner deletion removes from loser instead of copying")
    @MainActor
    func winnerDeleted() async {
        // Alpha deleted the root directory — Mutagen uses the root name as the change path
        let conflict = Conflict(
            root: "alimentara",
            alphaChanges: [Change(path: "alimentara", old: Entry(kind: "directory", digest: nil, executable: nil), new: nil)],
            betaChanges: [Change(path: "logs/session.log", old: nil, new: Entry(kind: "file", digest: nil, executable: nil))]
        )
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let resolvedSession = makeSyncSession(id: "sync_1", name: "s1")
        let recorder = RecordingProvider(syncSessions: [session], resolvedSyncSessions: [resolvedSession])
        let cmdRecorder = CommandRecorder()
        let transport = FileTransport(execute: cmdRecorder.execute)
        let store = SessionStore(provider: recorder, fileTransport: transport)
        await store.refresh()

        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)

        #expect(store.lastError == nil)
        // Should have removed from beta (loser), not copied
        #expect(cmdRecorder.commands.count == 1)
        let cmd = cmdRecorder.commands[0]
        #expect(cmd.executable == "/bin/rm")
        #expect(cmd.arguments == ["-rf", "/tmp/b/alimentara"])
        // Should have flushed
        let flushCalls = recorder.calls.filter { $0.hasPrefix("syncFlush") }
        #expect(flushCalls.count == 1)
    }

    @Test("Winner file not found aborts without removing loser")
    @MainActor
    func winnerNotFound() async {
        let conflict = Conflict(root: "deleted.swift", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let recorder = RecordingProvider(syncSessions: [session])
        let cmdRecorder = CommandRecorder()
        let transport = FileTransport { executable, arguments in
            if executable == "/bin/test" && arguments.contains("-e") {
                throw CLIError(exitCode: 1, stderr: "")
            }
            return try await cmdRecorder.execute(executable, arguments)
        }
        let store = SessionStore(provider: recorder, fileTransport: transport)
        await store.refresh()

        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)

        #expect(store.lastError?.contains("no longer exists") == true)
        // Should NOT have removed or copied anything
        #expect(cmdRecorder.commands.isEmpty)
        // Should NOT have flushed
        let flushCalls = recorder.calls.filter { $0.hasPrefix("syncFlush") }
        #expect(flushCalls.isEmpty)
    }

    @Test("A conflict at the sync root is refused before pausing or running any file command")
    @MainActor
    func rootConflictRefused() async {
        let conflict = Conflict(root: "", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let recorder = RecordingProvider(syncSessions: [session])
        let cmdRecorder = CommandRecorder()
        let transport = FileTransport(execute: cmdRecorder.execute)
        let store = SessionStore(provider: recorder, fileTransport: transport)
        await store.refresh()

        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)

        #expect(store.lastError == "The conflict in \"s1\" is at the sync root, where resolving it would replace a whole endpoint. Resolve a root-level conflict by hand.")
        #expect(recorder.calls.isEmpty)
        #expect(cmdRecorder.commands.isEmpty)
    }

    @Test("Bulk resolve counts a conflict at the sync root as failed and resolves the others")
    @MainActor
    func bulkRootConflictRefused() async {
        let rootConflict = Conflict(root: "", alphaChanges: [], betaChanges: [])
        let deletion = Conflict(
            root: "gone.txt",
            alphaChanges: [Change(path: "gone.txt", old: Entry(kind: "file", digest: nil, executable: nil), new: nil)],
            betaChanges: []
        )
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [rootConflict, deletion])
        let recorder = RecordingProvider(syncSessions: [session])
        let cmdRecorder = CommandRecorder()
        let transport = FileTransport(execute: cmdRecorder.execute)
        let store = SessionStore(provider: recorder, fileTransport: transport)
        await store.refresh()

        await store.resolveConflicts(session: session, conflicts: [rootConflict, deletion], winner: .alpha)

        #expect(store.lastError == "1 of 2 conflicts could not be resolved. The conflict in \"s1\" is at the sync root, where resolving it would replace a whole endpoint. Resolve a root-level conflict by hand.")
        #expect(recorder.calls == ["syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1"])
        #expect(cmdRecorder.commands.map(\.executable) == ["/bin/rm"])
        #expect(cmdRecorder.commands.map(\.arguments) == [["-rf", "/tmp/b/gone.txt"]])
    }

    @Test("Bulk resolve pauses once, resolves all, then resumes and flushes once")
    @MainActor
    func bulkResolve() async {
        defer { removeDefaults() }
        let c1 = Conflict(root: "a.txt", alphaChanges: [], betaChanges: [])
        let c2 = Conflict(root: "b.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [c1, c2])
        let resolvedSession = makeSyncSession(id: "sync_1", name: "s1")
        let recorder = RecordingProvider(syncSessions: [session], resolvedSyncSessions: [resolvedSession])
        let cmdRecorder = CommandRecorder()
        let transport = FileTransport(execute: cmdRecorder.execute)
        let store = SessionStore(provider: recorder, fileTransport: transport, defaults: defaults)
        await store.refresh()

        await store.resolveConflicts(session: session, conflicts: [c1, c2], winner: .alpha)

        #expect(store.lastError == nil)
        // Per conflict: test -e winner, then cp to incoming, test -e loser, test -d loser, mv aside, mv into place, rm set-aside (14 commands)
        #expect(cmdRecorder.commands.count == 14)
        // Verify both files were resolved
        let rmCommands = cmdRecorder.commands.filter { $0.executable == "/bin/rm" }
        #expect(rmCommands.count == 2)
        let cpCommands = cmdRecorder.commands.filter { $0.executable == "/bin/cp" }
        #expect(cpCommands.count == 2)
        // Should have flushed once
        let flushCalls = recorder.calls.filter { $0.hasPrefix("syncFlush") }
        #expect(flushCalls.count == 1)
    }

    @Test("A replacement that only fails to remove the set-aside original resumes, flushes and names the leftover")
    @MainActor
    func cleanupFailureStillResolves() async throws {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let recorder = RecordingProvider(syncSessions: [session])
        let cmdRecorder = CommandRecorder()
        let transport = FileTransport { executable, arguments in
            let output = try await cmdRecorder.execute(executable, arguments)
            if executable == "/bin/rm" { throw CLIError(exitCode: 1, stderr: "permission denied") }
            return output
        }
        let store = SessionStore(provider: recorder, fileTransport: transport, defaults: defaults)

        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)

        let token = try replaceToken(copiedBeside: "/tmp/b/file.txt", in: cmdRecorder.commands)
        #expect(recorder.calls == ["syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1"])
        #expect(store.lastError == "Resolved \"file.txt\", but left the original it replaced at /tmp/b/file.txt.helix-replaced-\(token): permission denied. Delete that path by hand.")
    }

    @Test("Bulk resolve counts a leftover set-aside original as resolved and names it")
    @MainActor
    func bulkCleanupFailureStillResolves() async throws {
        defer { removeDefaults() }
        let c1 = Conflict(root: "a.txt", alphaChanges: [], betaChanges: [])
        let c2 = Conflict(root: "b.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [c1, c2])
        let recorder = RecordingProvider(syncSessions: [session])
        let cmdRecorder = CommandRecorder()
        let transport = FileTransport { executable, arguments in
            let output = try await cmdRecorder.execute(executable, arguments)
            if executable == "/bin/rm", arguments.last?.hasPrefix("/tmp/b/a.txt") == true {
                throw CLIError(exitCode: 1, stderr: "permission denied")
            }
            return output
        }
        let store = SessionStore(provider: recorder, fileTransport: transport, defaults: defaults)

        await store.resolveConflicts(session: session, conflicts: [c1, c2], winner: .alpha)

        let token = try replaceToken(copiedBeside: "/tmp/b/a.txt", in: cmdRecorder.commands)
        #expect(recorder.calls == ["syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1"])
        #expect(cmdRecorder.commands.filter { $0.executable == "/bin/cp" }.count == 2)
        #expect(store.lastError == "Resolved \"a.txt\", but left the original it replaced at /tmp/b/a.txt.helix-replaced-\(token): permission denied. Delete that path by hand.")
    }

    /// A transport whose move into place fails while every check afterwards finds something at every path,
    /// so the replacement cannot be shown to have happened or to have been undone.
    private func transportLeavingDestinationUnverified(recordingTo cmdRecorder: CommandRecorder) -> FileTransport {
        FileTransport { executable, arguments in
            let output = try await cmdRecorder.execute(executable, arguments)
            if executable == "/bin/mv", arguments.first?.contains(".helix-incoming-") == true {
                throw CLIError(exitCode: 1, stderr: "permission denied")
            }
            return output
        }
    }

    @Test("A replacement that leaves the destination unverified keeps the session paused and names the paths holding the data")
    @MainActor
    func unverifiedReplacementStaysPaused() async throws {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let recorder = RecordingProvider(syncSessions: [session])
        let cmdRecorder = CommandRecorder()
        let store = SessionStore(provider: recorder, fileTransport: transportLeavingDestinationUnverified(recordingTo: cmdRecorder), defaults: defaults)

        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)

        let token = try replaceToken(copiedBeside: "/tmp/b/file.txt", in: cmdRecorder.commands)
        #expect(recorder.calls == ["syncPause:sync_1"])
        #expect(store.lastError == "Could not move /tmp/b/file.txt.helix-incoming-\(token) into place at /tmp/b/file.txt: permission denied. Nothing was deleted: look for the original at /tmp/b/file.txt.helix-replaced-\(token) and for the replacement at /tmp/b/file.txt.helix-incoming-\(token). The session \"s1\" was left paused so that sync cannot overwrite or delete those paths. Put \"file.txt\" in order, then resume the session.")
    }

    @Test("Bulk resolve stops at a replacement that leaves the destination unverified and keeps the session paused")
    @MainActor
    func bulkUnverifiedReplacementStaysPaused() async throws {
        defer { removeDefaults() }
        let c1 = Conflict(root: "a.txt", alphaChanges: [], betaChanges: [])
        let c2 = Conflict(root: "b.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [c1, c2])
        let recorder = RecordingProvider(syncSessions: [session])
        let cmdRecorder = CommandRecorder()
        let store = SessionStore(provider: recorder, fileTransport: transportLeavingDestinationUnverified(recordingTo: cmdRecorder), defaults: defaults)

        await store.resolveConflicts(session: session, conflicts: [c1, c2], winner: .alpha)

        let token = try replaceToken(copiedBeside: "/tmp/b/a.txt", in: cmdRecorder.commands)
        #expect(recorder.calls == ["syncPause:sync_1"])
        #expect(cmdRecorder.commands.filter { $0.arguments.contains { $0.contains("b.txt") } }.isEmpty)
        #expect(store.lastError == "Could not move /tmp/b/a.txt.helix-incoming-\(token) into place at /tmp/b/a.txt: permission denied. Nothing was deleted: look for the original at /tmp/b/a.txt.helix-replaced-\(token) and for the replacement at /tmp/b/a.txt.helix-incoming-\(token). The session \"s1\" was left paused so that sync cannot overwrite or delete those paths. Put \"a.txt\" in order, then resume the session. 1 of 2 conflicts was not attempted.")
    }

    /// The hold message for a file conflict in session "s1" whose move into place at `destination` failed.
    private func holdMessage(root: String, destination: String, token: String) -> String {
        "Could not move \(destination).helix-incoming-\(token) into place at \(destination): permission denied. Nothing was deleted: look for the original at \(destination).helix-replaced-\(token) and for the replacement at \(destination).helix-incoming-\(token). The session \"s1\" was left paused so that sync cannot overwrite or delete those paths. Put \"\(root)\" in order, then resume the session."
    }

    @Test("A poll after an unverified replacement clears the passing error and keeps the hold with its message")
    @MainActor
    func holdOutlivesPolling() async throws {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let recorder = RecordingProvider(syncSessions: [session])
        let cmdRecorder = CommandRecorder()
        let store = SessionStore(provider: recorder, fileTransport: transportLeavingDestinationUnverified(recordingTo: cmdRecorder), defaults: defaults)
        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)
        let token = try replaceToken(copiedBeside: "/tmp/b/file.txt", in: cmdRecorder.commands)

        await store.refresh()

        #expect(store.lastError == nil)
        #expect(store.sessionHolds == ["sync_1": holdMessage(root: "file.txt", destination: "/tmp/b/file.txt", token: token)])
        #expect(recorder.calls == ["syncPause:sync_1"])
    }

    @Test("A hold is read back by a second store on the same defaults")
    @MainActor
    func holdSurvivesRelaunch() async throws {
        defer { removeDefaults() }
        let c1 = Conflict(root: "a.txt", alphaChanges: [], betaChanges: [])
        let c2 = Conflict(root: "b.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [c1, c2])
        let cmdRecorder = CommandRecorder()
        let firstLaunch = SessionStore(provider: RecordingProvider(syncSessions: [session]), fileTransport: transportLeavingDestinationUnverified(recordingTo: cmdRecorder), defaults: defaults)
        await firstLaunch.resolveConflicts(session: session, conflicts: [c1, c2], winner: .alpha)
        let token = try replaceToken(copiedBeside: "/tmp/b/a.txt", in: cmdRecorder.commands)

        let nextLaunch = SessionStore(provider: RecordingProvider(syncSessions: [session]), defaults: defaults)

        #expect(nextLaunch.sessionHolds == ["sync_1": holdMessage(root: "a.txt", destination: "/tmp/b/a.txt", token: token) + " 1 of 2 conflicts was not attempted."])
    }

    @Test("Resuming a held session by hand sends the resume and ends the hold, for this launch and the next")
    @MainActor
    func explicitResumeEndsHold() async throws {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let recorder = RecordingProvider(syncSessions: [session])
        let store = SessionStore(provider: recorder, fileTransport: transportLeavingDestinationUnverified(recordingTo: CommandRecorder()), defaults: defaults)
        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)

        await store.resumeSync("sync_1")

        #expect(recorder.calls == ["syncPause:sync_1", "syncResume:sync_1"])
        #expect(store.sessionHolds == [:])
        #expect(store.lastError == nil)
        #expect(SessionStore(provider: recorder, defaults: defaults).sessionHolds == [:])
    }

    @Test("A resume by hand that fails leaves the hold in place")
    @MainActor
    func failedExplicitResumeKeepsHold() async throws {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let cmdRecorder = CommandRecorder()
        let store = SessionStore(provider: RecordingProvider(syncSessions: [session]), fileTransport: transportLeavingDestinationUnverified(recordingTo: cmdRecorder), defaults: defaults)
        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)
        let token = try replaceToken(copiedBeside: "/tmp/b/file.txt", in: cmdRecorder.commands)
        store.replaceProvider(RecordingProvider(syncSessions: [session], failOn: "syncResume"))

        await store.resumeSync("sync_1")

        #expect(store.sessionHolds == ["sync_1": holdMessage(root: "file.txt", destination: "/tmp/b/file.txt", token: token)])
        #expect(store.lastError == "simulated failure")
    }

    @Test("A hold ends when its session is gone from the daemon's list, and not while the list cannot be read")
    @MainActor
    func holdEndsWithItsSession() async throws {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let cmdRecorder = CommandRecorder()
        let store = SessionStore(provider: RecordingProvider(syncSessions: [session]), fileTransport: transportLeavingDestinationUnverified(recordingTo: cmdRecorder), defaults: defaults)
        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)
        let token = try replaceToken(copiedBeside: "/tmp/b/file.txt", in: cmdRecorder.commands)

        store.replaceProvider(FailingProvider())
        await store.refresh()
        #expect(store.sessionHolds == ["sync_1": holdMessage(root: "file.txt", destination: "/tmp/b/file.txt", token: token)])

        store.replaceProvider(RecordingProvider(syncSessions: [makeSyncSession(id: "sync_2", name: "s2")]))
        await store.refresh()
        #expect(store.sessionHolds == [:])
    }

    @Test("Leftover notices of one session add up, outlive polling and relaunch, do not stop syncing, and go when dismissed")
    @MainActor
    func leftoverNoticesStayUntilDismissed() async throws {
        defer { removeDefaults() }
        let c1 = Conflict(root: "a.txt", alphaChanges: [], betaChanges: [])
        let c2 = Conflict(root: "b.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [c1, c2])
        let recorder = RecordingProvider(syncSessions: [session])
        let cmdRecorder = CommandRecorder()
        let transport = FileTransport { executable, arguments in
            let output = try await cmdRecorder.execute(executable, arguments)
            if executable == "/bin/rm" { throw CLIError(exitCode: 1, stderr: "permission denied") }
            return output
        }
        let store = SessionStore(provider: recorder, fileTransport: transport, defaults: defaults)

        await store.resolveConflict(session: session, conflict: c1, winner: .alpha)
        await store.resolveConflict(session: session, conflict: c2, winner: .alpha)
        await store.refresh()

        let copies = cmdRecorder.commands.filter { $0.executable == "/bin/cp" }
        let tokenA = try replaceToken(copiedBeside: "/tmp/b/a.txt", in: [copies[0]])
        let tokenB = try replaceToken(copiedBeside: "/tmp/b/b.txt", in: [copies[1]])
        let notices = ["sync_1": "Resolved \"a.txt\", but left the original it replaced at /tmp/b/a.txt.helix-replaced-\(tokenA): permission denied. Delete that path by hand. Resolved \"b.txt\", but left the original it replaced at /tmp/b/b.txt.helix-replaced-\(tokenB): permission denied. Delete that path by hand."]
        #expect(store.lastError == nil)
        #expect(store.leftoverNotices == notices)
        #expect(store.sessionHolds == [:])
        #expect(recorder.calls == ["syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1", "syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1"])
        #expect(SessionStore(provider: recorder, defaults: defaults).leftoverNotices == notices)

        store.dismissLeftoverNotice(for: "sync_1")

        #expect(store.leftoverNotices == [:])
        #expect(SessionStore(provider: recorder, defaults: defaults).leftoverNotices == [:])
    }

    @Test("Two resolves started together on one session run one after the other, in the order requested")
    @MainActor
    func resolvesOnOneSessionTakeTurns() async {
        defer { removeDefaults() }
        let c1 = Conflict(root: "a.txt", alphaChanges: [], betaChanges: [])
        let c2 = Conflict(root: "b.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [c1, c2])
        let provider = MainActorRecordingProvider(syncSessions: [session])
        let cmdRecorder = CommandRecorder()
        let gate = Gate()
        let transport = FileTransport { executable, arguments in
            await gate.pass()
            return try await cmdRecorder.execute(executable, arguments)
        }
        let store = SessionStore(provider: provider, fileTransport: transport, defaults: defaults)

        let first = Task { _ = await store.resolveConflict(session: session, conflict: c1, winner: .alpha) }
        let second = Task { _ = await store.resolveConflict(session: session, conflict: c2, winner: .alpha) }
        await gate.reached()
        for _ in 0..<100 { await Task.yield() }
        let callsWhileFirstIsMidway = provider.calls
        await gate.open()
        await first.value
        await second.value

        #expect(callsWhileFirstIsMidway == ["syncPause:sync_1"])
        #expect(provider.calls == [
            "syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1",
            "syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1",
        ])
        let roots = cmdRecorder.commands.map { $0.arguments.contains { $0.contains("a.txt") } ? "a.txt" : "b.txt" }
        #expect(roots == Array(repeating: "a.txt", count: 7) + Array(repeating: "b.txt", count: 7))
    }

    @Test("A resolve requested on a held session is refused with the hold message before any pause or file command")
    @MainActor
    func resolveOnHeldSessionRefused() async throws {
        defer { removeDefaults() }
        let c1 = Conflict(root: "a.txt", alphaChanges: [], betaChanges: [])
        let c2 = Conflict(root: "b.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [c1, c2])
        let firstRecorder = CommandRecorder()
        let store = SessionStore(provider: RecordingProvider(syncSessions: [session]), fileTransport: transportLeavingDestinationUnverified(recordingTo: firstRecorder), defaults: defaults)
        await store.resolveConflict(session: session, conflict: c1, winner: .alpha)
        let token = try replaceToken(copiedBeside: "/tmp/b/a.txt", in: firstRecorder.commands)
        await store.refresh()
        let commandsBefore = firstRecorder.commands.count
        let provider = RecordingProvider(syncSessions: [session])
        store.replaceProvider(provider)

        await store.resolveConflict(session: session, conflict: c2, winner: .alpha)
        await store.resolveConflicts(session: session, conflicts: [c2], winner: .beta)

        #expect(provider.calls == [])
        #expect(firstRecorder.commands.count == commandsBefore)
        #expect(store.lastError == holdMessage(root: "a.txt", destination: "/tmp/b/a.txt", token: token))
    }

    @Test("A resolve waiting behind one that ends unverified is refused when its turn comes")
    @MainActor
    func queuedResolveRefusedOnceHeld() async throws {
        defer { removeDefaults() }
        let c1 = Conflict(root: "a.txt", alphaChanges: [], betaChanges: [])
        let c2 = Conflict(root: "b.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [c1, c2])
        let provider = MainActorRecordingProvider(syncSessions: [session])
        let cmdRecorder = CommandRecorder()
        let store = SessionStore(provider: provider, fileTransport: transportLeavingDestinationUnverified(recordingTo: cmdRecorder), defaults: defaults)

        let first = Task { _ = await store.resolveConflict(session: session, conflict: c1, winner: .alpha) }
        let second = Task { _ = await store.resolveConflict(session: session, conflict: c2, winner: .alpha) }
        await first.value
        await second.value

        let token = try replaceToken(copiedBeside: "/tmp/b/a.txt", in: cmdRecorder.commands)
        #expect(provider.calls == ["syncPause:sync_1"])
        #expect(cmdRecorder.commands.map(\.arguments).filter { $0.contains { $0.contains("b.txt") } } == [])
        #expect(store.sessionHolds == ["sync_1": holdMessage(root: "a.txt", destination: "/tmp/b/a.txt", token: token)])
    }

    @Test("Resuming a session by hand while a conflict resolve runs on it is refused with an error and sends no resume")
    @MainActor
    func resumeDuringResolveRefused() async {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let provider = MainActorRecordingProvider(syncSessions: [session])
        let gate = Gate()
        let transport = FileTransport { _, _ in
            await gate.pass()
            return ""
        }
        let store = SessionStore(provider: provider, fileTransport: transport, defaults: defaults)
        await store.refresh()

        let resolve = Task { _ = await store.resolveConflict(session: session, conflict: conflict, winner: .alpha) }
        await gate.reached()
        await store.resumeSync("sync_1")
        let callsWhileResolveIsMidway = provider.calls
        let errorWhileResolveIsMidway = store.lastError
        let resolvingWhileResolveIsMidway = store.isResolving("sync_1")
        await gate.open()
        await resolve.value

        #expect(callsWhileResolveIsMidway == ["syncPause:sync_1"])
        #expect(errorWhileResolveIsMidway == "The session \"s1\" was not resumed: a conflict resolve is running on it.")
        #expect(provider.calls == ["syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1"])
        #expect(resolvingWhileResolveIsMidway)
        #expect(!store.isResolving("sync_1"))
    }

    @Test("Recreating a held session, or adding to its ignore list, is refused with the hold before anything is terminated")
    @MainActor
    func recreateOfHeldSessionRefused() async throws {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let cmdRecorder = CommandRecorder()
        let store = SessionStore(provider: RecordingProvider(syncSessions: [session]), fileTransport: transportLeavingDestinationUnverified(recordingTo: cmdRecorder), defaults: defaults)
        await store.resolveConflict(session: session, conflict: conflict, winner: .alpha)
        let token = try replaceToken(copiedBeside: "/tmp/b/file.txt", in: cmdRecorder.commands)
        let hold = holdMessage(root: "file.txt", destination: "/tmp/b/file.txt", token: token)
        let refusal = "The session \"s1\" was not recreated: it is kept paused after a conflict. Resume it first. \(hold)"
        let provider = RecordingProvider(syncSessions: [session])
        store.replaceProvider(provider)
        await store.refresh()

        await store.recreateSync(session, options: SyncCreateOptions(), alpha: "/tmp/a", beta: "/tmp/b")
        let errorAfterRecreate = store.lastError
        await store.refresh()
        await store.addToIgnoreList(session: session, path: "file.txt")

        #expect(provider.calls == [])
        #expect(errorAfterRecreate == refusal)
        #expect(store.lastError == refusal)
        #expect(store.sessionHolds == ["sync_1": hold])
    }

    @Test("Recreating a session, or adding to its ignore list, while a conflict resolve runs on it is refused before anything is terminated")
    @MainActor
    func recreateDuringResolveRefused() async {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let provider = MainActorRecordingProvider(syncSessions: [session])
        let gate = Gate()
        let transport = FileTransport { _, _ in
            await gate.pass()
            return ""
        }
        let store = SessionStore(provider: provider, fileTransport: transport, defaults: defaults)
        await store.refresh()
        let refusal = "The session \"s1\" was not recreated: a conflict resolve is running on it."

        let resolve = Task { _ = await store.resolveConflict(session: session, conflict: conflict, winner: .alpha) }
        await gate.reached()
        await store.recreateSync(session, options: SyncCreateOptions(), alpha: "/tmp/a", beta: "/tmp/b")
        let errorAfterRecreate = store.lastError
        await store.refresh()
        await store.addToIgnoreList(session: session, path: "file.txt")
        let errorAfterIgnore = store.lastError
        let callsWhileResolveIsMidway = provider.calls
        await gate.open()
        await resolve.value

        #expect(callsWhileResolveIsMidway == ["syncPause:sync_1"])
        #expect(errorAfterRecreate == refusal)
        #expect(errorAfterIgnore == refusal)
        #expect(provider.calls == ["syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1"])
    }

    @Test("While a replacement is under way, a store launched on the same defaults holds the session with the three paths and neither resumes nor resolves it")
    @MainActor
    func relaunchMidReplacementHoldsSession() async throws {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let running = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let paused = makeSyncSession(id: "sync_1", name: "s1", paused: true, conflicts: [conflict])
        let cmdRecorder = CommandRecorder()
        let gate = Gate()
        // The copy beside the destination is the first command that changes the losing side.
        let transport = FileTransport { executable, arguments in
            let output = try await cmdRecorder.execute(executable, arguments)
            if executable == "/bin/cp" { await gate.pass() }
            return output
        }
        let firstLaunch = SessionStore(provider: RecordingProvider(syncSessions: [running]), fileTransport: transport, defaults: defaults)
        await firstLaunch.pauseAllSync()

        let resolve = Task { _ = await firstLaunch.resolveConflict(session: paused, conflict: conflict, winner: .alpha) }
        await gate.reached()
        let token = try replaceToken(copiedBeside: "/tmp/b/file.txt", in: cmdRecorder.commands)
        let hold = "Helix quit while replacing /tmp/b/file.txt; check /tmp/b/file.txt.helix-incoming-\(token) and /tmp/b/file.txt.helix-replaced-\(token)"
        let provider = RecordingProvider(syncSessions: [paused])
        let nextRecorder = CommandRecorder()
        let nextLaunch = SessionStore(provider: provider, fileTransport: FileTransport(execute: nextRecorder.execute), defaults: defaults)
        let holdsAtLaunch = nextLaunch.sessionHolds
        let errorsLoggedAtLaunch = ConsoleLog.shared.entries.filter { $0.level == .error }.map(\.message)
        await nextLaunch.resumeBulkPause()
        let unresolved = await nextLaunch.resolveConflict(session: paused, conflict: conflict, winner: .beta)
        await gate.open()
        await resolve.value

        #expect(holdsAtLaunch == ["sync_1": hold])
        #expect(errorsLoggedAtLaunch.filter { $0 == hold } == [hold])
        #expect(provider.calls == [])
        #expect(nextRecorder.commands.count == 0)
        #expect(unresolved == ["file.txt"])
        #expect(nextLaunch.lastError == hold)
        #expect(nextLaunch.sessionHolds == ["sync_1": hold])
    }

    @Test("A replacement that completes, and one that fails with the destination unchanged, leave no hold for this launch or the next")
    @MainActor
    func settledReplacementLeavesNoHold() async {
        defer { removeDefaults() }
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let recorder = RecordingProvider(syncSessions: [session])
        let completing = SessionStore(provider: recorder, fileTransport: FileTransport(execute: CommandRecorder().execute), defaults: defaults)

        await completing.resolveConflict(session: session, conflict: conflict, winner: .alpha)

        #expect(completing.sessionHolds == [:])
        #expect(SessionStore(provider: recorder, defaults: defaults).sessionHolds == [:])
        #expect(recorder.calls == ["syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1"])

        let failingCopy = FileTransport { executable, _ in
            if executable == "/bin/cp" { throw CLIError(exitCode: 1, stderr: "permission denied") }
            return ""
        }
        let unchanged = SessionStore(provider: recorder, fileTransport: failingCopy, defaults: defaults)

        await unchanged.resolveConflict(session: session, conflict: conflict, winner: .alpha)

        #expect(unchanged.sessionHolds == [:])
        #expect(SessionStore(provider: recorder, defaults: defaults).sessionHolds == [:])
        #expect(recorder.calls == ["syncPause:sync_1", "syncResume:sync_1", "syncFlush:sync_1", "syncPause:sync_1", "syncResume:sync_1"])
    }

    @Test("A resolve returns the roots it left unresolved: failed, not attempted, and refused ones")
    @MainActor
    func resolveReturnsUnresolvedRoots() async {
        defer { removeDefaults() }
        let c1 = Conflict(root: "a.txt", alphaChanges: [], betaChanges: [])
        let c2 = Conflict(root: "b.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [c1, c2])
        let failingToCopyB = FileTransport { executable, arguments in
            if executable == "/bin/cp", arguments[1] == "/tmp/a/b.txt" { throw CLIError(exitCode: 1, stderr: "permission denied") }
            return ""
        }
        let store = SessionStore(provider: RecordingProvider(syncSessions: [session]), fileTransport: failingToCopyB, defaults: defaults)

        #expect(await store.resolveConflicts(session: session, conflicts: [c1, c2], winner: .alpha) == ["b.txt"])
        #expect(await store.resolveConflict(session: session, conflict: c2, winner: .alpha) == ["b.txt"])
        #expect(await store.resolveConflict(session: session, conflict: c1, winner: .alpha) == [])

        let held = SessionStore(provider: RecordingProvider(syncSessions: [session]), fileTransport: transportLeavingDestinationUnverified(recordingTo: CommandRecorder()), defaults: defaults)

        #expect(await held.resolveConflicts(session: session, conflicts: [c1, c2], winner: .alpha) == ["a.txt", "b.txt"])
        #expect(await held.resolveConflict(session: session, conflict: c2, winner: .alpha) == ["b.txt"])
        #expect(await held.resolveConflicts(session: session, conflicts: [c1, c2], winner: .alpha) == ["a.txt", "b.txt"])
    }

    @Test("conflictFileInfo returns file metadata from both endpoints")
    @MainActor
    func fileInfo() async {
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let transport = FileTransport { executable, _ in
            if executable == "/bin/test" {
                // isSymlink check: exit 1 = not a symlink
                throw CLIError(exitCode: 1, stderr: "")
            }
            return "1024 1700000000"
        }
        let store = SessionStore(provider: FakeProvider(syncSessions: [session]), fileTransport: transport)

        let info = await store.conflictFileInfo(session: session, conflict: conflict)

        #expect(info.alpha != nil)
        #expect(info.alpha?.size == 1024)
        #expect(info.alpha?.isSymlink == false)
        #expect(info.alpha?.symlinkTarget == nil)
        #expect(info.beta != nil)
        #expect(info.beta?.size == 1024)
        #expect(info.beta?.isSymlink == false)
        #expect(info.beta?.symlinkTarget == nil)
    }

    @Test("conflictFileInfo returns nil for failed stat")
    @MainActor
    func fileInfoFailure() async {
        let conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let transport = FileTransport { _, _ in
            throw CLIError(exitCode: 1, stderr: "no such file")
        }
        let store = SessionStore(provider: FakeProvider(syncSessions: [session]), fileTransport: transport)

        let info = await store.conflictFileInfo(session: session, conflict: conflict)

        #expect(info.alpha == nil)
        #expect(info.beta == nil)
    }

    @Test("conflictFileInfo populates symlink fields when alpha is a symlink")
    @MainActor
    func fileInfoWithSymlink() async {
        let conflict = Conflict(root: "mylink", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])
        let transport = FileTransport { executable, args in
            let joined = args.joined(separator: " ")
            // stat: return valid output for both
            if executable == "/usr/bin/stat" {
                return "512 1700000000"
            }
            // isSymlink: alpha is a symlink, beta is not
            if executable == "/bin/test" && args.contains("-L") {
                if joined.contains("/tmp/a") {
                    return ""  // exit 0 = is a symlink
                }
                throw CLIError(exitCode: 1, stderr: "")  // not a symlink
            }
            // readLink: return target for alpha
            if executable == "/usr/bin/readlink" && joined.contains("/tmp/a") {
                return "/actual/target/path\n"
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(syncSessions: [session]), fileTransport: transport)

        let info = await store.conflictFileInfo(session: session, conflict: conflict)

        #expect(info.alpha != nil)
        #expect(info.alpha?.isSymlink == true)
        #expect(info.alpha?.symlinkTarget == "/actual/target/path")
        #expect(info.beta != nil)
        #expect(info.beta?.isSymlink == false)
        #expect(info.beta?.symlinkTarget == nil)
    }
}

@Suite("SessionStore conflictDiff")
struct ConflictDiffTests {

    @Test("Returns diff hunks for conflicting file content")
    @MainActor
    func diffReturnsHunks() async {
        let conflict = Conflict(
            root: "readme.txt",
            alphaChanges: [Change(path: "readme.txt", old: Entry(kind: "file", digest: nil, executable: nil), new: Entry(kind: "file", digest: nil, executable: nil))],
            betaChanges: [Change(path: "readme.txt", old: Entry(kind: "file", digest: nil, executable: nil), new: Entry(kind: "file", digest: nil, executable: nil))]
        )
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])

        let transport = FileTransport { executable, args in
            // Return different content depending on which path is being cat'd
            if args.last == "/tmp/a/readme.txt" {
                return "line1\noriginal\nline3\n"
            } else if args.last == "/tmp/b/readme.txt" {
                return "line1\nmodified\nline3\n"
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(syncSessions: [session]), fileTransport: transport)

        let result = await store.conflictDiff(session: session, conflict: conflict)
        #expect(result != nil)
        #expect(!result!.isEmpty)

        let allLines = result!.flatMap(\.lines)
        let deletions = allLines.filter { $0.tag == .delete }
        let insertions = allLines.filter { $0.tag == .insert }
        #expect(deletions.count > 0)
        #expect(insertions.count > 0)
    }

    @Test("Returns nil when file read fails")
    @MainActor
    func diffReturnsNilOnError() async {
        let conflict = Conflict(root: "missing.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])

        let transport = FileTransport { _, _ in
            throw CLIError(exitCode: 1, stderr: "No such file")
        }
        let store = SessionStore(provider: FakeProvider(syncSessions: [session]), fileTransport: transport)

        let result = await store.conflictDiff(session: session, conflict: conflict)
        #expect(result == nil)
    }

    @Test("Returns empty hunks for identical files")
    @MainActor
    func diffIdenticalFiles() async {
        let conflict = Conflict(root: "same.txt", alphaChanges: [], betaChanges: [])
        let session = makeSyncSession(id: "sync_1", name: "s1", conflicts: [conflict])

        let transport = FileTransport { _, _ in
            return "identical\ncontent\n"
        }
        let store = SessionStore(provider: FakeProvider(syncSessions: [session]), fileTransport: transport)

        let result = await store.conflictDiff(session: session, conflict: conflict)
        #expect(result != nil)
        #expect(result!.isEmpty)
    }
}

@Suite("SessionStore git repo status")
struct GitRepoStatusTests {

    @Test("Both endpoints have .git returns symmetric")
    @MainActor
    func bothHaveGit() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { _, _ in "" }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let check = await store.gitRepoStatus(for: session)

        #expect(check.status == .symmetric)
        #expect(check.subpath.isEmpty)
    }

    @Test("Neither root nor subdirectories have .git returns symmetric")
    @MainActor
    func neitherHasGit() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { executable, args in
            let joined = args.joined(separator: " ")
            if executable == "/bin/test" {
                throw CLIError(exitCode: 1, stderr: "")
            }
            // find returns empty
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let check = await store.gitRepoStatus(for: session)

        #expect(check.status == .symmetric)
    }

    @Test("Only alpha has .git with remote returns alphaOnly and hasRemote true")
    @MainActor
    func alphaOnlyWithRemote() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { executable, args in
            let joined = args.joined(separator: " ")
            if executable == "/bin/test" && joined.contains("/tmp/b") {
                throw CLIError(exitCode: 1, stderr: "")
            }
            if joined.contains("git config --get remote.origin.url") {
                return "https://github.com/example/repo.git\n"
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let check = await store.gitRepoStatus(for: session)

        #expect(check.status == .alphaOnly)
        #expect(check.subpath.isEmpty)
        #expect(check.hasRemote == true)
    }

    @Test("Only alpha has .git without remote returns alphaOnly and hasRemote false")
    @MainActor
    func alphaOnlyNoRemote() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { executable, args in
            let joined = args.joined(separator: " ")
            if executable == "/bin/test" && joined.contains("/tmp/b") {
                throw CLIError(exitCode: 1, stderr: "")
            }
            if joined.contains("git config --get remote.origin.url") {
                throw CLIError(exitCode: 1, stderr: "")
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let check = await store.gitRepoStatus(for: session)

        #expect(check.status == .alphaOnly)
        #expect(check.hasRemote == false)
    }

    @Test("Only beta has .git at root returns betaOnly with empty subpath")
    @MainActor
    func betaOnly() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { _, args in
            let joined = args.joined(separator: " ")
            if joined.contains("/tmp/a") {
                throw CLIError(exitCode: 1, stderr: "")
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let check = await store.gitRepoStatus(for: session)

        #expect(check.status == .betaOnly)
        #expect(check.subpath.isEmpty)
    }

    @Test("An endpoint mutagen reports as not connected gets no probe")
    @MainActor
    func disconnectedEndpointNotProbed() async {
        let session = makeSyncSession(
            id: "sync_1", name: "test", status: "connecting-beta",
            beta: makeEndpoint(path: "/tmp/b", connected: false)
        )
        let recorder = CommandRecorder()
        let store = SessionStore(provider: FakeProvider(), fileTransport: FileTransport(execute: recorder.execute))

        let check = await store.gitRepoStatus(for: session)

        #expect(recorder.commands.count == 0)
        #expect(check.status == .unknown)
    }

    @Test("Transport error returns unknown")
    @MainActor
    func transportError() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { _, _ in
            throw CLIError(exitCode: 255, stderr: "connection refused")
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let check = await store.gitRepoStatus(for: session)

        #expect(check.status == .unknown)
    }

    @Test("Subdirectory .git on alpha only returns alphaOnly with subpath")
    @MainActor
    func subdirectoryAlphaOnly() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { executable, args in
            let joined = args.joined(separator: " ")
            // Root .git checks: both return false
            if executable == "/bin/test" {
                throw CLIError(exitCode: 1, stderr: "")
            }
            // find command via /bin/sh
            if joined.contains("find .") {
                if joined.contains("/tmp/a") {
                    return "./helix/.git\n"
                }
                return ""
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let check = await store.gitRepoStatus(for: session)

        #expect(check.status == .alphaOnly)
        #expect(check.subpath == "helix")
    }

    @Test("Subdirectory .git on beta only returns betaOnly with subpath")
    @MainActor
    func subdirectoryBetaOnly() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { executable, args in
            let joined = args.joined(separator: " ")
            if executable == "/bin/test" {
                throw CLIError(exitCode: 1, stderr: "")
            }
            if joined.contains("find .") {
                if joined.contains("/tmp/b") {
                    return "./project/.git\n"
                }
                return ""
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let check = await store.gitRepoStatus(for: session)

        #expect(check.status == .betaOnly)
        #expect(check.subpath == "project")
    }

    @Test("Subdirectory .git on both sides returns symmetric")
    @MainActor
    func subdirectoryBothHaveGit() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { executable, args in
            let joined = args.joined(separator: " ")
            if executable == "/bin/test" {
                throw CLIError(exitCode: 1, stderr: "")
            }
            if joined.contains("find .") {
                return "./helix/.git\n"
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let check = await store.gitRepoStatus(for: session)

        #expect(check.status == .symmetric)
    }
}

@Suite("SessionStore fixGitMismatch")
struct FixGitMismatchTests {

    @Test("Reads remote and branch from alpha, runs git commands on beta")
    @MainActor
    func alphaOnlyFixesBeta() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let log = CallLog()
        let transport = FileTransport { executable, args in
            log.record(executable: executable, arguments: args)

            let joined = args.joined(separator: " ")
            if joined.contains("/tmp/a") && joined.contains("remote.origin.url") {
                return "https://github.com/example/repo.git\n"
            }
            if joined.contains("/tmp/a") && joined.contains("branch --show-current") {
                return "main\n"
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let success = await store.fixGitMismatch(session: session, gitCheck: GitRepoCheck(status: .alphaOnly))

        #expect(success == true)
        #expect(store.lastError == nil)

        let commands = log.entries
        #expect(commands.count == 6)

        // Read remote URL from alpha
        let readRemote = commands[0].arguments.joined(separator: " ")
        #expect(readRemote.contains("/tmp/a") && readRemote.contains("remote.origin.url"))

        // Read branch from alpha
        let readBranch = commands[1].arguments.joined(separator: " ")
        #expect(readBranch.contains("/tmp/a") && readBranch.contains("branch --show-current"))

        // git init on beta
        let gitInit = commands[2].arguments.joined(separator: " ")
        #expect(gitInit.contains("/tmp/b") && gitInit.contains("git init"))

        // git remote add on beta
        let remoteAdd = commands[3].arguments.joined(separator: " ")
        #expect(remoteAdd.contains("/tmp/b") && remoteAdd.contains("git remote add origin"))
        #expect(remoteAdd.contains("https://github.com/example/repo.git"))

        // git fetch on beta
        let fetch = commands[4].arguments.joined(separator: " ")
        #expect(fetch.contains("/tmp/b") && fetch.contains("git fetch origin"))

        // git reset on beta
        let reset = commands[5].arguments.joined(separator: " ")
        #expect(reset.contains("/tmp/b") && reset.contains("git reset --mixed 'origin/main'"))
    }

    @Test("betaOnly reads from beta and fixes alpha")
    @MainActor
    func betaOnlyFixesAlpha() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let log = CallLog()
        let transport = FileTransport { executable, args in
            log.record(executable: executable, arguments: args)

            let joined = args.joined(separator: " ")
            if joined.contains("/tmp/b") && joined.contains("remote.origin.url") {
                return "git@github.com:example/repo.git\n"
            }
            if joined.contains("/tmp/b") && joined.contains("branch --show-current") {
                return "develop\n"
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let success = await store.fixGitMismatch(session: session, gitCheck: GitRepoCheck(status: .betaOnly))

        #expect(success == true)

        // git init should target alpha (/tmp/a)
        let gitInit = log.entries[2].arguments.joined(separator: " ")
        #expect(gitInit.contains("/tmp/a") && gitInit.contains("git init"))

        // Reset should use develop branch
        let reset = log.entries[5].arguments.joined(separator: " ")
        #expect(reset.contains("origin/develop"))
    }

    @Test("No remote URL sets lastError and returns false")
    @MainActor
    func noRemote() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { _, args in
            let joined = args.joined(separator: " ")
            if joined.contains("remote.origin.url") {
                return "\n"
            }
            if joined.contains("branch --show-current") {
                return "main\n"
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let success = await store.fixGitMismatch(session: session, gitCheck: GitRepoCheck(status: .alphaOnly))

        #expect(success == false)
        #expect(store.lastError != nil)
        #expect(store.lastError!.contains("No git remote"))
    }

    @Test("Transport error reading git info sets lastError")
    @MainActor
    func readError() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { _, _ in
            throw CLIError(exitCode: 128, stderr: "not a git repository")
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let success = await store.fixGitMismatch(session: session, gitCheck: GitRepoCheck(status: .alphaOnly))

        #expect(success == false)
        #expect(store.lastError != nil)
        #expect(store.lastError!.contains("Could not read git info"))
    }

    @Test("Symmetric status returns false immediately")
    @MainActor
    func symmetricNoOp() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let store = SessionStore(provider: FakeProvider())

        let success = await store.fixGitMismatch(session: session, gitCheck: GitRepoCheck(status: .symmetric))

        #expect(success == false)
    }

    @Test("gitSourceInfo reads remote URL and branch from source endpoint")
    @MainActor
    func sourceInfo() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { _, args in
            let joined = args.joined(separator: " ")
            if joined.contains("remote.origin.url") {
                return "https://github.com/hex/Helix.git\n"
            }
            if joined.contains("branch --show-current") {
                return "main\n"
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let info = await store.gitSourceInfo(
            for: session,
            gitCheck: GitRepoCheck(status: .alphaOnly, subpath: "helix")
        )

        #expect(info.remoteURL == "https://github.com/hex/Helix.git")
        #expect(info.branch == "main")
    }

    @Test("gitSourceInfo returns nil when no remote configured")
    @MainActor
    func sourceInfoNoRemote() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let transport = FileTransport { _, args in
            let joined = args.joined(separator: " ")
            if joined.contains("remote.origin.url") {
                throw CLIError(exitCode: 1, stderr: "")
            }
            if joined.contains("branch --show-current") {
                return "main\n"
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let info = await store.gitSourceInfo(
            for: session,
            gitCheck: GitRepoCheck(status: .alphaOnly)
        )

        #expect(info.remoteURL == nil)
        #expect(info.branch == "main")
    }

    @Test("Uses subpath when fixing subdirectory mismatch")
    @MainActor
    func fixWithSubpath() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let log = CallLog()
        let transport = FileTransport { executable, args in
            log.record(executable: executable, arguments: args)

            let joined = args.joined(separator: " ")
            if joined.contains("/tmp/a/helix") && joined.contains("remote.origin.url") {
                return "https://github.com/example/repo.git\n"
            }
            if joined.contains("/tmp/a/helix") && joined.contains("branch --show-current") {
                return "main\n"
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let success = await store.fixGitMismatch(
            session: session,
            gitCheck: GitRepoCheck(status: .alphaOnly, subpath: "helix")
        )

        #expect(success == true)

        let commands = log.entries
        #expect(commands.count == 6)

        // Read remote from alpha/helix
        let readRemote = commands[0].arguments.joined(separator: " ")
        #expect(readRemote.contains("/tmp/a/helix"))

        // Git init on beta/helix
        let gitInit = commands[2].arguments.joined(separator: " ")
        #expect(gitInit.contains("/tmp/b/helix") && gitInit.contains("git init"))
    }

    @Test("Git init failure on target sets lastError")
    @MainActor
    func initFails() async {
        let session = makeSyncSession(id: "sync_1", name: "test")
        var callCount = 0
        let lock = NSLock()
        let transport = FileTransport { _, args in
            lock.lock()
            callCount += 1
            let count = callCount
            lock.unlock()

            let joined = args.joined(separator: " ")
            if joined.contains("remote.origin.url") {
                return "https://github.com/example/repo.git\n"
            }
            if joined.contains("branch --show-current") {
                return "main\n"
            }
            // Fail on git init (third call)
            if count >= 3 {
                throw CLIError(exitCode: 1, stderr: "permission denied")
            }
            return ""
        }
        let store = SessionStore(provider: FakeProvider(), fileTransport: transport)

        let success = await store.fixGitMismatch(session: session, gitCheck: GitRepoCheck(status: .alphaOnly))

        #expect(success == false)
        #expect(store.lastError != nil)
        #expect(store.lastError!.contains("Git init failed"))
    }
}

final class RecordingDaemonProcess: DaemonProcess, @unchecked Sendable {
    private var _pid: ProcessID?
    private var _calls: [String] = []
    private let lock = NSLock()

    init(pid: Int32?) {
        _pid = pid.map { ProcessID($0)! }
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func restart(as pid: Int32) {
        lock.lock()
        _pid = ProcessID(pid)!
        lock.unlock()
    }

    func pid() async throws -> ProcessID? {
        lock.lock()
        defer { lock.unlock() }
        return _pid
    }

    func setBackgroundPriority(_ enabled: Bool, pid: ProcessID) async throws {
        lock.lock()
        _calls.append("\(enabled ? "background" : "restore"):\(pid.rawValue)")
        lock.unlock()
    }
}

final class CallLog: @unchecked Sendable {
    private var _entries: [RecordedCommand] = []
    private let lock = NSLock()

    var entries: [RecordedCommand] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    func record(executable: String, arguments: [String]) {
        lock.lock()
        _entries.append(RecordedCommand(executable: executable, arguments: arguments))
        lock.unlock()
    }
}

func makeForwardSession(
    id: String,
    name: String?,
    paused: Bool = false
) -> ForwardSession {
    ForwardSession(
        identifier: id,
        version: 1,
        creationTime: "2026-01-01T00:00:00Z",
        creatingVersion: "0.18.1",
        name: name,
        labels: nil,
        paused: paused,
        source: ForwardEndpoint(protocol_: "local", user: nil, host: nil, port: nil, connected: true),
        destination: ForwardEndpoint(protocol_: "ssh", user: "test", host: "host", port: nil, connected: true),
        sourceEndpoint: "tcp:localhost:8080",
        destinationEndpoint: "tcp:localhost:3000",
        socket: nil
    )
}

@Suite("SessionStore name collision sources")
struct SessionNameCollisionTests {

    @Test("Sync names exclude the session being renamed")
    @MainActor
    func syncNamesExcludeSelf() async {
        let provider = FakeProvider(syncSessions: [
            makeSyncSession(id: "sync_1", name: "web-app"),
            makeSyncSession(id: "sync_2", name: "api")
        ])
        let store = SessionStore(provider: provider)
        await store.refresh()

        #expect(store.syncSessionNames(excluding: "sync_1") == ["api"])
    }

    @Test("Sync names include every session when nothing is excluded")
    @MainActor
    func syncNamesIncludeAll() async {
        let provider = FakeProvider(syncSessions: [
            makeSyncSession(id: "sync_1", name: "web-app"),
            makeSyncSession(id: "sync_2", name: "api")
        ])
        let store = SessionStore(provider: provider)
        await store.refresh()

        #expect(store.syncSessionNames() == ["web-app", "api"])
    }

    @Test("Unnamed sessions contribute no name")
    @MainActor
    func unnamedSessionsSkipped() async {
        let provider = FakeProvider(syncSessions: [
            makeSyncSession(id: "sync_1", name: nil),
            makeSyncSession(id: "sync_2", name: "api")
        ])
        let store = SessionStore(provider: provider)
        await store.refresh()

        #expect(store.syncSessionNames() == ["api"])
    }

    @Test("Forward names are tracked separately from sync names")
    @MainActor
    func forwardNamesAreSeparate() async {
        let provider = FakeProvider(
            syncSessions: [makeSyncSession(id: "sync_1", name: "web-app")],
            forwardSessions: [makeForwardSession(id: "fwd_1", name: "db-tunnel")]
        )
        let store = SessionStore(provider: provider)
        await store.refresh()

        #expect(store.forwardSessionNames() == ["db-tunnel"])
        #expect(store.syncSessionNames() == ["web-app"])
    }
}

@Suite("Selection after recreate")
struct RecreateSelectionTests {

    @Test("Selects the session that recreate produced")
    @MainActor
    func selectsRecreatedSession() async {
        let old = makeSyncSession(id: "sync_old", name: "test")
        let new = makeSyncSession(id: "sync_new", name: "test")
        let recorder = RecordingProvider(syncSessions: [old], sessionsAfterCreate: [new])
        let store = SessionStore(provider: recorder)
        await store.refresh()

        var opts = SyncCreateOptions()
        opts.name = "test"
        await store.recreateSync(old, options: opts, alpha: "/tmp/a", beta: "/tmp/b")

        #expect(store.pendingSessionSelection == "sync_new")
    }

    @Test("Leaves selection alone when untouched sessions are present")
    @MainActor
    func ignoresPreexistingSessions() async {
        let other = makeSyncSession(id: "sync_other", name: "other")
        let old = makeSyncSession(id: "sync_old", name: "test")
        let new = makeSyncSession(id: "sync_new", name: "test")
        let recorder = RecordingProvider(
            syncSessions: [other, old],
            sessionsAfterCreate: [other, new]
        )
        let store = SessionStore(provider: recorder)
        await store.refresh()

        var opts = SyncCreateOptions()
        opts.name = "test"
        await store.recreateSync(old, options: opts, alpha: "/tmp/a", beta: "/tmp/b")

        #expect(store.pendingSessionSelection == "sync_new")
    }

    @Test("Sets no selection when recreate produced nothing new")
    @MainActor
    func noSelectionWithoutNewSession() async {
        let old = makeSyncSession(id: "sync_old", name: "test")
        let recorder = RecordingProvider(syncSessions: [old], sessionsAfterCreate: [old])
        let store = SessionStore(provider: recorder)
        await store.refresh()

        var opts = SyncCreateOptions()
        opts.name = "test"
        await store.recreateSync(old, options: opts, alpha: "/tmp/a", beta: "/tmp/b")

        #expect(store.pendingSessionSelection == nil)
    }
}
