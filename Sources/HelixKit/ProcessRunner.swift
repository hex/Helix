// ABOUTME: Runs commands with bounded execution and captures their output.
// ABOUTME: Terminates a child and closes its pipes on cancellation or deadline expiry.

import Darwin
import Dispatch
import Foundation

public enum CommandDeadline {
    public static let query: Duration = .seconds(15)
    public static let operation: Duration = .seconds(45)
    public static let transfer: Duration = .seconds(900)
    static let terminationGrace: Duration = .milliseconds(250)
}

public struct ProcessDeadlineError: LocalizedError, Sendable {
    public let executablePath: String
    public let deadline: Duration

    public var errorDescription: String? {
        "\(executablePath) exceeded its deadline of \(deadline)."
    }
}

/// Returns the child's stdout or throws its launch error, exit error, cancellation, or deadline error.
public func runProcess(
    executablePath: String, arguments: [String], deadline: Duration = CommandDeadline.query
) async throws -> String {
    try await ProcessRunner.shared.run(executablePath: executablePath, arguments: arguments, deadline: deadline)
}

public actor ProcessRunner {
    public static let shared = ProcessRunner()

    private var children: [ObjectIdentifier: RunningChild] = [:]
    private var isShuttingDown = false

    func run(executablePath: String, arguments: [String], deadline: Duration) async throws -> String {
        precondition(deadline > .zero, "Command deadlines must be positive")
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }

        let child = RunningChild(executablePath: executablePath, arguments: arguments, deadline: deadline)
        let identifier = ObjectIdentifier(child)
        children[identifier] = child
        defer { children.removeValue(forKey: identifier) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                child.launch(continuation)
            }
        } onCancel: {
            child.interrupt(throwing: CancellationError())
        }
    }

    /// Closes command admission, ends every tracked command, and returns their count.
    @discardableResult
    public func terminateAll() async -> Int {
        isShuttingDown = true
        let running = Array(children.values)
        for child in running { child.interrupt(throwing: CancellationError()) }
        for child in running { await child.waitUntilFinished() }
        children.removeAll()
        return running.count
    }
}

private final class RunningChild: @unchecked Sendable {
    // The queue owns the process, the pipe buffers, and all lifecycle transitions.
    private let queue = DispatchQueue(label: "helix.process")
    private let process = Process()
    private let executablePath: String
    private let deadline: Duration
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var continuation: CheckedContinuation<String, Error>?
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []
    private var channels: [DispatchIO] = []
    private var deadlineTimer: DispatchSourceTimer?
    private var openPipes = 0
    private var stdout = Data()
    private var stderr = Data()
    private var exitStatus: Int32?
    private var processGroup: pid_t?
    private var interruption: Error?
    private var escalating = false
    private var finished = false

    init(executablePath: String, arguments: [String], deadline: Duration) {
        self.executablePath = executablePath
        self.deadline = deadline
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func launch(_ continuation: CheckedContinuation<String, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            if let interruption = self.interruption {
                self.complete(.failure(interruption))
                return
            }

            // Process delivers the exit through this handler even for very short-lived commands.
            self.process.terminationHandler = { [self] child in
                let status = child.terminationStatus
                queue.async {
                    self.exitStatus = status
                    self.finishIfReady()
                }
            }

            do {
                try self.process.run()
            } catch {
                self.complete(.failure(error))
                return
            }

            let pid = self.process.processIdentifier
            let group = getpgid(pid)
            // The child may have exited while its descendants still hold its process group.
            if group == pid || (group == -1 && errno == ESRCH && kill(-pid, 0) == 0) {
                self.processGroup = pid
            }

            // Drain both pipes while the child runs so a full buffer cannot stall it.
            self.openPipes = 2
            self.channels = [
                self.drain(self.stdoutPipe.fileHandleForReading, as: \.stdout),
                self.drain(self.stderrPipe.fileHandleForReading, as: \.stderr),
            ]
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.deadline.timeInterval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.beginInterruption(ProcessDeadlineError(executablePath: self.executablePath, deadline: self.deadline))
            }
            self.deadlineTimer = timer
            timer.activate()
        }
    }

    func interrupt(throwing error: Error) {
        queue.async { self.beginInterruption(error) }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.finished {
                    continuation.resume()
                } else {
                    self.completionWaiters.append(continuation)
                }
            }
        }
    }

    private func beginInterruption(_ error: Error) {
        guard !finished, interruption == nil else { return }
        interruption = error
        guard continuation != nil else { return }

        escalating = true
        signal(SIGTERM)
        for channel in channels { channel.close(flags: .stop) }

        queue.asyncAfter(deadline: .now() + CommandDeadline.terminationGrace.timeInterval) {
            self.signal(SIGKILL)
            self.escalating = false
            self.finishIfReady()
        }
    }

    private func signal(_ signal: Int32) {
        if let processGroup {
            kill(-processGroup, signal)
        } else if exitStatus == nil, process.isRunning {
            kill(process.processIdentifier, signal)
        }
    }

    private func drain(_ handle: FileHandle, as output: ReferenceWritableKeyPath<RunningChild, Data>) -> DispatchIO {
        let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { error in
            do {
                try handle.close()
            } catch {
                self.beginInterruption(error)
            }
            if error != 0 { self.pipeFailed(error) }
            self.openPipes -= 1
            self.finishIfReady()
        }
        channel.read(offset: 0, length: Int.max, queue: queue) { done, bytes, error in
            if let bytes { self[keyPath: output].append(contentsOf: bytes) }
            if error != 0 { self.pipeFailed(error) }
            if done { channel.close() }
        }
        return channel
    }

    private func pipeFailed(_ error: Int32) {
        beginInterruption(NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: [
            NSLocalizedDescriptionKey: "Could not read output from \(executablePath): \(String(cString: strerror(error)))",
        ]))
    }

    private func finishIfReady() {
        guard !finished, !escalating, let exitStatus, openPipes == 0 else { return }
        if let interruption {
            complete(.failure(interruption))
        } else if exitStatus == 0 {
            complete(.success(String(data: stdout, encoding: .utf8) ?? ""))
        } else {
            let message = String(data: stderr, encoding: .utf8) ?? ""
            complete(.failure(CLIError(exitCode: exitStatus, stderr: message.trimmingCharacters(in: .whitespacesAndNewlines))))
        }
    }

    private func complete(_ result: Result<String, Error>) {
        finished = true
        deadlineTimer?.cancel()
        deadlineTimer = nil
        process.terminationHandler = nil
        channels.removeAll()
        let waiting = continuation
        continuation = nil
        waiting?.resume(with: result)
        for waiter in completionWaiters { waiter.resume() }
        completionWaiters.removeAll()
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
