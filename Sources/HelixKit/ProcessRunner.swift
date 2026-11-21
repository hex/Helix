// ABOUTME: Async wrapper for running shell processes with stdout/stderr capture.
// ABOUTME: Shared by CLI (mutagen commands) and FileTransport (cp/scp/docker-cp).

import Foundation

/// Runs a command to its end and returns its standard output, or throws `CLIError` when it exits non-zero.
///
/// Cancelling the calling task sends the child SIGTERM. The call still waits for the child to end: it throws
/// `CancellationError` when a signal ended the child, and reports the child's own exit otherwise. A call made
/// in a task that is already cancelled throws `CancellationError` without starting the command.
public func runProcess(executablePath: String, arguments: [String]) async throws -> String {
    try Task.checkCancellation()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // The end arrives through the termination handler: waitUntilExit, called off the main thread,
    // can miss the exit of a short-lived child and then never return.
    let childEnd = ChildEnd()
    process.terminationHandler = { finished in
        childEnd.report(ChildEnd.Report(status: finished.terminationStatus, reason: finished.terminationReason))
    }

    try process.run()

    let child = RunningChild(process: process)
    return try await withTaskCancellationHandler {
        // Both pipes are drained while the child runs: a child whose output fills a pipe's
        // buffer blocks until that pipe is read, and never exits.
        async let stdoutData = readToEnd(stdoutPipe.fileHandleForReading)
        async let stderrData = readToEnd(stderrPipe.fileHandleForReading)
        let stdout = String(data: await stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: await stderrData, encoding: .utf8) ?? ""
        let end = await childEnd.reported()

        if end.reason == .uncaughtSignal && Task.isCancelled {
            throw CancellationError()
        }
        guard end.status == 0 else {
            throw CLIError(
                exitCode: end.status,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return stdout
    } onCancel: {
        child.terminate()
    }
}

/// Reads a pipe to its end on a dispatch thread, so the blocking read never holds a Swift concurrency thread.
private func readToEnd(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: handle.readDataToEndOfFile())
        }
    }
}

/// A launched child that any thread may ask to end.
private struct RunningChild: @unchecked Sendable {
    // Process is not Sendable. This type only ever calls terminate on it, which sends the child
    // a signal and reads no state that the launching task writes after launch.
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func terminate() {
        process.terminate()
    }
}

/// How a child ended, handed from its termination handler to the one task that waits for it.
/// The wait does not end when the waiting task is cancelled, only when the child does.
private final class ChildEnd: @unchecked Sendable {
    struct Report {
        let status: Int32
        let reason: Process.TerminationReason
    }

    private let lock = NSLock()
    private var report: Report?
    private var waiter: CheckedContinuation<Report, Never>?

    func report(_ report: Report) {
        lock.lock()
        self.report = report
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: report)
    }

    func reported() async -> Report {
        await withCheckedContinuation { continuation in
            lock.lock()
            let report = self.report
            if report == nil { waiter = continuation }
            lock.unlock()
            if let report { continuation.resume(returning: report) }
        }
    }
}
