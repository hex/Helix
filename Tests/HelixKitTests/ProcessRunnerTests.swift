// ABOUTME: Tests for runProcess against real child processes.
// ABOUTME: Checks that output larger than a pipe buffer comes back whole.

import Testing
import Foundation
@testable import HelixKit

@Suite("Process runner")
struct ProcessRunnerTests {

    @Test("Returns all output of a child that writes more than a pipe buffer holds")
    func largeOutput() async throws {
        let output = try await withTimeout(seconds: 10) {
            try await runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", "head -c 300000 /dev/zero | tr '\\000' x"]
            )
        }

        #expect(output.utf8.count == 300000)
        #expect(output == String(repeating: "x", count: 300000))
    }
}

private struct TimedOut: Error, CustomStringConvertible {
    let seconds: Int
    var description: String { "runProcess did not return within \(seconds) seconds" }
}

/// Runs an operation that may never return, failing after the given time instead of waiting forever.
private func withTimeout<T: Sendable>(
    seconds: Int,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = FirstOutcome<T>()
    return try await withCheckedThrowingContinuation { continuation in
        outcome.continuation = continuation
        Task {
            do {
                outcome.finish(with: .success(try await operation()))
            } catch {
                outcome.finish(with: .failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            outcome.finish(with: .failure(TimedOut(seconds: seconds)))
        }
    }
}

/// Resumes its continuation with whichever outcome arrives first and ignores the rest.
private final class FirstOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    var continuation: CheckedContinuation<T, Error>?

    func finish(with result: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed, let continuation else { return }
        resumed = true
        continuation.resume(with: result)
    }
}
