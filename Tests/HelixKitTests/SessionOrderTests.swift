// ABOUTME: Tests for client-side session ordering: the sort modes and the manual drag order.
// ABOUTME: Covers new, missing, renamed, and unnamed sessions, and position carry-over on recreate.

import Testing
import Foundation
import Observation
@testable import HelixKit

@Suite("Session sort modes")
struct SessionSortModeTests {

    private let alpha = makeSyncSession(id: "sync_a", name: "alpha")
    private let bravo = makeSyncSession(id: "sync_b", name: "bravo")
    private let charlie = makeSyncSession(id: "sync_c", name: "charlie")

    @Test("Manual mode follows the stored order")
    func manualFollowsStoredOrder() {
        let sorted = SessionOrder.sorted([alpha, bravo, charlie], by: .manual, manualOrder: ["charlie", "alpha", "bravo"])

        #expect(sorted.map(\.identifier) == ["sync_c", "sync_a", "sync_b"])
    }

    @Test("Sessions missing from the stored order follow it in mutagen's order")
    func newSessionsGoLast() {
        let sorted = SessionOrder.sorted([alpha, bravo, charlie], by: .manual, manualOrder: ["bravo"])

        #expect(sorted.map(\.identifier) == ["sync_b", "sync_a", "sync_c"])
    }

    @Test("Stored keys without a session are skipped")
    func staleKeysSkipped() {
        let sorted = SessionOrder.sorted([alpha, bravo], by: .manual, manualOrder: ["gone", "bravo", "alpha"])

        #expect(sorted.map(\.identifier) == ["sync_b", "sync_a"])
    }

    @Test("Unnamed sessions are keyed by identifier")
    func unnamedUseIdentifier() {
        let unnamed = makeSyncSession(id: "sync_u", name: nil)
        let blank = makeSyncSession(id: "sync_v", name: "")

        let sorted = SessionOrder.sorted([alpha, unnamed, blank], by: .manual, manualOrder: ["sync_v", "sync_u", "alpha"])

        #expect(sorted.map(\.identifier) == ["sync_v", "sync_u", "sync_a"])
    }

    @Test("Duplicate keys in the stored order or among sessions do not break the order")
    func duplicateKeys() {
        let otherBravo = makeSyncSession(id: "sync_b2", name: "bravo")

        let sorted = SessionOrder.sorted(
            [alpha, bravo, otherBravo],
            by: .manual,
            manualOrder: ["bravo", "alpha", "bravo"]
        )

        #expect(sorted.map(\.identifier) == ["sync_b", "sync_b2", "sync_a"])
    }

    @Test("Name mode sorts case-insensitively with numbers in numeric order")
    func nameMode() {
        let web10 = makeSyncSession(id: "sync_1", name: "web-10")
        let web2 = makeSyncSession(id: "sync_2", name: "Web-2")
        let api = makeSyncSession(id: "sync_3", name: "api")

        let sorted = SessionOrder.sorted([web10, web2, api], by: .name, manualOrder: [])

        #expect(sorted.map(\.identifier) == ["sync_3", "sync_2", "sync_1"])
    }

    @Test("Name mode puts unnamed sessions last, in the manual order")
    func nameModeUnnamedLast() {
        let first = makeSyncSession(id: "sync_x", name: nil)
        let second = makeSyncSession(id: "sync_y", name: nil)

        let sorted = SessionOrder.sorted([first, second, bravo], by: .name, manualOrder: ["sync_y"])

        #expect(sorted.map(\.identifier) == ["sync_b", "sync_y", "sync_x"])
    }

