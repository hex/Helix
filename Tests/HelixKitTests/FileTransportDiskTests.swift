// ABOUTME: Tests FileTransport against a real temporary directory, running the real commands.
// ABOUTME: Asserts on what is on disk afterwards, which recorded command lists cannot show.

import Testing
import Foundation
@testable import HelixKit

/// A directory under the system temporary directory that exists for the length of `body`.
private func withScratchDirectory<Result>(_ body: (URL) async throws -> Result) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helix-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
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
