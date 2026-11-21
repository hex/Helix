// ABOUTME: Detailed view for a sync session showing endpoints, configuration, and conflicts.
// ABOUTME: Provides action buttons for pause/resume, flush, reset, and terminate.

import SwiftUI
import HelixKit

struct SyncDetailView: View {
    let session: SyncSession
    let store: SessionStore
    @State private var showTerminateConfirmation = false
    @State private var showRemoveOriginalConfirmation = false
    @State private var showResetConfirmation = false
    @State private var showEditSheet = false
    @State private var actionInProgress: String?
    @State private var gitCheck: GitRepoCheck = GitRepoCheck(status: .unknown)
    @State private var isFixingGit = false
    @State private var showManualFix = false
    @State private var showGuidance = false
    @State private var isBulkResolving = false
    @State private var resolvingRoots: Set<String> = []
    @State private var showDangerZone = false
    @State private var sourceRemoteURL: String?
    @State private var sourceBranch: String?
    @AppStorage("dismissedGitMismatches") private var dismissedJSON = "[]"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                endpointsSection
                if session.alpha.hasProblems || session.beta.hasProblems {
                    endpointProblemsSection
                }
                if (gitCheck.status == .alphaOnly || gitCheck.status == .betaOnly) && gitCheck.hasRemote && !isGitMismatchDismissed {
                    gitMismatchBanner
                }
                configurationSection
                if !visibleConflicts.isEmpty {
                    conflictsSection(visibleConflicts)
                        .transition(.opacity)
                } else if let excluded = session.excludedConflicts, excluded > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Conflicts").font(.headline)
                        omittedCount(excluded)
                    }
                }
                dangerZone
            }
            .padding()
        }
        .navigationTitle(session.name ?? session.identifier)
        .confirmationDialog(
            "Reset Session?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Task { await store.resetSync(session.identifier) }
            }
        } message: {
            Text("This clears the sync history. Both sides will be re-scanned and current contents treated as the baseline.")
        }
        .confirmationDialog(
            "Terminate Session?",
            isPresented: $showTerminateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Terminate", role: .destructive) {
                Task { await store.terminateSync(session.identifier) }
            }
        } message: {
            Text("This permanently removes the session. It cannot be undone.")
        }
        .confirmationDialog(
            "Remove Original Session?",
            isPresented: $showRemoveOriginalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove original", role: .destructive) {
                Task { await runAction("remove original") { await store.removeLeftoverSyncOriginal(session.identifier) } }
            }
        } message: {
            Text("Permanently remove the original session. The edited session must still be running.")
        }
        .sheet(isPresented: $showEditSheet) {
            EditSyncConfigView(session: session, store: store)
        }
        .task(id: "\(session.identifier):\(store.refreshCount):\(session.alpha.connected == true):\(session.beta.connected == true)") {
            gitCheck = await store.gitRepoStatus(for: session)
            if gitCheck.status == .alphaOnly || gitCheck.status == .betaOnly {
                let info = await store.gitSourceInfo(for: session, gitCheck: gitCheck)
                sourceRemoteURL = info.remoteURL
                sourceBranch = info.branch
            }
        }
        .onChange(of: session.conflicts) {
            // Keep resolution markers only for conflicts Mutagen still reports.
            let currentRoots = Set((session.conflicts ?? []).map(\.root))
            resolvingRoots = resolvingRoots.intersection(currentRoots)
        }
    }

    // MARK: - Header

    private func transferSection(_ progress: TransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Text(transferSummary(progress))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if let path = progress.currentPath {
                HStack(spacing: 6) {
                    Text(path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                    Text(currentFileSize(progress))
                        .font(.caption)
                        .monospacedDigit()
                        .layoutPriority(1)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func transferSummary(_ progress: TransferProgress) -> String {
        var parts = ["\(progress.receivedFiles.formatted()) of \(progress.expectedFiles.formatted()) files"]
        let received = Int64(progress.receivedBytes).formatted(.byteCount(style: .file))
        if let expected = progress.expectedBytes {
            parts.append("\(received) of \(Int64(expected).formatted(.byteCount(style: .file)))")
        } else {
            parts.append(received)
        }
        if let fraction = progress.fraction {
            parts.append(fraction.formatted(.percent.precision(.fractionLength(0))))
        }
        return parts.joined(separator: " · ")
    }

    private func currentFileSize(_ progress: TransferProgress) -> String {
        let received = Int64(progress.currentReceivedBytes).formatted(.byteCount(style: .file))
        guard let expected = progress.currentExpectedBytes else { return received }
        return "\(received) of \(Int64(expected).formatted(.byteCount(style: .file)))"
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.name ?? session.identifier)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()

                actionButtons
            }

            HStack {
                StatusBadge(status: session.status, paused: session.paused)
                Text(StatusBadge(status: session.status, paused: session.paused).label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let sessionError = session.lastError, !sessionError.isEmpty {
                Text(sessionError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }

            if let hold = store.sessionHolds[session.identifier] {
                Text(hold)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }

            if let notice = store.leftoverNotices[session.identifier] {
                HStack(alignment: .firstTextBaseline) {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button("Dismiss") {
                        store.dismissLeftoverNotice(for: session.identifier)
                    }
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }

            if let replacement = store.leftoverSyncOriginals[session.identifier] {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Helix blocks Resume on this original while the edited session \(replacement) is listed.")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button("Remove original") {
                        showRemoveOriginalConfirmation = true
                    }
                    .controlSize(.small)
                    .disabled(actionInProgress != nil)
                }
                .font(.callout)
            }

            if let progress = session.transferProgress {
                transferSection(progress)
            }

            HStack(spacing: 16) {
                Label((session.mode ?? "two-way-safe").replacingOccurrences(of: "-", with: " ").capitalized, systemImage: "arrow.triangle.2.circlepath")
                if let cycles = session.successfulCycles {
                    Label("\(cycles) cycles", systemImage: "checkmark.circle")
                }
                Label(session.creationTime.prefix(10).description, systemImage: "calendar")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let labels = session.labels, !labels.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        Text("\(key): \(value)")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
            }

            if let error = errorNotShownAbove {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }
        }
    }

    /// The store's last error, unless it repeats this session's hold or leftover notice shown above.
    private var errorNotShownAbove: String? {
        guard let error = store.lastError else { return nil }
        if store.sessionHolds[session.identifier] == error { return nil }
        if let notice = store.leftoverNotices[session.identifier], notice.hasSuffix(error) { return nil }
        return error
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if actionInProgress != nil {
                ProgressView()
                    .controlSize(.small)
            }

            if session.paused {
                Button("Resume") {
                    Task { await runAction("resume") { await store.resumeSync(session.identifier) } }
                }
                .disabled(actionInProgress != nil || store.isResolving(session.identifier))
            } else {
                Button("Pause") {
                    Task { await runAction("pause") { await store.pauseSync(session.identifier) } }
                }
                .disabled(actionInProgress != nil)
            }

            Button("Flush") {
                Task { await runAction("flush") { await store.flushSync(session.identifier) } }
            }
            .disabled(session.paused || actionInProgress != nil)

            Button("Reset") {
                showResetConfirmation = true
            }
            .disabled(actionInProgress != nil)
        }
        .controlSize(.small)
    }

    private func runAction(_ name: String, _ action: () async -> Void) async {
        actionInProgress = name
        await action()
        actionInProgress = nil
    }

    // MARK: - Endpoints

    private var endpointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Endpoints")
                .font(.headline)

            HStack(alignment: .top, spacing: 0) {
                EndpointCard(label: "Alpha", color: .blue, endpoint: session.alpha)

                VStack(spacing: 4) {
                    Image(systemName: isOneWay ? "arrow.right" : "arrow.left.arrow.right")
                        .font(.callout)
                    Text(syncModeLabel)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .frame(width: 56)
                .padding(.top, 16)

                EndpointCard(label: "Beta", color: .purple, endpoint: session.beta)
            }
        }
    }

    private var visibleConflicts: [Conflict] {
        (session.conflicts ?? []).filter { !resolvingRoots.contains($0.root) }
    }

    private var isOneWay: Bool {
        (session.mode ?? "two-way-safe").hasPrefix("one-way")
    }

    private var syncModeLabel: String {
        switch session.mode ?? "two-way-safe" {
        case "two-way-safe": "Two-Way"
        case "two-way-resolved": "Resolved"
        case "one-way-safe": "One-Way"
        case "one-way-replica": "Replica"
        default: session.mode ?? "sync"
        }
    }

    // MARK: - Git Mismatch Banner

    private var gitMismatchBanner: some View {
        let hasGitLabel = gitCheck.status == .alphaOnly ? "Alpha" : "Beta"
        let hasGitColor: Color = gitCheck.status == .alphaOnly ? .blue : .purple
        let missingGitLabel = gitCheck.status == .alphaOnly ? "Beta" : "Alpha"
        let missingGitColor: Color = gitCheck.status == .alphaOnly ? .purple : .blue
        let missingEndpoint = gitCheck.status == .alphaOnly ? session.beta : session.alpha
        let basePath = missingEndpoint.path ?? "<path>"
        let missingPath = gitCheck.subpath.isEmpty ? basePath : (basePath as NSString).appendingPathComponent(gitCheck.subpath)
        let subpathNote = gitCheck.subpath.isEmpty ? "" : " (in \(gitCheck.subpath)/)"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Git Repository Mismatch\(subpathNote)")
                    .font(.headline)
                Spacer()
                Button("Dismiss") { dismissGitMismatch() }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            (Text(hasGitLabel).foregroundStyle(hasGitColor).fontWeight(.semibold)
             + Text(" has a .git directory, but ")
             + Text(missingGitLabel).foregroundStyle(missingGitColor).fontWeight(.semibold)
             + Text(" does not. This typically happens when .git is excluded from sync (which is correct) but only one side has been initialized as a git repo."))
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    isFixingGit = true
                    let success = await store.fixGitMismatch(session: session, gitCheck: gitCheck)
                    if success {
                        gitCheck = await store.gitRepoStatus(for: session)
                    }
                    isFixingGit = false
                }
            } label: {
                if isFixingGit {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Initializing git...")
                    }
                } else {
                    Label("Fix Automatically", systemImage: "wand.and.stars")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isFixingGit || sourceRemoteURL == nil)

            if sourceRemoteURL == nil {
                Label {
                    Text("No git remote configured on the ")
                    + Text(hasGitLabel).foregroundStyle(hasGitColor).fontWeight(.semibold)
                    + Text(" endpoint. Add a remote first, or use the manual commands below.")
                } icon: {
                    Image(systemName: "info.circle.fill")
                }
                .font(.callout)
                .foregroundStyle(.orange)
            }

            DisclosureGroup(isExpanded: $showManualFix) {
                VStack(alignment: .leading, spacing: 4) {
                    (Text("Run these commands on the ")
                     + Text(missingGitLabel).foregroundStyle(missingGitColor).fontWeight(.semibold)
                     + Text(" endpoint:"))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    let commands = """
                    cd \(missingPath)
                    git init
                    git remote add origin \(sourceRemoteURL ?? "<remote-url>")
                    git fetch origin
                    git reset --mixed origin/\(sourceBranch ?? "<branch>")
                    """

                    Text(commands)
                        .font(.caption)
                        .monospaced()
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .padding(.top, 4)
            } label: {
                Label("How to fix manually", systemImage: "wrench")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { showManualFix.toggle() }
            }
        }
        .padding()
        .background(.orange.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var isGitMismatchDismissed: Bool {
        let dismissed = (try? JSONDecoder().decode(Set<String>.self, from: Data(dismissedJSON.utf8))) ?? []
        return dismissed.contains(session.identifier)
    }

    private func dismissGitMismatch() {
        var dismissed = (try? JSONDecoder().decode(Set<String>.self, from: Data(dismissedJSON.utf8))) ?? []
        dismissed.insert(session.identifier)
        if let data = try? JSONEncoder().encode(dismissed) {
            dismissedJSON = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    // MARK: - Endpoint Problems

    private var endpointProblemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Endpoint Problems")
                .font(.headline)
            endpointProblems(session.alpha, title: "Alpha")
            endpointProblems(session.beta, title: "Beta")
        }
    }

    private func endpointProblems(_ endpoint: Endpoint, title: String) -> some View {
        Group {
            problemList("\(title) Scan", problems: endpoint.scanProblems ?? [], excluded: endpoint.excludedScanProblems ?? 0)
            problemList("\(title) Transition", problems: endpoint.transitionProblems ?? [], excluded: endpoint.excludedTransitionProblems ?? 0)
        }
    }

    @ViewBuilder
    private func problemList(_ title: String, problems: [SyncProblem], excluded: UInt64) -> some View {
        if !problems.isEmpty || excluded > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
                ForEach(problems.indices, id: \.self) { index in
                    let problem = problems[index]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.path.flatMap { $0.isEmpty ? nil : $0 } ?? "(sync root)")
                            .font(.caption.monospaced())
                        Text(problem.error ?? "No error message supplied.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
                if excluded > 0 { omittedCount(excluded) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func omittedCount(_ count: UInt64) -> some View {
        Text("\(count.formatted()) more not shown by mutagen")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Configuration

    private struct ConfigurationRow {
        let label: String
        let value: String
    }

    private var configurationSection: some View {
        let configuration = session.configuration
        let sessionRows = configurationRows(for: configuration)
        let alphaRows = configurationRows(for: session.alpha.configuration, inheriting: configuration)
        let betaRows = configurationRows(for: session.beta.configuration, inheriting: configuration)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Configuration")
                    .font(.headline)
                Spacer()
                Button("Edit") {
                    showEditSheet = true
                }
                .controlSize(.small)
            }

            if sessionRows.isEmpty && alphaRows.isEmpty && betaRows.isEmpty {
                Text("All settings use Mutagen defaults.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                configurationGroup("Session", rows: sessionRows)
                configurationGroup("Alpha Overrides", rows: alphaRows)
                configurationGroup("Beta Overrides", rows: betaRows)
            }
        }
    }

    @ViewBuilder
    private func configurationGroup(_ label: String, rows: [ConfigurationRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.callout)
                    .fontWeight(.semibold)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.label) { row in
                        configRow(row.label, row.value)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func configurationRows(
        for configuration: SyncConfiguration,
        inheriting inherited: SyncConfiguration? = nil
    ) -> [ConfigurationRow] {
        let defaults = SyncConfiguration.defaults(forVersion: session.version)

        func row<Value: Equatable>(
            _ label: String,
            _ field: KeyPath<SyncConfiguration, Value?>,
            display: (Value) -> String = { String(describing: $0) }
        ) -> ConfigurationRow? {
            let baseline = inherited?[keyPath: field] ?? defaults[keyPath: field]
            guard let value = configuration[keyPath: field], value != baseline else { return nil }
            return ConfigurationRow(label: label, value: display(value))
        }

        let ignores = configuration.ignore?.paths ?? []
        let rows: [ConfigurationRow?] = [
            row("Mode", \.mode),
            row("Hash", \.hash),
            row("Max entries", \.maxEntryCount) { $0.formatted() },
            row("Max staging file size", \.maxStagingFileSize) { "\($0.formatted()) bytes" },
            row("Probe mode", \.probeMode),
            row("Scan mode", \.scanMode),
            row("Stage mode", \.stageMode),
            ignores.isEmpty ? nil : ConfigurationRow(label: "Ignore rules", value: ignores.joined(separator: "\n")),
            row("Ignore syntax", \.ignore?.syntax),
            row("VCS directories", \.ignore?.vcs) { $0 ? "Ignore" : "Propagate" },
            row("Symlinks", \.symlink?.mode),
            row("Watch", \.watch?.mode),
            row("Watch polling interval", \.watch?.pollingInterval) { "\($0.formatted()) s" },
            row("Permissions", \.permissions?.mode),
            row("Default file mode", \.permissions?.defaultFileMode),
            row("Default directory mode", \.permissions?.defaultDirectoryMode),
            row("Default owner", \.permissions?.defaultOwner),
            row("Default group", \.permissions?.defaultGroup),
            row("Compression", \.compression?.algorithm),
        ]
        return rows.compactMap { $0 }
    }

    private func configRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
    }

    // MARK: - Conflicts

    private func conflictsSection(_ conflicts: [Conflict]) -> some View {
        let grouped = conflictGroups(conflicts)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Conflicts (\(conflicts.count))")
                    .font(.headline)
                Spacer()
                Button("Reset Session") {
                    showResetConfirmation = true
                }
                .controlSize(.small)
            }

            if let excluded = session.excludedConflicts, excluded > 0 {
                omittedCount(excluded)
            }

            resolutionGuidance

            if isBulkResolving {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Resolving conflicts...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            ForEach(grouped, id: \.folder) { group in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(group.folder)
                            .font(.callout)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text("(\(group.conflicts.count))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        bulkResolveButtons(conflicts: group.conflicts)
                    }

                    ForEach(group.conflicts) { conflict in
                        ConflictCard(
                            conflict: conflict,
                            session: session,
                            store: store,
                            onResolveStarted: { markResolving(conflict.root) },
                            onResolveEnded: showAgain
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func bulkResolveButtons(conflicts: [Conflict]) -> some View {
        HStack(spacing: 4) {
            Button {
                bulkResolve(conflicts: conflicts, winner: .alpha)
            } label: {
                HStack(spacing: 2) {
                    if session.alpha.protocol_ == "local" {
                        Image(systemName: "laptopcomputer")
                    }
                    Text("Keep All Alpha")
                }
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .controlSize(.mini)
            .disabled(isBulkResolving)

            Button {
                bulkResolve(conflicts: conflicts, winner: .beta)
            } label: {
                HStack(spacing: 2) {
                    if session.beta.protocol_ == "local" {
                        Image(systemName: "laptopcomputer")
                    }
                    Text("Keep All Beta")
                }
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .controlSize(.mini)
            .disabled(isBulkResolving)
        }
    }

    private func bulkResolve(conflicts: [Conflict], winner: ConflictWinner) {
        withAnimation {
            resolvingRoots.formUnion(conflicts.map(\.root))
        }
        isBulkResolving = true
        Task {
            let unresolved = await store.resolveConflicts(session: session, conflicts: conflicts, winner: winner)
            isBulkResolving = false
            showAgain(unresolved)
        }
    }

    private func markResolving(_ root: String) {
        withAnimation {
            resolvingRoots.insert(root)
        }
    }

    /// Brings back the rows of conflicts whose resolve ended without resolving them.
    private func showAgain(_ unresolvedRoots: Set<String>) {
        withAnimation {
            resolvingRoots.subtract(unresolvedRoots)
        }
    }

    private struct ConflictGroup {
        let folder: String
        let conflicts: [Conflict]
    }

    private func conflictGroups(_ conflicts: [Conflict]) -> [ConflictGroup] {
        var groups: [String: [Conflict]] = [:]
        for conflict in conflicts {
            let folder = conflict.root.split(separator: "/").first.map(String.init) ?? "(root)"
            groups[folder, default: []].append(conflict)
        }
        return groups.keys.sorted().map { ConflictGroup(folder: $0, conflicts: groups[$0]!) }
    }

    private var resolutionGuidance: some View {
        DisclosureGroup(isExpanded: $showGuidance) {
            VStack(alignment: .leading, spacing: 8) {
                guidanceRow(
                    icon: "arrow.counterclockwise",
                    title: "Reset Session",
                    body: "Re-scans both endpoints and treats the current state as the new baseline. Conflicts are cleared."
                )
                guidanceRow(
                    icon: "pencil",
                    title: "Manually Resolve",
                    body: "Edit or delete the conflicting files on one endpoint, then flush to sync the resolution."
                )
                guidanceRow(
                    icon: "arrow.right",
                    title: "Switch to Two-Way Resolved",
                    body: "Recreate the session with two-way-resolved mode so alpha always wins conflicts automatically."
                )
            }
            .padding(.top, 4)
        } label: {
            Label("How to resolve conflicts", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture { showGuidance.toggle() }
        }
    }

    private func guidanceRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(body).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    // MARK: - Danger Zone

    private var dangerZone: some View {
        DisclosureGroup(isExpanded: $showDangerZone) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Terminate Session")
                        .font(.callout)
                        .fontWeight(.semibold)
                    Text("Permanently remove this session. This cannot be undone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Terminate", role: .destructive) {
                    showTerminateConfirmation = true
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        } label: {
            Text("Danger Zone")
                .contentShape(Rectangle())
                .onTapGesture { showDangerZone.toggle() }
        }
        .foregroundStyle(.red)
    }
}

// MARK: - Endpoint Card

private struct EndpointCard: View {
    let label: String
    let color: Color
    let endpoint: Endpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(label)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(color)
                }
                Spacer()
                Circle()
                    .fill(endpoint.connected == true ? .green : .red)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(endpoint.connected == true ? "Connected" : "Disconnected")
            }

            endpointRow("Protocol", endpoint.protocol_)
            if let user = endpoint.user {
                endpointRow("User", user)
            }
            endpointRow("Host", displayHost)
            if let path = endpoint.path {
                HStack {
                    Text("Path")
                        .fontWeight(.semibold)
                    Text(path)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Divider()

            if let dirs = endpoint.directories, let files = endpoint.files, let size = endpoint.totalFileSize {
                HStack(spacing: 8) {
                    Text("\(dirs) dirs")
                    Text("\(files) files")
                    Text(formatBytes(size))
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(10)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var displayHost: String {
        endpoint.host ?? ProcessInfo.processInfo.hostName
    }

    private func endpointRow(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
        } label: {
            Text(label).fontWeight(.semibold)
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Conflict Card

private struct ConflictCard: View {
    let conflict: Conflict
    let session: SyncSession
    let store: SessionStore
    var onResolveStarted: (() -> Void)?
    /// Called with the roots the resolve left unresolved.
    var onResolveEnded: ((Set<String>) -> Void)?
    @Environment(\.openWindow) private var openWindow
    @State private var isResolving = false
    @State private var alphaInfo: FileInfo?
    @State private var betaInfo: FileInfo?
    @State private var pendingWinner: ConflictWinner?
    @State private var pendingIgnore = false

    private var hasUntrackedEntries: Bool {
        let allChanges = conflict.alphaChanges + conflict.betaChanges
        return allChanges.contains { $0.new?.kind == "untracked" || $0.old?.kind == "untracked" }
    }

    private var isFileDiff: Bool {
        let allChanges = conflict.alphaChanges + conflict.betaChanges
        return allChanges.contains { ($0.new?.kind ?? $0.old?.kind) == "file" }
    }

    /// Non-nil when one side is a symlink and the other is not.
    private var symlinkResolution: (symlinkSide: ConflictWinner, directorySide: ConflictWinner)? {
        let aLink = alphaInfo?.isSymlink ?? false
        let bLink = betaInfo?.isSymlink ?? false
        if aLink && !bLink { return (symlinkSide: .alpha, directorySide: .beta) }
        if bLink && !aLink { return (symlinkSide: .beta, directorySide: .alpha) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            HStack(alignment: .top, spacing: 8) {
                conflictPane(
                    label: "Alpha (\(session.alpha.shortLabel))",
                    color: .blue,
                    isLocal: session.alpha.protocol_ == "local",
                    changes: conflict.alphaChanges,
                    info: alphaInfo,
                    winner: .alpha,
                    showAction: symlinkResolution?.symlinkSide != .alpha
                )

                if isFileDiff {
                    Button {
                        openWindow(value: DiffRequest(
                            sessionIdentifier: session.identifier,
                            conflictRoot: conflict.root
                        ))
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "rectangle.split.2x1")
                            Text("Diff")
                        }
                        .font(.caption)
                        .frame(maxHeight: .infinity)
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("View Diff")
                    .accessibilityLabel("View Diff")
                }

                conflictPane(
                    label: "Beta (\(session.beta.shortLabel))",
                    color: .purple,
                    isLocal: session.beta.protocol_ == "local",
                    changes: conflict.betaChanges,
                    info: betaInfo,
                    winner: .beta,
                    showAction: symlinkResolution?.symlinkSide != .beta
                )
            }

            if let resolution = symlinkResolution {
                Button {
                    pendingWinner = resolution.directorySide
                } label: {
                    Label("Replace symlink with directory", systemImage: "arrow.triangle.swap")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                .disabled(isResolving)
            }

            if hasUntrackedEntries {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                    Text("Contains entries mutagen cannot track. If resolution fails, try adding to ignore list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        pendingIgnore = true
                    } label: {
                        Label("Ignore", systemImage: "eye.slash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.mini)
                    .disabled(isResolving)
                }
                .padding(8)
                .background(.orange.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if isResolving {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Resolving...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task { await loadFileInfo() }
        .alert(
            "Resolve Conflict",
            isPresented: Binding(
                get: { pendingWinner != nil },
                set: { if !$0 { pendingWinner = nil } }
            )
        ) {
            Button("Replace", role: .destructive) {
                guard let winner = pendingWinner else { return }
                pendingWinner = nil
                onResolveStarted?()
                Task {
                    isResolving = true
                    let unresolved = await store.resolveConflict(session: session, conflict: conflict, winner: winner)
                    isResolving = false
                    onResolveEnded?(unresolved)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingWinner = nil
            }
        } message: {
            let loserLabel = pendingWinner == .alpha ? "Beta" : "Alpha"
            Text("This will permanently delete the \(loserLabel) version of \"\(conflict.root)\" and replace it with the selected side.")
        }
        .alert(
            "Add to Ignore List",
            isPresented: $pendingIgnore
        ) {
            Button("Add to Ignores", role: .destructive) {
                Task {
                    isResolving = true
                    await store.addToIgnoreList(session: session, path: conflict.root)
                    isResolving = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will terminate the session and recreate it with \"\(conflict.root)\" in the ignore list. Sync history will be reset.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.orange)
                .font(.callout)
            Text(conflict.root)
                .font(.callout)
                .monospaced()
                .fontWeight(.semibold)
            Spacer()
            if session.alpha.protocol_ == "local", let base = session.alpha.path {
                Button {
                    let fullPath = (base as NSString).appendingPathComponent(conflict.root)
                    NSWorkspace.shared.selectFile(fullPath, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
            }
            Text("\(conflict.alphaChanges.count + conflict.betaChanges.count) changes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pane

    private func conflictPane(
        label: String,
        color: Color,
        isLocal: Bool = false,
        changes: [Change],
        info: FileInfo?,
        winner: ConflictWinner,
        showAction: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
                if isLocal {
                    Image(systemName: "laptopcomputer")
                        .font(.caption)
                        .foregroundStyle(color)
                        .help("This computer")
                }
                Spacer()
                if let info {
                    if info.isSymlink {
                        Label("Symlink", systemImage: "arrow.triangle.turn.up.right.diamond")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(formatBytes(info.size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let info {
                if info.isSymlink, let target = info.symlinkTarget {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                        Text(target)
                            .font(.caption)
                            .monospaced()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.orange)
                }
                Text(info.modifiedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if changes.isEmpty {
                Text("No changes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                    ChangeLabel(change: change)
                }
            }

            Spacer(minLength: 0)

            if showAction {
                Button {
                    pendingWinner = winner
                } label: {
                    Label("Keep This Side", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(color)
                .controlSize(.small)
                .disabled(isResolving)
            }
        }
        .padding(8)
        .background(color.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helpers

    private func loadFileInfo() async {
        let info = await store.conflictFileInfo(session: session, conflict: conflict)
        alphaInfo = info.alpha
        betaInfo = info.beta
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct ChangeLabel: View {
    let change: Change

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: changeIcon)
                .font(.caption)
                .foregroundStyle(changeColor)
                .frame(width: 14)

            Text(change.path)
                .font(.caption)
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(changeVerb)
                .font(.caption)
                .foregroundStyle(changeColor)
        }
        .padding(.leading, 12)
    }

    private var changeIcon: String {
        if change.old != nil && change.new == nil { return "minus.circle.fill" }
        if change.old == nil && change.new != nil { return "plus.circle.fill" }
        return "arrow.triangle.2.circlepath.circle.fill"
    }

    private var changeColor: Color {
        if change.old != nil && change.new == nil { return .red }
        if change.old == nil && change.new != nil { return .green }
        return .orange
    }

    private var changeVerb: String {
        if let old = change.old, change.new == nil { return "deleted \(old.kind)" }
        if change.old == nil, let new = change.new { return "created \(new.kind)" }
        if let old = change.old, let new = change.new { return "\(old.kind) -> \(new.kind)" }
        return "modified"
    }
}
