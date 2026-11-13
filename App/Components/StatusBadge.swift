// ABOUTME: Color-coded status indicator dot for session health display.
// ABOUTME: Maps mutagen status strings to semantic colors.

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
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(color)
            .accessibilityLabel(label)
    }

    var color: Color {
        if paused { return .secondary }

        switch SyncPhase(status: status) {
        case .watching:
            return .green
        case .syncing:
            return .blue
        case .stalled:
            return .orange
        case .connecting:
            return .yellow
        case .disconnected:
            return .red
        case .unknown:
            return .secondary
        }
    }

    var label: String {
        if paused { return "Paused" }
        return status.capitalized
    }
}
