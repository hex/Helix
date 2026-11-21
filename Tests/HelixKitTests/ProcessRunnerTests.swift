// ABOUTME: Tests for runProcess against real child processes.
// ABOUTME: Checks output capture, exit codes, and what cancelling a call does to its child.

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

    @Test("Throws the exit code and stderr text of a child that fails")
    func failingChild() async throws {
        let error = await #expect(throws: CLIError.self) {
            try await withTimeout(seconds: 10) {
                try await runProcess(executablePath: "/bin/sh", arguments: ["-c", "echo no such session >&2; exit 3"])
            }
        }

        #expect(error?.exitCode == 3)
        #expect(error?.stderr == "no such session")
    }

    @Test("Cancelling the task that awaits a running child ends the child and throws CancellationError")
    func cancelledWhileChildRuns() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("helix-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let call = Task {
            try await runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", "echo $$ > \"$0\"; exec /bin/sleep 30", pidFile.path]
            )
        }
        defer { call.cancel() }
        let child = try await processIdentifier(writtenTo: pidFile)
        defer { kill(child, SIGKILL) }

        call.cancel()
        await #expect(throws: CancellationError.self) {
            try await withTimeout(seconds: 5) { try await call.value }
        }

        #expect(kill(child, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("A call cancelled because a concurrent call failed to launch leaves the launch error to the caller")
    func siblingOfFailedCall() async throws {
        let missing = "/nonexistent/helix-test-executable"
        let calls = Task {
            async let failing = runProcess(executablePath: missing, arguments: [])
            // The child closes both streams at once, so the call is waiting for nothing but its exit when cancelled.
            async let running = runProcess(executablePath: "/bin/sh", arguments: ["-c", "exec /bin/sleep 1 >&- 2>&-"])
            _ = try await failing
            _ = try await running
        }

        let error = await #expect(throws: CocoaError.self) {
            try await withTimeout(seconds: 5) { try await calls.value }
        }

        #expect(error?.code == .fileNoSuchFile)
    }
}

@Suite("Process deadlines")
struct ProcessDeadlineTests {
    @Test("A live child is reaped and the caller receives the deadline error")
    func deadlineEndsRunningChild() async throws {
        let pidFile = fixturePIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let clock = Gate()
        let limit: Duration = .milliseconds(250)
        let started = SuspendingClock.now
        let wait: @Sendable (SuspendingClock.Instant) async throws -> Void = { expiry in
            #expect(expiry >= started.advanced(by: limit))
            #expect(expiry <= SuspendingClock.now.advanced(by: limit))
            await clock.pass()
        }
        let runner = ProcessRunner(waitForDeadline: wait)
        let call = Task {
            try await runner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf '%s\n' \"$$\" > \"$1\"; exec /bin/sleep 8", "helix-test", pidFile.path],
                deadline: limit
            )
        }
        defer {
            call.cancel()
            Task { await clock.open() }
        }
        let pid = try await processIdentifier(writtenTo: pidFile)
        defer { endFixture(pid) }
        await clock.open()

        let failure = await deadlineFailure(of: call)

        #expect(failure == "/bin/sh exceeded its deadline of 0.25 seconds.")
        #expect(fixtureIsGone(pid))
    }

    @Test("Cancellation kills a child that ignores SIGTERM")
    func cancellationEscalatesToKill() async throws {
        let pidFile = fixturePIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let call = Task {
            try await runBoundedShell(
                "trap '' TERM; printf '%s\n' \"$$\" > \"$1\"; exec /bin/sleep 8",
                pidFile: pidFile, duration: .seconds(5)
            )
        }
        defer { call.cancel() }
        let pid = try await processIdentifier(writtenTo: pidFile)
        defer { endFixture(pid) }

        call.cancel()
        await #expect(throws: CancellationError.self) {
            try await withTimeout(seconds: 2) { try await call.value }
        }
        #expect(fixtureIsGone(pid))
    }

    @Test("An exited child cannot leave the caller waiting on inherited stdout")
    func inheritedPipeHasDeadline() async throws {
        let pidFile = fixturePIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let parentFile = fixturePIDFile()
        defer { try? FileManager.default.removeItem(at: parentFile) }
        let clock = Gate()
        let runner = ProcessRunner { _ in await clock.pass() }
        let call = Task {
            try await runner.run(
                executablePath: "/bin/sh",
                arguments: [
                    "-c", "/bin/sleep 8 & printf '%s\n' \"$!\" > \"$1\"; printf '%s\n' \"$$\" > \"$2\"",
                    "helix-test", pidFile.path, parentFile.path,
                ],
                deadline: .milliseconds(250)
            )
        }
        defer {
            call.cancel()
            Task { await clock.open() }
        }
        let pid = try await processIdentifier(writtenTo: pidFile)
        defer { endFixture(pid) }
        let parent = try await processIdentifier(writtenTo: parentFile)
        for _ in 0..<100 where !fixtureIsGone(parent) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixtureIsGone(parent))
        await clock.open()

        let failure = await deadlineFailure(of: call)

        #expect(failure == "/bin/sh exceeded its deadline of 0.25 seconds.")
        #expect(fixtureIsGone(pid))
    }

    @Test("A fast command returns its full output")
    func fastCommandSucceeds() async throws {
        let output = try await withTimeout(seconds: 2) {
            try await runProcess(executablePath: "/usr/bin/printf", arguments: ["hello"], deadline: .seconds(1))
        }
        #expect(output == "hello")
    }
}

