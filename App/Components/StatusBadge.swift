// ABOUTME: Status indicator for session health display: one symbol and color per sync phase.
// ABOUTME: Maps mutagen status strings to symbols and semantic colors through SyncPhase.

import SwiftUI
import HelixKit

struct StatusBadge: View {
    let status: String
    let paused: Bool
    /// Fraction of a transfer that is complete; drawn as a ring in place of the symbol.
    let progress: Double?

    init(status: String, paused: Bool = false, progress: Double? = nil) {
        self.status = status
        self.paused = paused
        self.progress = progress
    }

    var body: some View {
        if let progress, !paused {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
        } else {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .accessibilityLabel(label)
        }
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
