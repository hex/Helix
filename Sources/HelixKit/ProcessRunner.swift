// ABOUTME: Runs commands with bounded execution and captures their output.
// ABOUTME: Terminates a child and closes its pipes on cancellation or deadline expiry.

import Darwin
import Dispatch
import Foundation

public enum CommandDeadline {
    public static let query: Duration = .seconds(15)
    public static let operation: Duration = .seconds(45)
    public static let transfer: Duration = .seconds(900)
    public static let quitDrain: Duration = .seconds(3)
    static let terminationGrace: Duration = .milliseconds(250)
}

public struct ProcessDeadlineError: LocalizedError, Sendable {
    public let executablePath: String
    public let deadline: Duration

    public var errorDescription: String? {
        "\(executablePath) exceeded its deadline of \(deadline)."
    }
}

extension Error {
    var isCommandInterruption: Bool {
        if let mutation = self as? MutationNotConfirmed { return mutation.cause.isCommandInterruption }
        return self is CancellationError || self is ProcessDeadlineError
    }
}

/// Returns the child's stdout or throws its launch error, exit error, cancellation, or deadline error.
public func runProcess(
    executablePath: String, arguments: [String], deadline: Duration = CommandDeadline.query
) async throws -> String {
    try await ProcessRunner.shared.run(executablePath: executablePath, arguments: arguments, deadline: deadline)
}

public actor ProcessRunner {
    public struct DrainReport: Sendable {
        public let interrupted: Int
        public let unfinished: Int
    }

    private struct DrainWaiter {
        let continuation: CheckedContinuation<Void, Never>
        let timer: Task<Void, Never>
    }

    public static let shared = ProcessRunner()

    private var drainWaiters: [UUID: DrainWaiter] = [:]
    private var children: [ObjectIdentifier: RunningChild] = [:]
    private var isShuttingDown = false
    private let waitForDeadline: @Sendable (SuspendingClock.Instant) async throws -> Void

    init(waitForDeadline: @escaping @Sendable (SuspendingClock.Instant) async throws -> Void = {
        try await SuspendingClock().sleep(until: $0)
    }) {
        self.waitForDeadline = waitForDeadline
    }

    func run(executablePath: String, arguments: [String], deadline: Duration) async throws -> String {
        precondition(deadline > .zero, "Command deadlines must be positive")
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }

        let child = RunningChild(
            executablePath: executablePath, arguments: arguments, deadline: deadline, waitForDeadline: waitForDeadline
        )
        let identifier = ObjectIdentifier(child)
        children[identifier] = child
        defer {
            children.removeValue(forKey: identifier)
            if children.isEmpty {
                for waiter in Array(drainWaiters.keys) { finishDrain(waiter) }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                child.launch(continuation)
            }
        } onCancel: {
            child.interrupt(throwing: CancellationError())
        }
    }

    /// Closes command admission, interrupts tracked commands, and waits within the quit budget.
    @discardableResult
    public func terminateAll(within budget: Duration = CommandDeadline.quitDrain) async -> DrainReport {
        precondition(budget >= .zero, "The quit budget must not be negative")
        let deadline = ContinuousClock.now.advanced(by: budget)
        isShuttingDown = true
        let count = children.count
        for child in children.values { child.interrupt(throwing: CancellationError()) }
        if count > 0, ContinuousClock.now < deadline {
            let id = UUID()
            await withCheckedContinuation { continuation in
                let timer = Task { [weak self] in
                    guard (try? await ContinuousClock().sleep(until: deadline)) != nil else { return }
                    await self?.finishDrain(id)
                }
                drainWaiters[id] = DrainWaiter(continuation: continuation, timer: timer)
            }
        }
        return DrainReport(interrupted: count, unfinished: children.count)
    }

    private func finishDrain(_ id: UUID) {
        guard let waiter = drainWaiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume()
    }
}

private final class RunningChild: @unchecked Sendable {
    // The queue owns the process, the pipe buffers, and all lifecycle transitions.
    private let queue = DispatchQueue(label: "helix.process")
    private let process = Process()
    private let executablePath: String
    private let deadline: Duration
    private let waitForDeadline: @Sendable (SuspendingClock.Instant) async throws -> Void
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var continuation: CheckedContinuation<String, Error>?
    private var channels: [DispatchIO] = []
    private var deadlineTimer: Task<Void, Never>?
    private var openPipes = 0
    private var stdout = Data()
    private var stderr = Data()
    private var exitStatus: Int32?
    private var processGroup: pid_t?
    private var interruption: Error?
    private var escalating = false
    private var finished = false

    init(
        executablePath: String, arguments: [String], deadline: Duration,
        waitForDeadline: @escaping @Sendable (SuspendingClock.Instant) async throws -> Void
    ) {
        self.executablePath = executablePath
        self.deadline = deadline
        self.waitForDeadline = waitForDeadline
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
            self.startDeadline()
        }
    }

    private func startDeadline() {
        let expiry = SuspendingClock.now.advanced(by: deadline)
        let error = ProcessDeadlineError(executablePath: executablePath, deadline: deadline)
        deadlineTimer = Task { [weak self, waitForDeadline] in
            do {
                try await waitForDeadline(expiry)
                self?.interrupt(throwing: error)
            } catch is CancellationError {
                return
            } catch {
                self?.interrupt(throwing: error)
            }
        }
    }

    func interrupt(throwing error: Error) {
        queue.async { self.beginInterruption(error) }
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
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
