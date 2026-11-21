// ABOUTME: Verifies that a stopped Helix observes the daemon without contacting Mutagen.
// ABOUTME: Exercises daemon actions with isolated preferences and process observations.

import Foundation
import Testing
@testable import HelixKit

@Suite("Daemon started outside Helix")
struct ExternalDaemonTests {
    @Test("Stopped polling notices an outside start and leaves session commands fenced")
    @MainActor
    func stoppedPollingNoticesOutsideDaemon() async throws {
        let suite = "ExternalDaemonTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "daemonStoppedByHelix")
        let daemon = RecordingDaemonProcess(pid: 123)
        let provider = RecordingProvider(recordQueries: true)
        let store = SessionStore(provider: provider, defaults: defaults, daemonProcess: daemon)
        store.startPolling(interval: 0.02)
        defer { store.stopPolling() }

        let timeout = ContinuousClock.now + .seconds(2)
        while store.daemonStatus.rawValue == "Stopped", ContinuousClock.now < timeout {
            try await Task.sleep(for: .milliseconds(20))
        }

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
        let suite = "ExternalDaemonTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
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
        let suite = "ExternalDaemonTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
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
}
