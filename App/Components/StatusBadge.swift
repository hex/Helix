// ABOUTME: Status indicator for session health display: one symbol and color per sync phase.
// ABOUTME: Maps mutagen status strings to symbols and semantic colors through SyncPhase.

import SwiftUI
import HelixKit

struct StatusBadge: View {
    let status: String
    let paused: Bool

    init(status: String, paused: Bool = false) {
        self.status = status
        self.paused = paused
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .accessibilityLabel(label)
    }

    var symbol: String {
        if paused { return "pause.circle.fill" }

        switch SyncPhase(mutagenStatus: status) {
        case .watching:
            return "checkmark.circle.fill"
        case .working:
            return "arrow.triangle.2.circlepath"
        case .halted:
            return "exclamationmark.octagon.fill"
        case .connecting:
            return "ellipsis.circle.fill"
        case .disconnected:
            return "xmark.circle.fill"
        case .unrecognized:
            return "questionmark.circle.fill"
        }
    }

    var color: Color {
        if paused { return .secondary }

        switch SyncPhase(mutagenStatus: status) {
        case .watching:
            return .green
        case .working:
            return .blue
        case .halted:
            return .orange
        case .connecting:
            return .yellow
        case .disconnected:
            return .red
        case .unrecognized:
            return .secondary
        }
    }

    var label: String {
        if paused { return "Paused" }
        return status.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
