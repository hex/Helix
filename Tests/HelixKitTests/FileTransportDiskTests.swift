// ABOUTME: Tests FileTransport against a real temporary directory, running the real commands.
// ABOUTME: Asserts on what is on disk afterwards, which recorded command lists cannot show.

import Testing
import Foundation
@testable import HelixKit

/// A directory under the system temporary directory that exists for the length of `body`.
func withScratchDirectory<Result>(_ body: (URL) async throws -> Result) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helix-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// An executor that runs every command for real, except that the first command `matches` picks throws:
/// before running it, or after running it when `afterRunning` is set.
func executorFailing(
    afterRunning: Bool = false,
    where matches: @escaping @Sendable (_ executable: String, _ arguments: [String]) -> Bool
) -> @Sendable (String, [String]) async throws -> String {
    let failed = FailedOnce()
    return { executable, arguments in
        guard matches(executable, arguments), failed.claim() else {
            return try await runProcess(executablePath: executable, arguments: arguments)
        }
        if afterRunning {
            _ = try await runProcess(executablePath: executable, arguments: arguments)
        }
        throw CLIError(exitCode: 255, stderr: "connection lost")
    }
}

private final class FailedOnce: @unchecked Sendable {
    private var hasFailed = false
    private let lock = NSLock()

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasFailed { return false }
        hasFailed = true
        return true
    }
}

/// The names in `directory` that a replacement leaves behind when it does not finish.
func replaceSiblings(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".helix-") }.sorted()
}

@Suite("FileTransport replace on disk")
struct FileTransportReplaceDiskTests {

    private func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test("a file replaces a file")
    func fileOverFile() async throws {
        try await withScratchDirectory { scratch in
            let winner = scratch.appendingPathComponent("winner.txt")
            let loser = scratch.appendingPathComponent("loser.txt")
            try "winner".write(to: winner, atomically: false, encoding: .utf8)
            try "loser".write(to: loser, atomically: false, encoding: .utf8)

            _ = try await FileTransport().replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))

