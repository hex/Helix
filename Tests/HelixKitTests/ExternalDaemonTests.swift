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
}