@Suite("Process registry")
struct ProcessRegistryTests {
    @Test("Shutdown kills a tracked child and waits for it to exit")
    func registryTerminatesRunningChild() async throws {
        let registry = ProcessRunner()
        let pidFile = fixturePIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let call = Task {
            try await registry.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "trap '' TERM; printf '%s\n' \"$$\" > \"$1\"; exec /bin/sleep 8", "helix-test", pidFile.path],
                deadline: .seconds(6)
            )
        }
        defer { call.cancel() }
        let pid = try await processIdentifier(writtenTo: pidFile)
        defer { endFixture(pid) }

        let stopped = try await withTimeout(seconds: 2) { await registry.terminateAll() }

        #expect(stopped.interrupted == 1)
        #expect(stopped.unfinished == 0)
        #expect(fixtureIsGone(pid))
        await #expect(throws: CancellationError.self) {
            try await withTimeout(seconds: 2) { try await call.value }
        }
        await #expect(throws: CancellationError.self) {
            try await registry.run(executablePath: "/usr/bin/printf", arguments: ["after quit"], deadline: .seconds(1))
        }
    }

    @Test("Quit returns when its drain budget is exhausted while escalation continues")
    func registryReturnsWhenQuitBudgetExpires() async throws {
        let registry = ProcessRunner()
        let pidFile = fixturePIDFile()
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let call = Task {
            try await registry.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "trap '' TERM; printf '%s\n' \"$$\" > \"$1\"; exec /bin/sleep 8", "helix-test", pidFile.path],
                deadline: .seconds(6)
            )
        }
        defer { call.cancel() }
        let pid = try await processIdentifier(writtenTo: pidFile)
        defer { endFixture(pid) }

        let budget: Duration = .milliseconds(30)
        let began = ContinuousClock.now
        let result = try await withTimeout(seconds: 2) { await registry.terminateAll(within: budget) }
        let elapsed = began.duration(to: .now)

        #expect(elapsed >= budget)
        #expect(result.interrupted == 1)
        #expect(result.unfinished == 1)
        await #expect(throws: CancellationError.self) {
            try await withTimeout(seconds: 2) { try await call.value }
        }
        #expect(fixtureIsGone(pid))
    }

    @Test("A completed command leaves no child in the registry")
    func registryIsEmptyAfterCompletion() async throws {
        let registry = ProcessRunner()
        let output = try await withTimeout(seconds: 2) {
            try await registry.run(executablePath: "/usr/bin/printf", arguments: ["finished"], deadline: .seconds(1))
        }
        let stopped = try await withTimeout(seconds: 2) { await registry.terminateAll() }

        #expect(output == "finished")
        #expect(stopped.interrupted == 0)
        #expect(stopped.unfinished == 0)
    }
}

private func runBoundedShell(_ script: String, pidFile: URL, duration: Duration) async throws -> String {
    try await runProcess(
        executablePath: "/bin/sh", arguments: ["-c", script, "helix-test", pidFile.path], deadline: duration
    )
}

private func fixturePIDFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("helix-process-\(UUID().uuidString).pid")
}

private func fixtureIsGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}

private func endFixture(_ pid: pid_t) {
    if !fixtureIsGone(pid) { kill(pid, SIGKILL) }
}

private func deadlineFailure(of call: Task<String, Error>) async -> String {
    do {
        let result = try await withTimeout(seconds: 2) { try await call.value }
        return "Command unexpectedly returned \(result)"
    } catch {
        return (error as? TimedOut)?.description ?? error.localizedDescription
    }
}

private struct NoProcessIdentifier: Error, CustomStringConvertible {
    let file: URL
    var description: String { "no process identifier was written to \(file.path) within 5 seconds" }
}

/// Waits for a child to write its process identifier to a file and returns it.
private func processIdentifier(writtenTo file: URL) async throws -> pid_t {
    for _ in 0..<100 {
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let identifier = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return identifier
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw NoProcessIdentifier(file: file)
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