            #expect(try text(at: loser) == "winner")
            #expect(try text(at: winner) == "winner")
            #expect(try replaceSiblings(in: scratch) == [])
        }
    }

    @Test("a directory replaces a directory without nesting inside it")
    func directoryOverDirectory() async throws {
        try await withScratchDirectory { scratch in
            let winner = scratch.appendingPathComponent("winner")
            let loser = scratch.appendingPathComponent("loser")
            try FileManager.default.createDirectory(at: winner, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: loser, withIntermediateDirectories: false)
            try "winner".write(to: winner.appendingPathComponent("kept.txt"), atomically: false, encoding: .utf8)
            try "loser".write(to: loser.appendingPathComponent("dropped.txt"), atomically: false, encoding: .utf8)

            _ = try await FileTransport().replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))

            #expect(try FileManager.default.contentsOfDirectory(atPath: loser.path) == ["kept.txt"])
            #expect(try text(at: loser.appendingPathComponent("kept.txt")) == "winner")
            #expect(try replaceSiblings(in: scratch) == [])
        }
    }

    @Test("a file replaces a dangling symlink, leaving a regular file")
    func fileOverDanglingSymlink() async throws {
        try await withScratchDirectory { scratch in
            let winner = scratch.appendingPathComponent("winner.txt")
            let loser = scratch.appendingPathComponent("loser.txt")
            try "winner".write(to: winner, atomically: false, encoding: .utf8)
            try FileManager.default.createSymbolicLink(atPath: loser.path, withDestinationPath: "nowhere")

            _ = try await FileTransport().replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))

            #expect(try FileManager.default.attributesOfItem(atPath: loser.path)[.type] as? FileAttributeType == .typeRegular)
            #expect(try text(at: loser) == "winner")
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["loser.txt", "winner.txt"])
        }
    }

    @Test("a file lands where nothing was")
    func destinationAbsent() async throws {
        try await withScratchDirectory { scratch in
            let winner = scratch.appendingPathComponent("winner.txt")
            let loser = scratch.appendingPathComponent("loser.txt")
            try "winner".write(to: winner, atomically: false, encoding: .utf8)

            _ = try await FileTransport().replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))

            #expect(try text(at: loser) == "winner")
            #expect(try replaceSiblings(in: scratch) == [])
        }
    }

    @Test("a replacement whose last cleanup fails still succeeds and reports the original left beside it")
    func cleanupFails() async throws {
        try await withScratchDirectory { scratch in
            let winner = scratch.appendingPathComponent("winner")
            let loser = scratch.appendingPathComponent("loser")
            try FileManager.default.createDirectory(at: winner, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: loser, withIntermediateDirectories: false)
            try "winner".write(to: winner.appendingPathComponent("kept.txt"), atomically: false, encoding: .utf8)
            try "loser".write(to: loser.appendingPathComponent("dropped.txt"), atomically: false, encoding: .utf8)
            let transport = FileTransport(execute: executorFailing { executable, _ in executable == "/bin/rm" })

            let outcome = try await transport.replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))

            let siblings = try replaceSiblings(in: scratch)
            try #require(siblings.count == 1)
            let leftover = scratch.appendingPathComponent(siblings[0])
            #expect(siblings[0].hasPrefix("loser.helix-replaced-"))
            #expect(outcome == .replacedLeavingOriginal(path: leftover.path, reason: "connection lost"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: loser.path) == ["kept.txt"])
            #expect(try text(at: loser.appendingPathComponent("kept.txt")) == "winner")
            #expect(try text(at: leftover.appendingPathComponent("dropped.txt")) == "loser")
        }
    }

    /// A loser directory holding "dropped.txt" and a winner directory holding "kept.txt", both in `scratch`.
    private func makeDirectoryConflict(in scratch: URL) throws -> (winner: URL, loser: URL) {
        let winner = scratch.appendingPathComponent("winner")
        let loser = scratch.appendingPathComponent("loser")
        try FileManager.default.createDirectory(at: winner, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: loser, withIntermediateDirectories: false)
        try "winner".write(to: winner.appendingPathComponent("kept.txt"), atomically: false, encoding: .utf8)
        try "loser".write(to: loser.appendingPathComponent("dropped.txt"), atomically: false, encoding: .utf8)
        return (winner, loser)
    }

    private func movesCopyIntoPlace(_ executable: String, _ arguments: [String]) -> Bool {
        executable == "/bin/mv" && arguments.first?.contains(".helix-incoming-") == true
    }

    @Test("Interrupted set-aside removal leaves a verified winner and an unverified old tree")
    func interruptedSetAsideRemovalReportsUnverifiedTree() async throws {
        try await withScratchDirectory { scratch in
            let (winner, loser) = try makeDirectoryConflict(in: scratch)
            try "also old".write(to: loser.appendingPathComponent("stays.txt"), atomically: false, encoding: .utf8)
            let transport = FileTransport { executable, arguments in
                if executable == "/bin/rm" {
                    let path = try #require(arguments.last)
                    try FileManager.default.removeItem(at: URL(fileURLWithPath: path).appendingPathComponent("dropped.txt"))
                    throw ProcessDeadlineError(executablePath: executable, deadline: .seconds(15))
                }
                return try await runProcess(executablePath: executable, arguments: arguments)
            }
            let plan = ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path))

            let outcome = try await transport.replace(plan)

            #expect(outcome == .replacedWithInterruptedRemoval(path: plan.setAside.formatted, reason: "/bin/rm exceeded its deadline of 15.0 seconds."))
            #expect(try FileManager.default.contentsOfDirectory(atPath: plan.setAside.formatted) == ["stays.txt"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: loser.path) == ["kept.txt"])
        }
    }

    @Test("a move into place that ran and then reported failure leaves the winner in place and the original beside it, not inside it")
    func moveIntoPlaceRanThenFailed() async throws {
        try await withScratchDirectory { scratch in
            let (winner, loser) = try makeDirectoryConflict(in: scratch)
            let transport = FileTransport(execute: executorFailing(afterRunning: true, where: movesCopyIntoPlace))

            let outcome = try await transport.replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))

            let siblings = try replaceSiblings(in: scratch)
            try #require(siblings.count == 1)
            let leftover = scratch.appendingPathComponent(siblings[0])
            #expect(siblings[0].hasPrefix("loser.helix-replaced-"))
            #expect(outcome == .replacedLeavingOriginal(path: leftover.path, reason: "connection lost"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: loser.path) == ["kept.txt"])
            #expect(try text(at: loser.appendingPathComponent("kept.txt")) == "winner")
            #expect(try FileManager.default.contentsOfDirectory(atPath: leftover.path) == ["dropped.txt"])
            #expect(try text(at: leftover.appendingPathComponent("dropped.txt")) == "loser")
        }
    }

    @Test("a move into place that fails puts the original back and removes the unused copy")
    func moveIntoPlaceFails() async throws {
        try await withScratchDirectory { scratch in
            let (winner, loser) = try makeDirectoryConflict(in: scratch)
            let transport = FileTransport(execute: executorFailing(where: movesCopyIntoPlace))

            let error = try await #require(throws: ReplaceError.self) {
                _ = try await transport.replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))
            }

            #expect(try replaceSiblings(in: scratch) == [])
            #expect(error.aftermath == .destinationUnchanged)
            #expect(error.incoming.hasPrefix("\(loser.path).helix-incoming-"))
            #expect(error.localizedDescription == "Could not move \(error.incoming) into place at \(loser.path): connection lost. \(loser.path) is unchanged")
            #expect(try FileManager.default.contentsOfDirectory(atPath: loser.path) == ["dropped.txt"])
            #expect(try text(at: loser.appendingPathComponent("dropped.txt")) == "loser")
        }
    }

    @Test("when the original cannot be moved back, both siblings stay on disk and the error names them")
    func restoreFails() async throws {
        try await withScratchDirectory { scratch in
            let (winner, loser) = try makeDirectoryConflict(in: scratch)
            let transport = FileTransport { executable, arguments in
                if executable == "/bin/mv", arguments.last == loser.path {
                    throw CLIError(exitCode: 255, stderr: "connection lost")
                }
                return try await runProcess(executablePath: executable, arguments: arguments)
            }

            let error = try await #require(throws: ReplaceError.self) {
                _ = try await transport.replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))
            }

            let siblings = try replaceSiblings(in: scratch)
            try #require(siblings.count == 2)
            let incoming = scratch.appendingPathComponent(siblings[0])
            let setAside = scratch.appendingPathComponent(siblings[1])
            #expect(siblings[0].hasPrefix("loser.helix-incoming-"))
            #expect(siblings[1].hasPrefix("loser.helix-replaced-"))
            #expect(error.aftermath == .destinationUnverified)
            #expect(error.localizedDescription == "Could not move \(incoming.path) into place at \(loser.path): connection lost. Then could not move the original back from \(setAside.path) to \(loser.path): connection lost. Nothing was deleted: look for the original at \(setAside.path) and for the replacement at \(incoming.path)")
            #expect(FileManager.default.fileExists(atPath: loser.path) == false)
            #expect(try text(at: setAside.appendingPathComponent("dropped.txt")) == "loser")
            #expect(try text(at: incoming.appendingPathComponent("kept.txt")) == "winner")
        }
    }

    @Test("a file replaces a symlink to a directory without landing inside that directory")
    func fileOverSymlinkToDirectory() async throws {
        try await withScratchDirectory { scratch in
            let winner = scratch.appendingPathComponent("winner.txt")
            let loser = scratch.appendingPathComponent("loser.txt")
            let linked = scratch.appendingPathComponent("linked")
            try "winner".write(to: winner, atomically: false, encoding: .utf8)
            try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
            try "inside".write(to: linked.appendingPathComponent("inside.txt"), atomically: false, encoding: .utf8)
            try FileManager.default.createSymbolicLink(atPath: loser.path, withDestinationPath: "linked")

            _ = try await FileTransport().replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))

            #expect(try FileManager.default.attributesOfItem(atPath: loser.path)[.type] as? FileAttributeType == .typeRegular)
            #expect(try text(at: loser) == "winner")
            #expect(try FileManager.default.contentsOfDirectory(atPath: linked.path) == ["inside.txt"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["linked", "loser.txt", "winner.txt"])
        }
    }

    @Test("a file's move over a file that ran and then reported failure counts as replaced")
    func renameOverFileRanThenFailed() async throws {
        try await withScratchDirectory { scratch in
            let winner = scratch.appendingPathComponent("winner.txt")
            let loser = scratch.appendingPathComponent("loser.txt")
            try "winner".write(to: winner, atomically: false, encoding: .utf8)
            try "loser".write(to: loser, atomically: false, encoding: .utf8)
            let transport = FileTransport(execute: executorFailing(afterRunning: true, where: movesCopyIntoPlace))

            let outcome = try await transport.replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))

            #expect(outcome == .replaced)
            #expect(try text(at: loser) == "winner")
            #expect(try replaceSiblings(in: scratch) == [])
        }
    }

    @Test("a file's move over a file that fails leaves the original in place and removes the unused copy")
    func renameOverFileFails() async throws {
        try await withScratchDirectory { scratch in
            let winner = scratch.appendingPathComponent("winner.txt")
            let loser = scratch.appendingPathComponent("loser.txt")
            try "winner".write(to: winner, atomically: false, encoding: .utf8)
            try "loser".write(to: loser, atomically: false, encoding: .utf8)
            let transport = FileTransport(execute: executorFailing(where: movesCopyIntoPlace))

            let error = try await #require(throws: ReplaceError.self) {
                _ = try await transport.replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))
            }

            #expect(try replaceSiblings(in: scratch) == [])
            #expect(error.aftermath == .destinationUnchanged)
            #expect(try text(at: loser) == "loser")
            #expect(try text(at: winner) == "winner")
        }
    }

    @Test("when the unused copy cannot be removed after a failed move, it stays on disk and the error names it")
    func removingUnusedCopyFails() async throws {
        try await withScratchDirectory { scratch in
            let winner = scratch.appendingPathComponent("winner.txt")
            let loser = scratch.appendingPathComponent("loser.txt")
            try "winner".write(to: winner, atomically: false, encoding: .utf8)
            try "loser".write(to: loser, atomically: false, encoding: .utf8)
            let transport = FileTransport { executable, arguments in
                if executable == "/bin/mv" { throw CLIError(exitCode: 255, stderr: "connection lost") }
                if executable == "/bin/rm" { throw CLIError(exitCode: 1, stderr: "permission denied") }
                return try await runProcess(executablePath: executable, arguments: arguments)
            }

            let error = try await #require(throws: ReplaceError.self) {
                _ = try await transport.replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))
            }

            let siblings = try replaceSiblings(in: scratch)
            try #require(siblings.count == 1)
            let unusedCopy = scratch.appendingPathComponent(siblings[0])
            #expect(siblings[0].hasPrefix("loser.txt.helix-incoming-"))
            #expect(error.aftermath == .destinationUnchanged)
            #expect(error.incomingCopy == .unverified(path: unusedCopy.path))
            #expect(error.localizedDescription == "Could not move \(unusedCopy.path) into place at \(loser.path): connection lost. Then could not remove the copy at \(unusedCopy.path): permission denied. \(loser.path) is unchanged, and the unused copy may still be at \(unusedCopy.path)")
            #expect(try text(at: loser) == "loser")
            #expect(try text(at: unusedCopy) == "winner")
        }
    }

    @Test("a copy that fails partway leaves the destination as it was and no partial copy")
    func copyFails() async throws {
        try await withScratchDirectory { scratch in
            let winner = scratch.appendingPathComponent("winner.txt")
            let loser = scratch.appendingPathComponent("loser.txt")
            try "winner".write(to: winner, atomically: false, encoding: .utf8)
            try "loser".write(to: loser, atomically: false, encoding: .utf8)
            let transport = FileTransport(execute: executorFailing(afterRunning: true) { executable, _ in executable == "/bin/cp" })

            await #expect(throws: ReplaceError.self) {
                _ = try await transport.replace(ReplacePlan(replacing: .local(path: loser.path), withCopyOf: .local(path: winner.path)))
            }

            #expect(try text(at: loser) == "loser")
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["loser.txt", "winner.txt"])
        }
    }
}

