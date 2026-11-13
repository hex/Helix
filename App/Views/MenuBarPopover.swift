// ABOUTME: Compact popover shown when clicking the menu bar icon.
// ABOUTME: Lists all sessions with status dots and provides quick actions.

import SwiftUI
import HelixKit

struct MenuBarPopover: View {
    let store: SessionStore
    @Environment(\.openWindow) private var openWindow

    private static let maxListHeight: CGFloat = 430

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !store.daemonRunning {
                daemonWarning
            } else if store.totalSessionCount == 0 {
                emptyState
            } else {
                sessionList
            }

            if let error = store.lastError {
                Divider()
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: 320)
        .task {
            await store.refresh()
        }
    }

    private var header: some View {
        HStack {
            Text("Helix")
                .font(.headline)
            Spacer()
            Button("Open Helix") {
                openMainWindow()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var daemonWarning: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Daemon not running")
                .font(.headline)
            Text("Start the mutagen daemon to manage sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No active sessions")
                .font(.headline)
            Text("Mutagen syncs files and forwards ports\nbetween local and remote environments.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Create Your First Session") {
                openMainWindow()
            }
            .controlSize(.small)
        }
        .padding()
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(store.syncSessions) { session in
                    SyncSessionRow(session: session, store: store)
                        .onTapGesture {
                            store.pendingSessionSelection = session.identifier
                            openMainWindow()
                        }
                    Divider().padding(.leading, 28)
                }
                ForEach(store.forwardSessions) { session in
                    ForwardSessionRow(session: session, store: store)
                        .onTapGesture {
                            store.pendingSessionSelection = session.identifier
                            openMainWindow()
                        }
                    Divider().padding(.leading, 28)
                }
            }
        }
        // The menu bar window takes its content's minimum height, so the list's height must be rigid.
        .frame(maxHeight: Self.maxListHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func openMainWindow() {
        NSApp.keyWindow?.close()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Session Rows

private struct SyncSessionRow: View {
    let session: SyncSession
    let store: SessionStore
    @AppStorage(MenuBarPopover.compactListKey) private var compact = false
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 8) {
            StatusBadge(status: session.status, paused: session.paused)
                .padding(.top, compact ? 0 : 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name ?? String(session.identifier.prefix(12)))
                    .font(.body)
                    .lineLimit(1)

                if !compact {
                    Text(endpointSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let cycles = session.successfulCycles, cycles > 0 {
                            Text("\(cycles) cycles")
                        }
                        if let conflicts = session.conflicts, !conflicts.isEmpty {
                            Text("\(conflicts.count) conflicts")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if compact, let conflicts = session.conflicts, !conflicts.isEmpty {
                Text("\(conflicts.count) conflicts")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 4 : 6)
        .help(compact ? endpointSummary : "")
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if session.paused {
                Button("Resume") { Task { await store.resumeSync(session.identifier) } }
            } else {
                Button("Pause") { Task { await store.pauseSync(session.identifier) } }
                Button("Flush") { Task { await store.flushSync(session.identifier) } }
            }
            Divider()
            Button("Terminate", role: .destructive) {
                Task { await store.terminateSync(session.identifier) }
            }
        }
    }

    private var endpointSummary: String {
        let alpha = endpointLabel(session.alpha)
        let beta = endpointLabel(session.beta)
        let arrow = (session.mode ?? "two-way-safe").hasPrefix("one-way") ? "->" : "<->"
        return "\(alpha) \(arrow) \(beta)"
    }

    private func endpointLabel(_ endpoint: Endpoint) -> String {
        switch endpoint.protocol_ {
        case "ssh":
            if let user = endpoint.user, let host = endpoint.host {
                return "\(user)@\(host)"
            }
            return endpoint.host ?? "ssh"
        case "docker":
            return "docker"
        default:
            return "local"
        }
    }
}

private struct ForwardSessionRow: View {
    let session: ForwardSession
    let store: SessionStore
    @AppStorage(MenuBarPopover.compactListKey) private var compact = false
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 8) {
            StatusBadge(
                status: session.source.connected == true ? "watching" : "disconnected",
                paused: session.paused
            )
            .padding(.top, compact ? 0 : 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name ?? String(session.identifier.prefix(12)))
                    .font(.body)
                    .lineLimit(1)

                if !compact {
                    Text(endpointSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "network")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 4 : 6)
        .help(compact ? endpointSummary : "")
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if session.paused {
                Button("Resume") { Task { await store.resumeForward(session.identifier) } }
            } else {
                Button("Pause") { Task { await store.pauseForward(session.identifier) } }
            }
            Divider()
            Button("Terminate", role: .destructive) {
                Task { await store.terminateForward(session.identifier) }
            }
        }
    }

    private var endpointSummary: String {
        let src = session.sourceEndpoint ?? "source"
        let dst = session.destinationEndpoint ?? "destination"
        return "\(src) -> \(dst)"
    }
}

extension MenuBarPopover {
    static let compactListKey = "menuBarCompactList"
}
