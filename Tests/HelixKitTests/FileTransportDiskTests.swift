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

            _ = try await FileTransport().replace(.local(path: loser.path), withCopyOf: .local(path: winner.path))

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

            _ = try await FileTransport().replace(.local(path: loser.path), withCopyOf: .local(path: winner.path))

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

            _ = try await FileTransport().replace(.local(path: loser.path), withCopyOf: .local(path: winner.path))

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

            _ = try await FileTransport().replace(.local(path: loser.path), withCopyOf: .local(path: winner.path))

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

            let outcome = try await transport.replace(.local(path: loser.path), withCopyOf: .local(path: winner.path))

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

    @Test("a move into place that ran and then reported failure leaves the winner in place and the original beside it, not inside it")
    func moveIntoPlaceRanThenFailed() async throws {
        try await withScratchDirectory { scratch in
            let (winner, loser) = try makeDirectoryConflict(in: scratch)
            let transport = FileTransport(execute: executorFailing(afterRunning: true, where: movesCopyIntoPlace))

            let outcome = try await transport.replace(.local(path: loser.path), withCopyOf: .local(path: winner.path))

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

    @Test("a move into place that fails puts the original back and keeps the unused copy")
    func moveIntoPlaceFails() async throws {
        try await withScratchDirectory { scratch in
            let (winner, loser) = try makeDirectoryConflict(in: scratch)
            let transport = FileTransport(execute: executorFailing(where: movesCopyIntoPlace))

            let error = try await #require(throws: ReplaceError.self) {
                _ = try await transport.replace(.local(path: loser.path), withCopyOf: .local(path: winner.path))
            }

            let siblings = try replaceSiblings(in: scratch)
            try #require(siblings.count == 1)
            let unusedCopy = scratch.appendingPathComponent(siblings[0])
            #expect(siblings[0].hasPrefix("loser.helix-incoming-"))
            #expect(error.aftermath == .destinationUnchanged)
            #expect(error.localizedDescription == "Could not move \(unusedCopy.path) into place at \(loser.path): connection lost. \(loser.path) is unchanged, and the unused copy is still at \(unusedCopy.path)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: loser.path) == ["dropped.txt"])
            #expect(try text(at: loser.appendingPathComponent("dropped.txt")) == "loser")
            #expect(try text(at: unusedCopy.appendingPathComponent("kept.txt")) == "winner")
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
                _ = try await transport.replace(.local(path: loser.path), withCopyOf: .local(path: winner.path))
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

    @Test("a copy that fails partway leaves the destination as it was and no partial copy")
    func copyFails() async throws {
        try await withScratchDirectory { scratch in
            let winner = scratch.appendingPathComponent("winner.txt")
            let loser = scratch.appendingPathComponent("loser.txt")
            try "winner".write(to: winner, atomically: false, encoding: .utf8)
            try "loser".write(to: loser, atomically: false, encoding: .utf8)
            let transport = FileTransport(execute: executorFailing(afterRunning: true) { executable, _ in executable == "/bin/cp" })

            await #expect(throws: ReplaceError.self) {
                _ = try await transport.replace(.local(path: loser.path), withCopyOf: .local(path: winner.path))
            }

            #expect(try text(at: loser) == "loser")
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["loser.txt", "winner.txt"])
        }
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