@Suite("Conflict interruptions on disk")
struct ConflictInterruptionDiskTests {
    @Test("Pause All includes a session paused by an in-progress conflict resolve", arguments: [false, true])
    @MainActor
    func pauseAllDuringConflictResolve(timed: Bool) async throws {
        try await withScratchDirectory { scratch in
            let fixture = try LocalConflictFixture(in: scratch)
            let suite = "ConflictBulkPauseTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let other = makeSyncSession(id: "other", name: "Other")
            let commands = MutationCommands(sessions: [other, fixture.session])
            let copying = Gate()
            let transport = FileTransport { executable, arguments in
                if executable == "/bin/cp" { await copying.pass() }
                return try await runProcess(executablePath: executable, arguments: arguments)
            }
            let store = SessionStore(provider: commands.cli, fileTransport: transport, defaults: defaults)
            let resolve = Task {
                await store.resolveConflict(session: fixture.session, conflict: fixture.conflict, winner: .alpha)
            }
            await copying.reached()
            #expect(await commands.sessions.map(\.paused) == [false, true])
            let callCount = await commands.calls.count
            let resumeAt = timed ? Date(timeIntervalSince1970: 2_000_000_000) : nil
            let pause = Task { await store.pauseAllSync(until: resumeAt) }
            let limit = ContinuousClock.now.advanced(by: .seconds(2))
            while await commands.calls.count <= callCount, ContinuousClock.now < limit {
                await Task.yield()
            }
            #expect(await commands.calls.count > callCount)
            await copying.open()
            #expect(await resolve.value.isEmpty)
            await pause.value

            #expect(await commands.sessions.map(\.paused) == [true, true])
            #expect(store.bulkPause == BulkPause(sessionIdentifiers: [other.identifier, fixture.session.identifier], resumeAt: resumeAt))
            #expect(try String(contentsOf: fixture.loser, encoding: .utf8) == "winner")
            await store.resumeBulkPause()
            #expect(await commands.sessions.map(\.paused) == [false, false])
        }
    }