    @Test("Status mode puts failing sessions first, then degraded, then running, then paused")
    func statusMode() {
        let conflict = Conflict(root: "file", alphaChanges: [], betaChanges: [])
        let sessions = [
            makeSyncSession(id: "watching", name: "a", status: "watching"),
            makeSyncSession(id: "paused", name: "b", status: "disconnected", paused: true),
            makeSyncSession(id: "scanning", name: "c", status: "scanning"),
            makeSyncSession(id: "conflicts", name: "d", status: "watching", conflicts: [conflict]),
            makeSyncSession(id: "halted", name: "e", status: "halted-on-root-emptied"),
            makeSyncSession(id: "disconnected", name: "f", status: "disconnected"),
            makeSyncSession(id: "connecting", name: "g", status: "connecting-beta"),
        ]

        let sorted = SessionOrder.sorted(sessions, by: .status, manualOrder: [])

        #expect(sorted.map(\.identifier) == [
            "disconnected", "connecting", "conflicts", "halted", "watching", "scanning", "paused",
        ])
    }

    @Test("Status mode keeps the manual order within a status")
    func statusModeTiesFollowManualOrder() {
        let broken = makeSyncSession(id: "sync_d", name: "delta", status: "disconnected")

        let sorted = SessionOrder.sorted(
            [alpha, bravo, charlie, broken],
            by: .status,
            manualOrder: ["charlie", "alpha", "bravo", "delta"]
        )

        #expect(sorted.map(\.identifier) == ["sync_d", "sync_c", "sync_a", "sync_b"])
    }

    @Test("Status mode puts disconnected forwards first and paused ones last")
    func forwardStatusMode() {
        let paused = makeForwardSession(id: "fwd_p", name: "p", paused: true)
        let healthy = makeForwardSession(id: "fwd_h", name: "h")
        let broken = makeForwardSession(id: "fwd_b", name: "b", connected: false)

        let sorted = SessionOrder.sorted([paused, healthy, broken], by: .status, manualOrder: [])

        #expect(sorted.map(\.identifier) == ["fwd_b", "fwd_h", "fwd_p"])
    }

    @Test("Server mode groups by remote host and puts local-only sessions last")
    func serverMode() {
        let zeta = makeSyncSession(id: "sync_z", name: "z", betaHost: "zeta.example.com")
        let local = makeSyncSession(id: "sync_l", name: "l")
        let alphaHost1 = makeSyncSession(id: "sync_1", name: "one", betaHost: "alpha.example.com")
        let alphaHost2 = makeSyncSession(id: "sync_2", name: "two", betaHost: "Alpha.example.com")

        let sorted = SessionOrder.sorted(
            [zeta, local, alphaHost1, alphaHost2],
            by: .server,
            manualOrder: ["two", "one"]
        )

        #expect(sorted.map(\.identifier) == ["sync_2", "sync_1", "sync_z", "sync_l"])
    }

    @Test("Server mode sorts forwards by their remote endpoint")
    func forwardServerMode() {
        let local = makeForwardSession(id: "fwd_l", name: "l", destinationHost: nil)
        let remote = makeForwardSession(id: "fwd_r", name: "r", destinationHost: "db.example.com")

        let sorted = SessionOrder.sorted([local, remote], by: .server, manualOrder: [])

        #expect(sorted.map(\.identifier) == ["fwd_r", "fwd_l"])
    }

    @Test("Date Created mode keeps mutagen's order")
    func createdMode() {
        let sorted = SessionOrder.sorted([charlie, alpha, bravo], by: .created, manualOrder: ["alpha", "bravo", "charlie"])

        #expect(sorted.map(\.identifier) == ["sync_c", "sync_a", "sync_b"])
    }
}

@Suite("Manual session order edits")
struct ManualOrderEditTests {

    @Test("Moving a session writes the whole displayed order")
    func moveWritesOrder() {
        let order = SessionOrder.moving(fromOffsets: [0], toOffset: 3, keys: ["a", "b", "c"], manualOrder: [])

        #expect(order == ["b", "c", "a"])
    }

    @Test("Moving works on the displayed order, sessions missing from the stored order included")
    func moveUsesDisplayedOrder() {
        let order = SessionOrder.moving(fromOffsets: [2], toOffset: 0, keys: ["a", "b", "c"], manualOrder: ["c"])

        #expect(order == ["b", "c", "a"])
    }

    @Test("Moving several sessions keeps their relative order")
    func moveSeveral() {
        let order = SessionOrder.moving(fromOffsets: [0, 2], toOffset: 4, keys: ["a", "b", "c", "d"], manualOrder: [])

        #expect(order == ["b", "d", "a", "c"])
    }

