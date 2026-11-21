// ABOUTME: Classifies the status strings mutagen 0.18 reports for a sync session.
// ABOUTME: One mapping shared by health aggregation and the status badge.

import Foundation

public enum SyncPhase: Sendable, Equatable {
    case disconnected
    case halted
    case connecting
    case watching
    /// Scanning, reconciling, staging, transitioning or saving: a cycle is in progress.
    case working
    /// A status this mapping does not know, including mutagen's own "unknown".
    case unrecognized

    public init(mutagenStatus: String) {
        switch mutagenStatus {
        case "disconnected":
            self = .disconnected
        case "halted-on-root-emptied", "halted-on-root-deletion", "halted-on-root-type-change":
            self = .halted
        case "connecting-alpha", "connecting-beta":
            self = .connecting
        case "watching":
            self = .watching
        case "scanning", "waiting-for-rescan", "reconciling", "staging-alpha", "staging-beta",
             "transitioning", "saving":
            self = .working
        default:
            self = .unrecognized
        }
    }
}

extension SyncSession {
    public var phase: SyncPhase { SyncPhase(mutagenStatus: status) }
}
