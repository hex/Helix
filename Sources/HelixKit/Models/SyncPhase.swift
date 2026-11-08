// ABOUTME: Classifies mutagen's sync status strings into the phases the app shows.
// ABOUTME: Matches the strings mutagen reports, such as staging-alpha and halted-on-root-emptied.

public enum SyncPhase: Sendable, Equatable {
    case watching
    case syncing
    case connecting
    case disconnected
    /// Halted on a root problem, or waiting to retry a failed scan.
    case stalled
    case unknown

    public init(status: String) {
        switch status {
        case "watching":
            self = .watching
        case "scanning", "reconciling", "transitioning", "saving":
            self = .syncing
        case "disconnected":
            self = .disconnected
        case "waiting-for-rescan":
            self = .stalled
        case _ where status.hasPrefix("staging"):
            self = .syncing
        case _ where status.hasPrefix("connecting"):
            self = .connecting
        case _ where status.hasPrefix("halted"):
            self = .stalled
        default:
            self = .unknown
        }
    }
}

extension SyncSession {
    public var phase: SyncPhase { SyncPhase(status: status) }
}