    @Test("Conflict resolution restores only overlap that was already running", arguments: [false, true], [false, true])
    @MainActor
    func conflictRestoresPreviouslyRunningOverlap(bulk: Bool, peerAlreadyRunning: Bool) async throws {
        try await withScratchDirectory { scratch in
            let fixture = try LocalConflictFixture(in: scratch)
            let suite = "ConflictResumeOverlapTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let peer = makeSyncSession(
                id: "peer", name: "Other", paused: !peerAlreadyRunning,
                alpha: fixture.session.alpha, beta: fixture.session.beta
            )
            let commands = MutationCommands(
                sessions: [fixture.session, peer], startingPeerOnPause: peerAlreadyRunning ? nil : peer.identifier
            )
            let store = SessionStore(provider: commands.cli, defaults: defaults)

            let unresolved = if bulk {
                await store.resolveConflicts(session: fixture.session, conflicts: [fixture.conflict], winner: .alpha)
            } else {
                await store.resolveConflict(session: fixture.session, conflict: fixture.conflict, winner: .alpha)
            }

            #expect(try String(contentsOf: fixture.loser, encoding: .utf8) == "winner")
            #expect(await commands.sessions.map(\.paused) == [!peerAlreadyRunning, false])
            let writes = await commands.calls.filter { $0.count == 3 }
            if peerAlreadyRunning {
                #expect(unresolved.isEmpty)
                #expect(writes == [
                    ["sync", "pause", "sync_1"], ["sync", "resume", "sync_1"], ["sync", "flush", "sync_1"],
                ])
            } else {
                #expect(unresolved == ["file.txt"])
                #expect(writes == [["sync", "pause", "sync_1"]])
                #expect(store.lastError == "Could not confirm that Mutagen resumed \"project\". Flush was skipped. Check the session status before retrying. Cannot resume \"project\" while \"Other\" is running on the same endpoints.")
            }
        }
    }

    @Test("A resume deadline reports uncertainty and skips flush after file placement")
    @MainActor
    func resumeDeadlineReportsUnconfirmedSession() async throws {
        try await withScratchDirectory { scratch in
            let fixture = try LocalConflictFixture(in: scratch)
            let suite = "ConflictResumeDeadlineTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let paused = makeSyncSession(
                id: fixture.session.identifier, name: fixture.session.name, paused: true,
                conflicts: [fixture.conflict], alpha: fixture.session.alpha, beta: fixture.session.beta
            )
            let provider = RecordingProvider(
                syncSessions: [paused], beforeSyncResume: { _ in
                    throw ProcessDeadlineError(executablePath: "/usr/bin/mutagen", deadline: .seconds(15))
                }
            )
            let store = SessionStore(provider: provider, defaults: defaults)

            let result = await store.resolveConflict(session: fixture.session, conflict: fixture.conflict, winner: .alpha)

            #expect(try String(contentsOf: fixture.loser, encoding: .utf8) == "winner")
            #expect(result == ["file.txt"])
            #expect(provider.calls == ["syncPause:sync_1", "syncResume:sync_1"])
            #expect(store.lastError == "Could not confirm that Mutagen resumed \"project\". Flush was skipped. Check the session status before retrying. /usr/bin/mutagen exceeded its deadline of 15.0 seconds.")
        }
    }

    @Test("A partial incoming copy with failed cleanup holds the session", arguments: [false, true])
    @MainActor
    func failedCleanupHoldsSession(bulk: Bool) async throws {
        try await withScratchDirectory { scratch in
            let fixture = try LocalConflictFixture(in: scratch)
            let suite = "IncompleteCopyTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let provider = RecordingProvider(syncSessions: [fixture.session])
            let transport = FileTransport { executable, arguments in
                if executable == "/bin/cp" {
                    let incoming = try #require(arguments.last)
                    try "partial".write(toFile: incoming, atomically: false, encoding: .utf8)
                    throw CLIError(exitCode: 1, stderr: "copy failed")
                }
                if executable == "/bin/rm" { throw CLIError(exitCode: 1, stderr: "permission denied") }
                return try await runProcess(executablePath: executable, arguments: arguments)
            }
            let store = SessionStore(provider: provider, fileTransport: transport, defaults: defaults)

            let unresolved = if bulk {
                await store.resolveConflicts(session: fixture.session, conflicts: [fixture.conflict], winner: .alpha)
            } else {
                await store.resolveConflict(session: fixture.session, conflict: fixture.conflict, winner: .alpha)
            }

            let parent = fixture.loser.deletingLastPathComponent()
            let sibling = try #require(try replaceSiblings(in: parent).first)
            let incoming = parent.appendingPathComponent(sibling)
            #expect(try String(contentsOf: incoming, encoding: .utf8) == "partial")
            #expect(try String(contentsOf: fixture.loser, encoding: .utf8) == "loser")
            #expect(unresolved == ["file.txt"])
            #expect(provider.calls == ["syncPause:sync_1"])
            #expect(store.sessionHolds["sync_1"]?.contains(incoming.path) == true)
            #expect(store.lastError == store.sessionHolds["sync_1"])
        }
    }

    @Test("An interrupted copy and cleanup leave both a journal and a hold")
    @MainActor
    func cancelledCopyKeepsRecoveryRecord() async throws {
        try await withScratchDirectory { scratch in
            let fixture = try LocalConflictFixture(in: scratch)
            let suite = "InterruptedCopyTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let provider = RecordingProvider(syncSessions: [fixture.session])
            let transport = FileTransport { executable, arguments in
                if executable == "/bin/cp" {
                    let incoming = try #require(arguments.last)
                    try "partial".write(toFile: incoming, atomically: false, encoding: .utf8)
                    throw CancellationError()
                }
                if executable == "/bin/rm" { throw CancellationError() }
                return try await runProcess(executablePath: executable, arguments: arguments)
            }
            let store = SessionStore(provider: provider, fileTransport: transport, defaults: defaults)

            let unresolved = await store.resolveConflict(session: fixture.session, conflict: fixture.conflict, winner: .alpha)

            let sibling = try #require(try replaceSiblings(in: fixture.loser.deletingLastPathComponent()).first)
            let incoming = fixture.loser.deletingLastPathComponent().appendingPathComponent(sibling)
            #expect(try String(contentsOf: incoming, encoding: .utf8) == "partial")
            #expect(try String(contentsOf: fixture.loser, encoding: .utf8) == "loser")
            #expect(unresolved == ["file.txt"])
            #expect(provider.calls == ["syncPause:sync_1"])
            #expect(store.sessionHolds["sync_1"]?.contains(incoming.path) == true)
            #expect(defaults.dictionary(forKey: "replacementsUnderWay")?["sync_1"] != nil)
            #expect(SessionStore(provider: provider, defaults: defaults).sessionHolds == store.sessionHolds)
        }
    }
}