    @Test("Moving keeps the keys of absent sessions after the key they followed")
    func moveKeepsAbsentKeys() {
        let order = SessionOrder.moving(
            fromOffsets: [0],
            toOffset: 3,
            keys: ["a", "b", "c"],
            manualOrder: ["a", "gone", "b", "c"]
        )

        #expect(order == ["b", "c", "a", "gone"])
    }

    @Test("Moving keeps absent keys that led the order at the front")
    func moveKeepsLeadingAbsentKeys() {
        let order = SessionOrder.moving(
            fromOffsets: [1],
            toOffset: 0,
            keys: ["a", "b"],
            manualOrder: ["gone", "a", "b"]
        )

        #expect(order == ["gone", "b", "a"])
    }

    @Test("Moving with duplicate session keys stores each key once")
    func moveWithDuplicateKeys() {
        let order = SessionOrder.moving(fromOffsets: [2], toOffset: 0, keys: ["a", "b", "b"], manualOrder: [])

        #expect(order == ["b", "a"])
    }

    @Test("A renamed session takes the old key's place")
    func renameKeepsPlace() {
        let order = SessionOrder.replacing("b", with: "renamed", in: ["a", "b", "c"])

        #expect(order == ["a", "renamed", "c"])
    }

    @Test("Renaming drops an older copy of the new key")
    func renameDropsOlderCopy() {
        let order = SessionOrder.replacing("b", with: "x", in: ["x", "a", "b"])

        #expect(order == ["a", "x"])
    }

    @Test("Renaming a key that is not stored leaves the order alone")
    func renameUnknownKey() {
        let order = SessionOrder.replacing("missing", with: "x", in: ["a", "b"])

        #expect(order == ["a", "b"])
    }

    @Test("Filling in appends the current keys the order lacks, in mutagen's order")
    func filledIn() {
        let order = SessionOrder.filledIn(["c", "gone"], with: ["a", "b", "c"])

        #expect(order == ["c", "gone", "a", "b"])
    }
}

@Suite("SessionStore ordering")
struct SessionStoreOrderingTests {

    private static func makeDefaults() -> (UserDefaults, String) {
        let suite = "HelixKitTests.ordering.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    private let sessions = [
        makeSyncSession(id: "sync_a", name: "alpha"),
        makeSyncSession(id: "sync_b", name: "bravo"),
        makeSyncSession(id: "sync_c", name: "charlie"),
    ]

    @Test("Defaults to the manual sort mode")
    @MainActor
    func defaultsToManual() {
        let store = SessionStore(provider: FakeProvider())

        #expect(store.sortMode == .manual)
    }

    @Test("Session lists follow the sort mode")
    @MainActor
    func listsFollowSortMode() async {
        let store = SessionStore(provider: FakeProvider(syncSessions: sessions.reversed()))
        await store.refresh()

        store.sortMode = .name

        #expect(store.syncSessions.map(\.identifier) == ["sync_a", "sync_b", "sync_c"])
    }

    @Test("Moving sync sessions reorders them and persists the order")
    @MainActor
    func moveSyncPersists() async {
        let (defaults, suite) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(provider: FakeProvider(syncSessions: sessions), defaults: defaults)
        await store.refresh()

        store.moveSyncSessions(fromOffsets: [2], toOffset: 0)

        #expect(store.syncSessions.map(\.identifier) == ["sync_c", "sync_a", "sync_b"])
        let reloaded = SessionStore(provider: FakeProvider(syncSessions: sessions), defaults: defaults)
        await reloaded.refresh()
        #expect(reloaded.syncSessions.map(\.identifier) == ["sync_c", "sync_a", "sync_b"])
    }

    @Test("Moving forward sessions keeps an order of their own")
    @MainActor
    func moveForwardPersists() async {
        let (defaults, suite) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let forwards = [
            makeForwardSession(id: "fwd_a", name: "alpha"),
            makeForwardSession(id: "fwd_b", name: "bravo"),
        ]
        let provider = FakeProvider(syncSessions: sessions, forwardSessions: forwards)
        let store = SessionStore(provider: provider, defaults: defaults)
        await store.refresh()

        store.moveForwardSessions(fromOffsets: [1], toOffset: 0)

        #expect(store.forwardSessions.map(\.identifier) == ["fwd_b", "fwd_a"])
        #expect(store.syncSessions.map(\.identifier) == ["sync_a", "sync_b", "sync_c"])
        let reloaded = SessionStore(provider: provider, defaults: defaults)
        await reloaded.refresh()
        #expect(reloaded.forwardSessions.map(\.identifier) == ["fwd_b", "fwd_a"])
    }

