// ABOUTME: Exercises daemon discovery with command lines and executable paths from a process table.
// ABOUTME: Covers both launch forms, executable and user scoping, and multiple matches.

import Darwin
import Foundation
import Testing
@testable import HelixKit

struct DaemonProcessTests {
    private static let executable = "/test/Mutagen (18).bin"

    @Test("Daemon discovery accepts both exact command lines", arguments: ["mutagen", executable])
    func recognizesBothDaemonLaunchForms(argvZero: String) async throws {
        let daemonPID = try #require(ProcessID(101))
        let daemon = processTable([
            .init(daemonPID, command: "\(argvZero) daemon run", executable: Self.executable),
            .init(try #require(ProcessID(102)), command: "mutagen sync list", executable: Self.executable),
            .init(try #require(ProcessID(103)), command: "mutagen daemon run --help", executable: Self.executable),
            .init(try #require(ProcessID(104)), command: "mutagen daemon run", executable: "/test/other-mutagen"),
            .init(try #require(ProcessID(105)), command: "\(Self.executable) daemon run", executable: "/test/other-mutagen"),
            .init(try #require(ProcessID(106)), command: "mutagen daemon run", executable: Self.executable, uid: getuid() &+ 1),
        ])

        #expect(try await daemon.pid() == daemonPID)
    }

    @Test("Two daemon launch forms for the same executable remain ambiguous")
    func severalMatchingDaemonsAreRejected() async throws {
        let first = try #require(ProcessID(101))
        let second = try #require(ProcessID(102))
        let daemon = processTable([
            .init(first, command: "\(Self.executable) daemon run", executable: Self.executable),
            .init(second, command: "mutagen daemon run", executable: Self.executable),
        ])

        await #expect(throws: DaemonProcessError.severalDaemons([first, second])) {
            try await daemon.pid()
        }
    }

    private func processTable(_ processes: [Process]) -> MutagenDaemon {
        MutagenDaemon(cliPath: Self.executable, findProcesses: { arguments in
            #expect(arguments.dropLast() == ["-U", String(getuid()), "-f", "-x", "--"])
            let pattern = try #require(arguments.last)
            let matches = processes.filter {
                $0.uid == getuid() && $0.command.range(of: "^(\(pattern))$", options: .regularExpression) != nil
            }
            if matches.isEmpty { throw CLIError(exitCode: 1, stderr: "") }
            return matches.map { $0.pid.description }.joined(separator: "\n")
        }, executablePath: { pid in
            processes.first { $0.pid == pid }?.executable
        })
    }

    private struct Process: Sendable {
        let pid: ProcessID
        let command: String
        let executable: String
        let uid: uid_t

        init(_ pid: ProcessID, command: String, executable: String, uid: uid_t = getuid()) {
            self.pid = pid
            self.command = command
            self.executable = executable
            self.uid = uid
        }
    }
}
