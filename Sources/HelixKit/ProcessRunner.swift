// ABOUTME: Async wrapper for running shell processes with stdout/stderr capture.
// ABOUTME: Shared by CLI (mutagen commands) and FileTransport (cp/scp/docker-cp).

import Foundation

public func runProcess(executablePath: String, arguments: [String]) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // The exit code arrives through the termination handler: waitUntilExit, called off the main thread,
    // can miss the exit of a short-lived child and then never return.
    let (exitCodes, exitCodeSource) = AsyncStream<Int32>.makeStream()
    process.terminationHandler = { finished in
        exitCodeSource.yield(finished.terminationStatus)
        exitCodeSource.finish()
    }

    try process.run()

    // Both pipes are drained while the child runs: a child whose output fills a pipe's
    // buffer blocks until that pipe is read, and never exits.
    async let stdoutData = readToEnd(stdoutPipe.fileHandleForReading)
    async let stderrData = readToEnd(stderrPipe.fileHandleForReading)
    let stdout = String(data: await stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: await stderrData, encoding: .utf8) ?? ""
    var exitCodeIterator = exitCodes.makeAsyncIterator()
    guard let exitCode = await exitCodeIterator.next() else {
        preconditionFailure("\(executablePath) ended without its termination handler reporting an exit code")
    }

    guard exitCode == 0 else {
        throw CLIError(
            exitCode: exitCode,
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
    return stdout
}

/// Reads a pipe to its end on a dispatch thread, so the blocking read never holds a Swift concurrency thread.
private func readToEnd(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: handle.readDataToEndOfFile())
        }
    }
}