    @Test("A poll that only bumps cycle counters leaves a reordered list untouched")
    @MainActor
    func pollKeepsReorderedListStable() async {
        let store = SessionStore(provider: FakeProvider(syncSessions: sessions))
        await store.refresh()
        store.moveSyncSessions(fromOffsets: [2], toOffset: 0)
        store.replaceProvider(FakeProvider(syncSessions: sessions.map {
            makeSyncSession(id: $0.identifier, name: $0.name, successfulCycles: 5)
        }))
        var changed = false
        withObservationTracking {
            _ = store.syncSessions
        } onChange: {
            changed = true
        }

        await store.refresh()

        #expect(!changed)
    }

    @Test("Date Created mode shows mutagen's order after a manual reorder")
    @MainActor
    func createdModeAfterReorder() async {
        let store = SessionStore(provider: FakeProvider(syncSessions: sessions))
        await store.refresh()
        store.moveSyncSessions(fromOffsets: [2], toOffset: 0)

        store.sortMode = .created

        #expect(store.syncSessions.map(\.identifier) == ["sync_a", "sync_b", "sync_c"])
    }

    @Test("Moving does nothing outside the manual sort mode")
    @MainActor
    func moveIgnoredOutsideManual() async {
        let store = SessionStore(provider: FakeProvider(syncSessions: sessions))
        await store.refresh()
        store.sortMode = .created

        store.moveSyncSessions(fromOffsets: [2], toOffset: 0)
        store.sortMode = .manual

        #expect(store.syncSessions.map(\.identifier) == ["sync_a", "sync_b", "sync_c"])
    }

    @Test("The sort mode persists")
    @MainActor
    func sortModePersists() {
        let (defaults, suite) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(provider: FakeProvider(), defaults: defaults)

        store.sortMode = .status

        #expect(SessionStore(provider: FakeProvider(), defaults: defaults).sortMode == .status)
    }

    @Test("An unreadable stored sort mode falls back to manual")
    @MainActor
    func unreadableSortMode() {
        let (defaults, suite) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("bogus", forKey: SessionStore.sortModeKey)

        #expect(SessionStore(provider: FakeProvider(), defaults: defaults).sortMode == .manual)
    }

    @Test("A renamed session keeps its position after recreate")
    @MainActor
    func recreateRenamedKeepsPosition() async {
        let renamed = makeSyncSession(id: "sync_new", name: "renamed")
        let recorder = RecordingProvider(
            syncSessions: sessions,
            sessionsAfterCreate: [sessions[0], sessions[2], renamed]
        )
        let store = SessionStore(provider: recorder)
        await store.refresh()

        var options = SyncCreateOptions()
        options.name = "renamed"
        await store.recreateSync(sessions[1], options: options, alpha: "/tmp/a", beta: "/tmp/b")

        #expect(store.syncSessions.map(\.identifier) == ["sync_a", "sync_new", "sync_c"])
    }

    @Test("An edited session keeps its dragged position after recreate")
    @MainActor
    func recreateKeepsDraggedPosition() async {
        let edited = makeSyncSession(id: "sync_new", name: "bravo")
        let recorder = RecordingProvider(
            syncSessions: sessions,
            sessionsAfterCreate: [sessions[0], sessions[2], edited]
        )
        let store = SessionStore(provider: recorder)
        await store.refresh()
        store.moveSyncSessions(fromOffsets: [1], toOffset: 0)

        var options = SyncCreateOptions()
        options.name = "bravo"
        await store.recreateSync(sessions[1], options: options, alpha: "/tmp/a", beta: "/tmp/b")

        #expect(store.syncSessions.map(\.identifier) == ["sync_new", "sync_a", "sync_c"])
    }

