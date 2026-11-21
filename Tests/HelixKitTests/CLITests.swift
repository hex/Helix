// ABOUTME: Tests for the CLI wrapper that shells out to mutagen.
// ABOUTME: Uses a mock script to simulate mutagen output without requiring the real binary.

import Testing
import Foundation
@testable import HelixKit

@Suite("CLI command execution")
struct CLITests {

    func fixturePath(_ name: String) -> String {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!.path
    }

    @Test("syncList parses JSON into SyncSession array")
    func syncList() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        let sessions = try await cli.syncList()

        #expect(sessions.count == 1)
        #expect(sessions[0].name == "test-session")
        #expect(sessions[0].status == "watching")
    }

    @Test("Reads the session identifier from a Mutagen create receipt", arguments: ["", "Connecting to beta...\r"])
    func parsesSyncCreateReceipt(status: String) async throws {
        let identifier = "sync_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
        let cli = CLI(executablePath: "/usr/bin/printf", baseArguments: ["%s\n"])
        let result = try await cli.syncCreate(arguments: [status + "Created session " + identifier])
        #expect(result == identifier)
    }

    @Test("forwardList parses JSON into ForwardSession array")
    func forwardList() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        let sessions = try await cli.forwardList()

        #expect(sessions.isEmpty)
    }

    @Test("version returns version string")
    func version() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        let version = try await cli.version()

        #expect(version == "0.18.1")
    }

    @Test("CLI throws on non-zero exit code")
    func errorHandling() async throws {
        let script = fixturePath("mock-mutagen-error.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])

        await #expect(throws: CLIError.self) {
            _ = try await cli.syncList()
        }
    }

    @Test("CLI captures stderr in error")
    func stderrCapture() async throws {
        let script = fixturePath("mock-mutagen-error.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])

        do {
            _ = try await cli.syncList()
            Issue.record("Expected CLIError to be thrown")
        } catch let error as CLIError {
            #expect(error.stderr.contains("daemon not running"))
        }
    }

    @Test("daemonStatus returns running when daemon is active")
    func daemonStatus() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        let running = try await cli.daemonRunning()

        #expect(running == true)
    }

    @Test("syncPause completes without error")
    func syncPause() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        try await cli.syncPause("sync_test123")
    }

    @Test("syncResume completes without error")
    func syncResume() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        try await cli.syncResume("sync_test123")
    }

    @Test("syncFlush completes without error")
    func syncFlush() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        try await cli.syncFlush("sync_test123")
    }

    @Test("syncReset completes without error")
    func syncReset() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        try await cli.syncReset("sync_test123")
    }

    @Test("syncTerminate completes without error")
    func syncTerminate() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        try await cli.syncTerminate("sync_test123")
    }

    @Test("forwardPause completes without error")
    func forwardPause() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        try await cli.forwardPause("fwd_test123")
    }

    @Test("forwardResume completes without error")
    func forwardResume() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        try await cli.forwardResume("fwd_test123")
    }

    @Test("forwardTerminate completes without error")
    func forwardTerminate() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        try await cli.forwardTerminate("fwd_test123")
    }

    @Test("daemonStop completes without error")
    func daemonStop() async throws {
        let script = fixturePath("mock-mutagen.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])
        try await cli.daemonStop()
    }

    @Test("action methods throw on error")
    func actionError() async throws {
        let script = fixturePath("mock-mutagen-error.sh")
        let cli = CLI(executablePath: "/bin/bash", baseArguments: [script])

        await #expect(throws: CLIError.self) {
            try await cli.syncPause("nonexistent")
        }
    }
}
