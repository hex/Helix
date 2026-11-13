// ABOUTME: Tests for SyncPhase, the classification of mutagen sync status strings.
// ABOUTME: Covers every status mutagen 0.18 reports and an unrecognised one.

import Testing
@testable import HelixKit

@Suite("SyncPhase classification")
struct SyncPhaseTests {

    @Test("Classifies mutagen status strings", arguments: [
        ("watching", SyncPhase.watching),
        ("scanning", .syncing),
        ("reconciling", .syncing),
        ("staging-alpha", .syncing),
        ("staging-beta", .syncing),
        ("transitioning", .syncing),
        ("saving", .syncing),
        ("connecting-alpha", .connecting),
        ("connecting-beta", .connecting),
        ("disconnected", .disconnected),
        ("halted-on-root-emptied", .stalled),
        ("halted-on-root-deletion", .stalled),
        ("halted-on-root-type-change", .stalled),
        ("waiting-for-rescan", .stalled),
        ("some-future-status", .unknown),
    ])
    func classifies(status: String, phase: SyncPhase) {
        #expect(SyncPhase(status: status) == phase)
    }

    @Test("A sync session exposes the phase of its status")
    func sessionPhase() {
        #expect(makeSyncSession(id: "sync_1", name: "s1", status: "staging-beta").phase == .syncing)
    }
}
