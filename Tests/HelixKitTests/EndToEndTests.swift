// ABOUTME: End-to-end scenarios that drive SessionStore against the real mutagen CLI and real local folders.
// ABOUTME: Runs only when HELIX_E2E is set; every session carries this run's label and is terminated by identifier.

import Testing
import Foundation
@testable import HelixKit

/// The value of the helix-e2e label on every session this test process creates.
private let runID = UUID().uuidString.lowercased()

/// Where the scenarios create their endpoint folders: HELIX_E2E_ROOT, or helix-e2e in the temporary directory.
private let scenarioRoot = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["HELIX_E2E_ROOT"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("helix-e2e").path
)

/// One entry under an endpoint root, as compared across the two sides.
private enum TreeEntry: Equatable, CustomStringConvertible {
    case directory
    case file(Data)
    case symlink(String)

    var description: String {
        switch self {
        case .directory: "directory"
        case .file(let data): "file(\(String(data: data, encoding: .utf8).map { "\"\($0)\"" } ?? "\(data.count) bytes"))"
        case .symlink(let target): "symlink(\(target))"
        }
    }
}

private struct ScenarioFailure: Error, CustomStringConvertible {
    let description: String
}

/// The folders, isolated defaults, store and created sessions of one scenario.
@MainActor
private final class Scenario {
    let alpha: URL
    let beta: URL
    let store: SessionStore
    let cli = CLI()
    private let slug: String
    private let token = UUID().uuidString.prefix(8).lowercased()
    private let folder: URL
    /// A path suite, so the defaults live in a plist inside the scenario folder and leave with it.
    private let defaultsSuite: String
    let defaults: UserDefaults
    private var created: Set<String> = []