private struct LocalConflictFixture {
    let session: SyncSession
    let conflict: Conflict
    let winner: URL
    let loser: URL

    init(in scratch: URL) throws {
        let alpha = scratch.appendingPathComponent("alpha")
        let beta = scratch.appendingPathComponent("beta")
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: false)
        winner = alpha.appendingPathComponent("file.txt")
        loser = beta.appendingPathComponent("file.txt")
        try "winner".write(to: winner, atomically: false, encoding: .utf8)
        try "loser".write(to: loser, atomically: false, encoding: .utf8)
        conflict = Conflict(root: "file.txt", alphaChanges: [], betaChanges: [])
        session = makeSyncSession(
            id: "sync_1", name: "project", conflicts: [conflict],
            alpha: makeEndpoint(path: alpha.path), beta: makeEndpoint(path: beta.path)
        )
    }
}

@Suite("FileTransport run on disk")
struct FileTransportRunDiskTests {

    @Test("a local directory named with a quote and a command separator is only ever a directory to cd into")
    func runStaysInsideQuotedDirectory() async throws {
        try await withScratchDirectory { scratch in
            let fileManager = FileManager.default
            let plain = scratch.appendingPathComponent("x")
            let hostile = scratch.appendingPathComponent("x'; touch pwned; echo '")
            try fileManager.createDirectory(at: plain, withIntermediateDirectories: false)
            try fileManager.createDirectory(at: hostile, withIntermediateDirectories: false)

            _ = try await FileTransport().run(on: .local(path: hostile.path), command: "touch marker")

            #expect(try fileManager.contentsOfDirectory(atPath: hostile.path) == ["marker"])
            #expect(try fileManager.contentsOfDirectory(atPath: plain.path) == [])
            #expect(try fileManager.contentsOfDirectory(atPath: scratch.path).sorted() == ["x", "x'; touch pwned; echo '"])
        }
    }
}
