// ABOUTME: Verifies that a stopped Helix observes the daemon without contacting Mutagen.
// ABOUTME: Exercises daemon actions with isolated preferences and process observations.

import Foundation
import Testing
@testable import HelixKit

@Suite("Daemon started outside Helix")
struct ExternalDaemonTests {
    private let suite = "ExternalDaemonTests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    @MainActor
    private func waitForStatus(_ expected: DaemonStatus, in store: SessionStore) async throws {
        let timeout = ContinuousClock.now + .seconds(2)
        while store.daemonStatus != expected, ContinuousClock.now < timeout {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Stopped polling notices an outside start and leaves session commands fenced")
    @MainActor
    func stoppedPollingNoticesOutsideDaemon() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "daemonStoppedByHelix")
        let daemon = RecordingDaemonProcess(pid: 123)
        let provider = RecordingProvider(recordQueries: true)
        let store = SessionStore(provider: provider, defaults: defaults, daemonProcess: daemon)
        store.startPolling(interval: 0.02)
        defer { store.stopPolling() }

        try await waitForStatus(.startedOutside, in: store)

        #expect(store.daemonStatus.rawValue == "Mutagen was started outside Helix")
        #expect(store.lastError == nil)
        #expect(defaults.bool(forKey: "daemonStoppedByHelix"))
        #expect(provider.calls == [])

        await store.fetchVersion()
        await store.manualRefresh()
        await store.pauseSync("sync_1")
        #expect(provider.calls == [])
        #expect(store.lastError == "Start the Mutagen daemon before using session commands.")
    }

    @Test("After relaunch Manage Sessions lists the outside daemon's sessions without starting it")
    @MainActor
    func relaunchOffersManagementWithoutStartingDaemon() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SessionStore(
            provider: RecordingProvider(), defaults: defaults, daemonProcess: RecordingDaemonProcess(pid: nil)
        )
        #expect(await first.stopDaemon())
        let daemon = RecordingDaemonProcess(pid: 123)
        first.replaceDaemonProcess(daemon)
        await first.refresh()
        #expect(first.daemonStatus == .startedOutside)

        let session = makeSyncSession(id: "sync_1", name: "project")
        let provider = RecordingProvider(syncSessions: [session], recordQueries: true)
        let relaunched = SessionStore(provider: provider, defaults: defaults, daemonProcess: daemon)
        await relaunched.refresh()
        #expect(relaunched.daemonStatus == .startedOutside)
        #expect(provider.calls == [])

        await relaunched.manageExternalDaemon()

        #expect(!defaults.bool(forKey: "daemonStoppedByHelix"))
        #expect(relaunched.daemonStatus == .running)
        #expect(relaunched.syncSessions.map(\.identifier) == ["sync_1"])
        #expect(provider.calls.sorted() == ["forwardList", "syncList"])
    }

    @Test("Stop Again sends only Stop and preserves the stopped preference", arguments: [true, false])
    @MainActor
    func stopAgainUsesNormalStop(succeeds: Bool) async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "daemonStoppedByHelix")
        let daemon = RecordingDaemonProcess(pid: 123)
        let provider = RecordingProvider(failOn: succeeds ? nil : "daemonStop", recordQueries: true)
        let store = SessionStore(provider: provider, defaults: defaults, daemonProcess: daemon)
        await store.refresh()

        let stopped = await store.stopDaemon()

        #expect(stopped == succeeds)
        #expect(provider.calls == ["daemonStop"])
        #expect(defaults.bool(forKey: "daemonStoppedByHelix"))
        #expect(store.daemonStatus == (succeeds ? .stopped : .startedOutside))
        #expect(store.lastError == (succeeds ? nil : "Could not stop Mutagen: simulated failure"))
        await store.pauseSync("sync_1")
        #expect(provider.calls == ["daemonStop"])
    }

    @Test("Stopped polling returns to plain Stopped when the outside daemon disappears")
    @MainActor
    func outsideDaemonDisappearanceReturnsToStopped() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "daemonStoppedByHelix")
        let provider = RecordingProvider(recordQueries: true)
        let store = SessionStore(
            provider: provider, defaults: defaults, daemonProcess: RecordingDaemonProcess(pid: 123)
        )
        store.startPolling(interval: 0.02)
        defer { store.stopPolling() }
        try await waitForStatus(.startedOutside, in: store)
        #expect(store.daemonStatus == .startedOutside)
        store.replaceDaemonProcess(RecordingDaemonProcess(pid: nil))
        try await waitForStatus(.stopped, in: store)

        #expect(store.daemonStatus == .stopped)
        #expect(defaults.bool(forKey: "daemonStoppedByHelix"))
        #expect(provider.calls == [])
    }

    @Test("A process check started before Stop Again cannot restore the outside-started label")
    @MainActor
    func staleOutsideDaemonCheckCannotUndoStop() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "daemonStoppedByHelix")
        let provider = RecordingProvider(recordQueries: true)
        let store = SessionStore(
            provider: provider, defaults: defaults, daemonProcess: RecordingDaemonProcess(pid: 123)
        )
        await store.refresh()
        let gate = Gate()
        store.replaceDaemonProcess(SuspendedProcessCheck(gate: gate))
        let staleCheck = Task { await store.refresh() }
        await gate.reached()

        let stopped = await store.stopDaemon()
        await gate.open()
        await staleCheck.value

        #expect(stopped)
        #expect(store.daemonStatus == .stopped)
        #expect(provider.calls == ["daemonStop"])
    }
}

private struct SuspendedProcessCheck: DaemonProcess {
    let gate: Gate

    func pid() async throws -> ProcessID? {
        await gate.pass()
        return ProcessID(123)
    }

    func setBackgroundPriority(_ enabled: Bool, pid: ProcessID) async throws {
        Issue.record("Stopped polling attempted to change the daemon priority")
    }
}