    init(_ slug: String) throws {
        self.slug = slug
        folder = scenarioRoot.appendingPathComponent("\(slug)-\(token)")
        alpha = folder.appendingPathComponent("alpha")
        beta = folder.appendingPathComponent("beta")
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        defaultsSuite = folder.appendingPathComponent("defaults").path
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw ScenarioFailure(description: "Could not open the defaults suite \(defaultsSuite)")
        }
        self.defaults = defaults
        store = SessionStore(provider: cli, defaults: defaults)
    }

    func name(_ role: String = "session") -> String { "helix-e2e-\(slug)-\(role)-\(token)" }

    func options(name: String) -> SyncCreateOptions {
        var options = SyncCreateOptions()
        options.name = name
        options.labels = ["helix-e2e": runID]
        return options
    }

    func track(_ identifier: String) { created.insert(identifier) }

    /// Creates a session through the store and returns it as the store lists it.
    func createSession(name: String) async throws -> SyncSession {
        let failure = await store.createSync(options: options(name: name), alpha: alpha.path, beta: beta.path)
        let listed = sessions(named: name)
        listed.forEach { track($0.identifier) }
        #expect(failure == nil)
        #expect(listed.count == 1, "Sessions named \(name): \(listed.map(\.identifier))")
        return try #require(listed.first)
    }

    func session(_ identifier: String) -> SyncSession? {
        store.syncSessions.first { $0.identifier == identifier }
    }

    func sessions(named name: String) -> [SyncSession] {
        store.syncSessions.filter { $0.name == name }
    }

    /// Refreshes the store until `condition` holds; throws after `seconds` with what it last observed.
    func waitUntil(
        _ what: String, seconds: Int = 60, observing observed: () -> String, _ condition: () throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)
        while true {
            await store.manualRefresh()
            if try condition() { return }
            if clock.now >= deadline {
                throw ScenarioFailure(description: "Timed out after \(seconds) s waiting until \(what). Last observed: \(observed())")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Waits until the session watches, unpaused and without conflicts, while both roots hold `expected`.
    func waitUntilSettled(_ identifier: String, holding expected: [String: TreeEntry]) async throws {
        try await waitUntil("both roots hold \(expected) and the session watches without conflicts", observing: { describe(identifier) }) {
            guard let session = session(identifier) else { return false }
            let alphaTree = try tree(alpha)
            let betaTree = try tree(beta)
            return session.phase == .watching && !session.paused && (session.conflicts ?? []).isEmpty
                && alphaTree == expected && betaTree == expected
        }
    }

    /// Waits until the session lists a conflict at `root` and returns the session and that conflict.
    func waitForConflict(on identifier: String, root: String) async throws -> (SyncSession, Conflict) {
        try await waitUntil("a conflict at \(root) is listed", observing: { describe(identifier) }) {
            session(identifier)?.conflicts?.contains { $0.root == root } == true
        }
        let session = try #require(session(identifier))
        return (session, try #require(session.conflicts?.first { $0.root == root }))
    }

    func describe(_ identifier: String) -> String {
        let sides = "alpha=\(treeSummary(alpha)) beta=\(treeSummary(beta)) store.lastError=\(store.lastError ?? "nil")"
        guard let session = session(identifier) else { return "\(identifier) is not listed; \(sides)" }
        let roots = (session.conflicts ?? []).map(\.root)
        return "\(identifier) status=\(session.status) paused=\(session.paused) conflicts=\(roots) lastError=\(session.lastError ?? "nil") \(sides)"
    }

    private func treeSummary(_ root: URL) -> String {
        do {
            return try tree(root).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.description
        } catch {
            return "unreadable (\(error.localizedDescription))"
        }
    }

    /// Every entry under `root`, hidden ones included, by path relative to it.
    func tree(_ root: URL) throws -> [String: TreeEntry] {
        let manager = FileManager.default
        var entries: [String: TreeEntry] = [:]
        for relative in try manager.subpathsOfDirectory(atPath: root.path) {
            let path = root.appendingPathComponent(relative).path
            let type = try manager.attributesOfItem(atPath: path)[.type] as? FileAttributeType
            switch type {
            case .typeDirectory: entries[relative] = .directory
            case .typeRegular: entries[relative] = .file(try Data(contentsOf: URL(fileURLWithPath: path)))
            case .typeSymbolicLink: entries[relative] = .symlink(try manager.destinationOfSymbolicLink(atPath: path))
            default: throw ScenarioFailure(description: "\(path) is a \(type.map { $0.rawValue } ?? "nil"), which the scenarios never create")
            }
        }
        return entries
    }

    /// Paths under either root that a conflict replacement names as its incoming copy or set-aside original.
    func replacementLeftovers() throws -> [String] {
        let paths = try tree(alpha).keys.map { "alpha/\($0)" } + tree(beta).keys.map { "beta/\($0)" }
        return paths.filter { path in
            let name = (path as NSString).lastPathComponent
            return name.hasPrefix(".helix-incoming-") || name.hasPrefix(".helix-replaced-")
        }.sorted()
    }

    /// Checks what a finished resolve leaves: no replacement leftovers, the session unpaused, no hold or notice.
    func expectResolvedCleanly(_ identifier: String) throws {
        #expect(try replacementLeftovers() == [])
        let session = try #require(session(identifier))
        #expect(session.paused == false)
        #expect((session.conflicts ?? []).isEmpty, "\(describe(identifier))")
        #expect(session.lastError == nil)
        #expect(store.sessionHolds[identifier] == nil)
        #expect(store.leftoverNotices[identifier] == nil)
    }

    func write(_ text: String, to relative: String, in root: URL) throws -> Data {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: url)
        return data
    }

    /// The sessions mutagen lists with this run's label.
    func labelledSessions() async throws -> [SyncSession] {
        let output = try await runProcess(
            executablePath: CLI.defaultExecutablePath,
            arguments: ["sync", "list", "--label-selector", "helix-e2e=\(runID)", "--template", "{{json .}}"],
            deadline: CommandDeadline.query
        )
        return try JSONDecoder().decode([SyncSession].self, from: Data(output.utf8))
    }

    /// Terminates, by identifier, every session this scenario created or that carries its name, including
    /// replacements an edit minted, then checks that mutagen lists no session with the run label.
    func tearDown() async {
        do {
            for session in try await labelledSessions()
            where created.contains(session.identifier) || session.name?.hasPrefix("helix-e2e-\(slug)-") == true {
                try await cli.syncTerminate(session.identifier)
            }
            let left = try await labelledSessions()
            #expect(left.isEmpty, "Sessions left with label helix-e2e=\(runID): \(left.map { "\($0.identifier) \($0.name ?? "")" })")
        } catch {
            Issue.record(error, "Cleaning up the sessions of \(slug)")
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults.synchronize()
        do {
            try FileManager.default.removeItem(at: folder)
            if try FileManager.default.contentsOfDirectory(atPath: scenarioRoot.path).isEmpty {
                try FileManager.default.removeItem(at: scenarioRoot)
            }
        } catch {
            Issue.record(error, "Removing \(folder.path)")
        }
    }
}

/// Runs `body` on a fresh scenario and tears the scenario down whether or not `body` throws.
@MainActor
private func withScenario(_ slug: String, _ body: (Scenario) async throws -> Void) async throws {
    let scenario = try Scenario(slug)
    do {
        try await body(scenario)
    } catch {
        await scenario.tearDown()
        throw error
    }
    await scenario.tearDown()
}

@Suite("End to end against the real mutagen CLI", .serialized, .enabled(if: ProcessInfo.processInfo.environment["HELIX_E2E"] != nil))
@MainActor
struct EndToEndTests {

    @Test("Create: the session is listed once, watches, and beta receives the alpha file byte for byte")
    func create() async throws {
        try await withScenario("create") { s in
            let bytes = try s.write("hello \(UUID().uuidString)\n", to: "hello.txt", in: s.alpha)
            let name = s.name()
            let session = try await s.createSession(name: name)
            #expect(s.store.lastError == nil)

            try await s.waitUntilSettled(session.identifier, holding: ["hello.txt": .file(bytes)])
            #expect(s.sessions(named: name).map(\.identifier) == [session.identifier])
        }
    }

    @Test("Conflict, file against file, keep alpha: beta takes alpha's bytes and the session syncs cleanly")
    func conflictKeepAlpha() async throws {
        try await resolveFileAgainstFile(keeping: .alpha, slug: "keep-alpha")
    }

    @Test("Conflict, file against file, keep beta: alpha takes beta's bytes and the session syncs cleanly")
    func conflictKeepBeta() async throws {
        try await resolveFileAgainstFile(keeping: .beta, slug: "keep-beta")
    }

    private func resolveFileAgainstFile(keeping winner: ConflictWinner, slug: String) async throws {
        try await withScenario(slug) { s in
            let alphaBytes = try s.write("alpha \(UUID().uuidString)\n", to: "conflict.txt", in: s.alpha)
            let betaBytes = try s.write("beta \(UUID().uuidString)\n", to: "conflict.txt", in: s.beta)
            let created = try await s.createSession(name: s.name())
            let (session, conflict) = try await s.waitForConflict(on: created.identifier, root: "conflict.txt")

            let unresolved = await s.store.resolveConflict(session: session, conflict: conflict, winner: winner)
            let errorAfterResolve = s.store.lastError
            #expect(unresolved == [])
            #expect(errorAfterResolve == nil)

            let kept = winner == .alpha ? alphaBytes : betaBytes
            try await s.waitUntilSettled(created.identifier, holding: ["conflict.txt": .file(kept)])
            await s.store.manualRefresh()
            try s.expectResolvedCleanly(created.identifier)
        }
    }

    @Test("Conflict, directory on the winner against a file on the loser: the loser ends with exactly the winner's tree")
    func conflictDirectoryWinner() async throws {
        try await resolveDirectoryAgainstFile(keeping: .alpha, slug: "dir-wins")
    }

    @Test("Conflict, file on the winner against a directory on the loser: the loser ends with exactly the winner's file")
    func conflictFileWinner() async throws {
        try await resolveDirectoryAgainstFile(keeping: .beta, slug: "file-wins")
    }

    /// Alpha holds a directory at "entry" and beta a file there; `winner` picks which one both sides keep.
    private func resolveDirectoryAgainstFile(keeping winner: ConflictWinner, slug: String) async throws {
        try await withScenario(slug) { s in
            let inner = try s.write("inner \(UUID().uuidString)\n", to: "entry/inner.txt", in: s.alpha)
            let deep = try s.write("deep \(UUID().uuidString)\n", to: "entry/nested/deep.txt", in: s.alpha)
            let file = try s.write("file \(UUID().uuidString)\n", to: "entry", in: s.beta)
            let created = try await s.createSession(name: s.name())
            let (session, conflict) = try await s.waitForConflict(on: created.identifier, root: "entry")

            let unresolved = await s.store.resolveConflict(session: session, conflict: conflict, winner: winner)
            let errorAfterResolve = s.store.lastError
            #expect(unresolved == [])
            #expect(errorAfterResolve == nil)

            let kept: [String: TreeEntry] = switch winner {
            case .alpha:
                [
                    "entry": .directory, "entry/inner.txt": .file(inner),
                    "entry/nested": .directory, "entry/nested/deep.txt": .file(deep),
                ]
            case .beta:
                ["entry": .file(file)]
            }
            try await s.waitUntilSettled(created.identifier, holding: kept)
            await s.store.manualRefresh()
            try s.expectResolvedCleanly(created.identifier)
        }
    }

    @Test("Deleted on alpha, modified on beta: two-way-safe lists no conflict and puts the modification back on alpha")
    func deletionAgainstModification() async throws {
        try await withScenario("delete-modify") { s in
            let original = try s.write("original \(UUID().uuidString)\n", to: "shared.txt", in: s.alpha)
            let created = try await s.createSession(name: s.name())
            let identifier = created.identifier
            try await s.waitUntilSettled(identifier, holding: ["shared.txt": .file(original)])

            await s.store.pauseSync(identifier)
            #expect(s.store.lastError == nil)
            try await s.waitUntil("the session is paused", observing: { s.describe(identifier) }) {
                s.session(identifier)?.paused == true
            }
            try FileManager.default.removeItem(at: s.alpha.appendingPathComponent("shared.txt"))
            let modified = try s.write("modified \(UUID().uuidString)\n", to: "shared.txt", in: s.beta)
            await s.store.resumeSync(identifier)
            #expect(s.store.lastError == nil)

            var conflictsSeen: Set<String> = []
            try await s.waitUntil("both roots hold the modification and the session watches", observing: { s.describe(identifier) }) {
                guard let session = s.session(identifier) else { return false }
                conflictsSeen.formUnion((session.conflicts ?? []).map(\.root))
                let expected: [String: TreeEntry] = ["shared.txt": .file(modified)]
                let alphaTree = try s.tree(s.alpha)
                let betaTree = try s.tree(s.beta)
                return session.phase == .watching && !session.paused && alphaTree == expected && betaTree == expected
            }
            #expect(conflictsSeen == [])
            let settled = try #require(s.session(identifier))
            #expect((settled.conflicts ?? []).isEmpty)
        }
    }

    @Test("Edit: recreating with an ignore pattern replaces the session, and the pattern stops matching files")
    func editAddsIgnore() async throws {
        try await withScenario("edit") { s in
            let base = try s.write("base \(UUID().uuidString)\n", to: "base.txt", in: s.alpha)
            let name = s.name()
            let original = try await s.createSession(name: name)
            try await s.waitUntilSettled(original.identifier, holding: ["base.txt": .file(base)])
            let current = try #require(s.session(original.identifier))

            var options = SyncCreateOptions(from: current)
            options.ignorePaths.append("*.skip")
            let failure = await s.store.recreateSync(
                current, options: options,
                alpha: current.alpha.endpointURL.formatted, beta: current.beta.endpointURL.formatted
            )
            let errorAfterEdit = s.store.lastError
            #expect(failure == nil)
            #expect(errorAfterEdit == nil)

            try await expectSessionReplaced(original, ignoring: "*.skip", matching: "late.skip", in: s)
        }
    }

    /// Checks that `original` was replaced by exactly one session of its name whose ignore list is `pattern`,
    /// that a new file named `ignored` stays on alpha while another new file reaches beta, and that the
    /// store, also as reopened on the same defaults, keeps no record of the edit.
    private func expectSessionReplaced(
        _ original: SyncSession, ignoring pattern: String, matching ignored: String, in s: Scenario
    ) async throws {
        let name = try #require(original.name)
        try await s.waitUntil("one session named \(name) other than \(original.identifier) watches", observing: {
            s.sessions(named: name).map { s.describe($0.identifier) }.description
        }) {
            let named = s.sessions(named: name)
            return named.count == 1 && named[0].identifier != original.identifier && named[0].phase == .watching
        }
        let replacement = try #require(s.sessions(named: name).first)
        s.track(replacement.identifier)
        #expect(s.session(original.identifier) == nil)
        #expect(replacement.ignore.paths == [pattern])
        #expect(replacement.paused == false)

        let skipped = try s.write("skipped \(UUID().uuidString)\n", to: ignored, in: s.alpha)
        let late = try s.write("late \(UUID().uuidString)\n", to: "late.txt", in: s.alpha)
        try await s.waitUntil("late.txt reaches beta", observing: { s.describe(replacement.identifier) }) {
            try s.tree(s.beta)["late.txt"] == .file(late) && s.session(replacement.identifier)?.phase == .watching
        }
        #expect(try s.tree(s.beta)[ignored] == nil)
        #expect(try s.tree(s.alpha)[ignored] == .file(skipped))

        #expect(s.store.leftoverSyncOriginals == [:])
        #expect(s.store.interruptedEditNotice == nil)
        #expect(s.store.sessionHolds == [:])
        let reopened = SessionStore(provider: s.cli, defaults: s.defaults)
        #expect(reopened.leftoverSyncOriginals == [:])
        #expect(reopened.interruptedEditNotice == nil)
        #expect(reopened.sessionHolds == [:])
    }

    @Test("Edit to an unreachable endpoint: the original keeps running under its identifier and the store reports why")
    func editToUnreachableEndpoint() async throws {
        try await withScenario("unreachable") { s in
            let base = try s.write("base \(UUID().uuidString)\n", to: "base.txt", in: s.alpha)
            let name = s.name()
            let original = try await s.createSession(name: name)
            try await s.waitUntilSettled(original.identifier, holding: ["base.txt": .file(base)])
            let current = try #require(s.session(original.identifier))

            let failure = await s.store.recreateSync(
                current, options: SyncCreateOptions(from: current),
                alpha: current.alpha.endpointURL.formatted,
                beta: EndpointURL.ssh(user: nil, host: "helix-e2e.invalid", port: nil, path: s.beta.path).formatted
            )
            let errorAfterEdit = s.store.lastError
            #expect(failure != nil)
            #expect(errorAfterEdit == failure)
            #expect(failure?.hasPrefix("Could not start the edited session: ") == true, "\(failure ?? "nil")")
            #expect(failure?.contains("helix-e2e.invalid") == true, "\(failure ?? "nil")")
            #expect(failure?.hasSuffix(" The original session was restored.") == true, "\(failure ?? "nil")")

            try await s.waitUntil("the original session watches again", observing: { s.describe(original.identifier) }) {
                s.session(original.identifier)?.phase == .watching && s.session(original.identifier)?.paused == false
            }
            #expect(s.sessions(named: name).map(\.identifier) == [original.identifier])
            let unreachable = s.store.syncSessions.filter {
                $0.labels?["helix-e2e"] == runID && ($0.alpha.host == "helix-e2e.invalid" || $0.beta.host == "helix-e2e.invalid")
            }
            #expect(unreachable.map(\.identifier) == [])
            #expect(s.store.leftoverSyncOriginals == [:])
        }
    }

    @Test("Add to ignore list on a running session: the session is replaced and the path stops syncing")
    func addToIgnoreList() async throws {
        try await withScenario("ignore") { s in
            let base = try s.write("base \(UUID().uuidString)\n", to: "base.txt", in: s.alpha)
            let original = try await s.createSession(name: s.name())
            try await s.waitUntilSettled(original.identifier, holding: ["base.txt": .file(base)])
            let current = try #require(s.session(original.identifier))

            await s.store.addToIgnoreList(session: current, path: "skip-me")
            #expect(s.store.lastError == nil)

            try await expectSessionReplaced(original, ignoring: "skip-me", matching: "skip-me", in: s)
        }
    }

    @Test("Resume guard: a paused session on the same folders as a running one is refused and stays paused")
    func resumeGuard() async throws {
        try await withScenario("guard") { s in
            let firstName = s.name("first")
            let first = try await s.createSession(name: firstName)
            try await s.waitUntilSettled(first.identifier, holding: [:])

            let secondName = s.name("second")
            let second = try await s.cli.syncCreate(arguments: [
                "sync", "create", s.alpha.path, s.beta.path,
                "--name", secondName, "--label", "helix-e2e=\(runID)", "--paused",
            ])
            s.track(second)
            await s.store.manualRefresh()
            #expect(s.session(second)?.paused == true)

            await s.store.resumeSync(second)
            let refusal = s.store.lastError
            #expect(refusal == "Cannot resume \"\(secondName)\" while \"\(firstName)\" is running on the same endpoints.")

            await s.store.manualRefresh()
            #expect(s.session(second)?.paused == true, "\(s.describe(second))")
            #expect(s.session(first.identifier)?.paused == false, "\(s.describe(first.identifier))")
        }
    }
}
