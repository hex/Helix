// ABOUTME: Primary management window with sidebar navigation and session content area.
// ABOUTME: Supports filtering by type (sync/forward) and status (healthy/conflicts/paused).

import SwiftUI
import HelixKit

enum SidebarFilter: Hashable {
    case all
    case sync
    case forward
    case conflicts
    case paused
    case label(key: String, value: String)
}

struct MainWindow: View {
    let store: SessionStore
    @State private var selectedFilter: SidebarFilter = .all
    @State private var selectedSyncSession: SyncSession?
    @State private var selectedForwardSession: ForwardSession?
    @State private var searchText = ""
    @State private var showCreateSync = false
    @State private var showCreateForward = false
    @AppStorage("showConsole") private var showConsole = false
    @State private var labelsExpanded = true

    var body: some View {
        VSplitView {
            NavigationSplitView {
                sidebar
            } content: {
                sessionList
            } detail: {
                detailView
            }

            if showConsole {
                ConsoleView()
                    .frame(minHeight: 100, idealHeight: 180, maxHeight: 300)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Sync Session...") {
                        showCreateSync = true
                    }
                    Button("Forward Session...") {
                        showCreateForward = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create Session")

                Button {
                    Task { await store.manualRefresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Sessions")
                .accessibilityLabel("Refresh Sessions")

                Button {
                    showConsole.toggle()
                } label: {
                    Image(systemName: "terminal")
                }
                .help("Toggle Console")
                .accessibilityLabel("Toggle Console")

                SettingsLink {
                    Image(systemName: "gear")
                }
            }
        }
        .sheet(isPresented: $showCreateSync) {
            CreateSyncView(store: store)
        }
        .sheet(isPresented: $showCreateForward) {
            CreateForwardView(store: store)
        }
        .focusedSceneValue(\.showCreateSync, $showCreateSync)
        .focusedSceneValue(\.showCreateForward, $showCreateForward)
        .task {
            await store.refresh()
        }
        .onChange(of: store.syncSessions) {
            guard let selected = selectedSyncSession else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedSyncSession = store.syncSessions.first { $0.identifier == selected.identifier }
            }
        }
        .onChange(of: store.forwardSessions) {
            guard let selected = selectedForwardSession else { return }
            selectedForwardSession = store.forwardSessions.first { $0.identifier == selected.identifier }
        }
        .onChange(of: store.pendingSessionSelection, initial: true) {
            guard let id = store.pendingSessionSelection else { return }
            store.pendingSessionSelection = nil
            if let sync = store.syncSessions.first(where: { $0.identifier == id }) {
                selectedSyncSession = sync
                selectedForwardSession = nil
            } else if let fwd = store.forwardSessions.first(where: { $0.identifier == id }) {
                selectedForwardSession = fwd
                selectedSyncSession = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedFilter) {
                Section {
                    Label("All Sessions", systemImage: "list.bullet")
                        .badge(store.totalSessionCount)
                        .tag(SidebarFilter.all)
                }

                Section("Type") {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        .badge(store.syncSessions.count)
                        .tag(SidebarFilter.sync)
                    Label("Forward", systemImage: "network")
                        .badge(store.forwardSessions.count)
                        .tag(SidebarFilter.forward)
                }

                Section("Status") {
                    if store.totalConflictCount > 0 {
                        Label("Conflicts", systemImage: "exclamationmark.triangle")
                            .badge(store.totalConflictCount)
                            .tag(SidebarFilter.conflicts)
                    }
                    let pausedCount = store.syncSessions.filter(\.paused).count
                        + store.forwardSessions.filter(\.paused).count
                    if pausedCount > 0 {
                        Label("Paused", systemImage: "pause.circle")
                            .badge(pausedCount)
                            .tag(SidebarFilter.paused)
                    }
                }

                if !allLabels.isEmpty {
                    Section("Labels", isExpanded: $labelsExpanded) {
                        ForEach(allLabels, id: \.self) { pair in
                            Label("\(pair.key)=\(pair.value)", systemImage: "tag")
                                .badge(labelCount(key: pair.key, value: pair.value))
                                .tag(SidebarFilter.label(key: pair.key, value: pair.value))
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            DaemonStatusView(running: store.daemonRunning)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
    }

    // MARK: - Session List

    private var sessionList: some View {
        List(selection: selectedSessionID) {
            if filteredSyncSessions.isEmpty && filteredForwardSessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("No sessions match the current filter.")
                )
            }

            if !filteredSyncSessions.isEmpty {
                Section("Sync Sessions") {
                    ForEach(filteredSyncSessions) { session in
                        SyncListRow(session: session, store: store, isSelected: selectedSyncSession?.id == session.id)
                    }
                }
            }

            if !filteredForwardSessions.isEmpty {
                Section("Forward Sessions") {
                    ForEach(filteredForwardSessions) { session in
                        ForwardListRow(session: session, isSelected: selectedForwardSession?.id == session.id)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search sessions")
        .navigationSplitViewColumnWidth(min: 250, ideal: 300)
    }

    private var selectedSessionID: Binding<String?> {
        Binding {
            selectedSyncSession?.identifier ?? selectedForwardSession?.identifier
        } set: { id in
            selectedSyncSession = store.syncSessions.first { $0.identifier == id }
            selectedForwardSession = selectedSyncSession == nil
                ? store.forwardSessions.first { $0.identifier == id }
                : nil
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        if let session = selectedSyncSession {
            SyncDetailView(session: session, store: store)
        } else if let session = selectedForwardSession {
            ForwardDetailView(session: session, store: store)
        } else {
            ContentUnavailableView(
                "Select a Session",
                systemImage: "sidebar.left",
                description: Text("Choose a session from the list to view details.")
            )
        }
    }

    // MARK: - Filtering

    private var filteredSyncSessions: [SyncSession] {
        var sessions = store.syncSessions

        switch selectedFilter {
        case .forward:
            return []
        case .conflicts:
            sessions = sessions.filter { ($0.conflicts?.count ?? 0) > 0 }
        case .paused:
            sessions = sessions.filter(\.paused)
        case .label(let key, let value):
            sessions = sessions.filter { $0.labels?[key] == value }
        case .all, .sync:
            break
        }

        if !searchText.isEmpty {
            sessions = sessions.filter { session in
                (session.name?.localizedCaseInsensitiveContains(searchText) ?? false)
                || session.identifier.localizedCaseInsensitiveContains(searchText)
                || (session.alpha.path?.localizedCaseInsensitiveContains(searchText) ?? false)
                || (session.beta.path?.localizedCaseInsensitiveContains(searchText) ?? false)
                || (session.labels?.contains(where: {
                    $0.key.localizedCaseInsensitiveContains(searchText)
                    || $0.value.localizedCaseInsensitiveContains(searchText)
                }) ?? false)
            }
        }

        return sessions
    }

    private var filteredForwardSessions: [ForwardSession] {
        var sessions = store.forwardSessions

        switch selectedFilter {
        case .sync, .conflicts:
            return []
        case .paused:
            sessions = sessions.filter(\.paused)
        case .label(let key, let value):
            sessions = sessions.filter { $0.labels?[key] == value }
        case .all, .forward:
            break
        }

        if !searchText.isEmpty {
            sessions = sessions.filter { session in
                (session.name?.localizedCaseInsensitiveContains(searchText) ?? false)
                || session.identifier.localizedCaseInsensitiveContains(searchText)
                || (session.labels?.contains(where: {
                    $0.key.localizedCaseInsensitiveContains(searchText)
                    || $0.value.localizedCaseInsensitiveContains(searchText)
                }) ?? false)
            }
        }

        return sessions
    }

    // MARK: - Label Helpers

    private struct LabelPair: Hashable {
        let key: String
        let value: String
    }

    private var allLabels: [LabelPair] {
        var pairs = Set<LabelPair>()
        for session in store.syncSessions {
            for (key, value) in session.labels ?? [:] {
                pairs.insert(LabelPair(key: key, value: value))
            }
        }
        for session in store.forwardSessions {
            for (key, value) in session.labels ?? [:] {
                pairs.insert(LabelPair(key: key, value: value))
            }
        }
        return pairs.sorted { $0.key == $1.key ? $0.value < $1.value : $0.key < $1.key }
    }

    private func labelCount(key: String, value: String) -> Int {
        let syncCount = store.syncSessions.filter { $0.labels?[key] == value }.count
        let fwdCount = store.forwardSessions.filter { $0.labels?[key] == value }.count
        return syncCount + fwdCount
    }
}

// MARK: - List Row Views

private struct SyncListRow: View {
    let session: SyncSession
    let store: SessionStore
    let isSelected: Bool
    @Environment(\.backgroundProminence) private var backgroundProminence
    @State private var gitCheck: GitRepoCheck = GitRepoCheck(status: .unknown)
    @AppStorage("dismissedGitMismatches") private var dismissedJSON = "[]"

    private var hasVisibleMismatch: Bool {
        guard gitCheck.status == .alphaOnly || gitCheck.status == .betaOnly else { return false }
        guard gitCheck.hasRemote else { return false }
        let dismissed = (try? JSONDecoder().decode(Set<String>.self, from: Data(dismissedJSON.utf8))) ?? []
        return !dismissed.contains(session.identifier)
    }

    private var isHighlighted: Bool { backgroundProminence == .increased }

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(status: session.status, paused: session.paused)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name ?? String(session.identifier.prefix(12)))
                    .fontWeight(isSelected ? .semibold : .regular)
                HStack(spacing: 4) {
                    Text(session.alpha.protocol_)
                        .foregroundStyle(isHighlighted ? .white.opacity(0.7) : .blue)
                    Image(systemName: (session.mode ?? "two-way-safe").hasPrefix("one-way") ? "arrow.right" : "arrow.left.arrow.right")
                        .font(.caption2)
                        .foregroundStyle(isHighlighted ? .white.opacity(0.5) : .secondary)
                    Text(session.beta.protocol_)
                        .foregroundStyle(isHighlighted ? .white.opacity(0.7) : .purple)
                }
                .font(.caption)

                if let labels = session.labels, !labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(labels.values.sorted(), id: \.self) { value in
                            Text(value)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(isHighlighted ? .white.opacity(0.2) : .blue.opacity(0.1))
                                .foregroundStyle(isHighlighted ? .white.opacity(0.9) : .blue)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Spacer()

            if hasVisibleMismatch {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(isHighlighted ? .white.opacity(0.7) : .orange)
                    .help("Git repository mismatch")
            }

            if let conflicts = session.conflicts, !conflicts.isEmpty {
                Text("\(conflicts.count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        }
        .contentShape(Rectangle())
        .task(id: "\(session.identifier):\(store.refreshCount)") {
            gitCheck = await store.gitRepoStatus(for: session)
        }
    }
}

private struct ForwardListRow: View {
    let session: ForwardSession
    let isSelected: Bool
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var isHighlighted: Bool { backgroundProminence == .increased }

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(
                status: session.source.connected == true ? "watching" : "disconnected",
                paused: session.paused
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name ?? String(session.identifier.prefix(12)))
                    .fontWeight(isSelected ? .semibold : .regular)
                Text("\(session.sourceEndpoint ?? "?") -> \(session.destinationEndpoint ?? "?")")
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? .white.opacity(0.7) : .secondary)

                if let labels = session.labels, !labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(labels.values.sorted(), id: \.self) { value in
                            Text(value)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(isHighlighted ? .white.opacity(0.2) : .blue.opacity(0.1))
                                .foregroundStyle(isHighlighted ? .white.opacity(0.9) : .blue)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Spacer()

            Image(systemName: "network")
                .font(.caption)
                .foregroundStyle(isHighlighted ? Color.white.opacity(0.5) : Color.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Daemon Status

private struct DaemonStatusView: View {
    let running: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(running ? .green : .red)
                .frame(width: 6, height: 6)
            Text("Daemon: \(running ? "Running" : "Stopped")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