    @Test("A recreated session keeps its position when a poll lands during terminate")
    @MainActor
    func recreateKeepsPositionAcrossPoll() async {
        let renamed = makeSyncSession(id: "sync_new", name: "renamed")
        let provider = PollingDuringTerminateProvider(
            syncSessions: sessions,
            sessionsAfterCreate: [sessions[0], sessions[2], renamed]
        )
        let store = SessionStore(provider: provider)
        await store.refresh()
        provider.onTerminate = { await store.refresh() }

        var options = SyncCreateOptions()
        options.name = "renamed"
        await store.recreateSync(sessions[1], options: options, alpha: "/tmp/a", beta: "/tmp/b")

        #expect(store.syncSessions.map(\.identifier) == ["sync_a", "sync_new", "sync_c"])
    }

    @Test("An unnamed session keeps its position under its new identifier")
    @MainActor
    func recreateUnnamedKeepsPosition() async {
        let unnamed = makeSyncSession(id: "sync_old", name: nil)
        let recreated = makeSyncSession(id: "sync_new", name: nil)
        let recorder = RecordingProvider(
            syncSessions: [sessions[0], unnamed, sessions[2]],
            sessionsAfterCreate: [sessions[0], sessions[2], recreated]
        )
        let store = SessionStore(provider: recorder)
        await store.refresh()

        await store.recreateSync(unnamed, options: SyncCreateOptions(), alpha: "/tmp/a", beta: "/tmp/b")

        #expect(store.syncSessions.map(\.identifier) == ["sync_a", "sync_new", "sync_c"])
    }

    @Test("Terminating a session drops its key from the stored order")
    @MainActor
    func terminateDropsKey() async {
        let (defaults, suite) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(provider: FakeProvider(syncSessions: sessions), defaults: defaults)
        await store.refresh()
        store.moveSyncSessions(fromOffsets: [2], toOffset: 0)

        await store.terminateSync("sync_a")

        #expect(defaults.stringArray(forKey: SessionStore.syncOrderKey) == ["charlie", "bravo"])
    }

    @Test("A failed terminate keeps the key")
    @MainActor
    func failedTerminateKeepsKey() async {
        let (defaults, suite) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["charlie", "alpha"], forKey: SessionStore.syncOrderKey)
        let recorder = RecordingProvider(syncSessions: sessions, failOn: "syncTerminate")
        let store = SessionStore(provider: recorder, defaults: defaults)
        await store.refresh()

        await store.terminateSync("sync_a")

        #expect(defaults.stringArray(forKey: SessionStore.syncOrderKey) == ["charlie", "alpha"])
    }
}

/// Drops a terminated session from the list the way the daemon does, and runs a hook meanwhile.
final class PollingDuringTerminateProvider: SessionProvider, @unchecked Sendable {
    private var syncSessions: [SyncSession]
    private let sessionsAfterCreate: [SyncSession]
    var onTerminate: (@Sendable () async -> Void)?

    init(syncSessions: [SyncSession], sessionsAfterCreate: [SyncSession]) {
        self.syncSessions = syncSessions
        self.sessionsAfterCreate = sessionsAfterCreate
    }

    func syncList() async throws -> [SyncSession] { syncSessions }
    func forwardList() async throws -> [ForwardSession] { [] }
    func daemonRunning() async throws -> Bool { true }
    func version() async throws -> String { "0.18.1" }
    func syncCreate(arguments: [String]) async throws { syncSessions = sessionsAfterCreate }
    func forwardCreate(arguments: [String]) async throws {}
    func syncPause(_ identifier: String) async throws {}
    func syncResume(_ identifier: String) async throws {}
    func syncFlush(_ identifier: String) async throws {}
    func syncReset(_ identifier: String) async throws {}
    func syncTerminate(_ identifier: String) async throws {
        syncSessions.removeAll { $0.identifier == identifier }
        await onTerminate?()
    }
    func forwardPause(_ identifier: String) async throws {}
    func forwardResume(_ identifier: String) async throws {}
    func forwardTerminate(_ identifier: String) async throws {}
    func daemonStart() async throws {}
    func daemonStop() async throws {}
    func daemonRegister() async throws {}
    func daemonUnregister() async throws {}
}
