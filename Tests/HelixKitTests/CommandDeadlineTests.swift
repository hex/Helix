// ABOUTME: Verifies the deadline requested by each transfer-sensitive command.
// ABOUTME: Observes the actual executor boundary without contacting Mutagen or a remote host.

import Testing
@testable import HelixKit

@Suite("Command deadline classes")
struct CommandDeadlineTests {
    @Test("File copies and tree removal use the transfer class")
    func fileCommandsUseTransferDeadline() async throws {
        let observed = CommandObservations()
        let transport = FileTransport { path, arguments, deadline in
            await observed.run(path, arguments, deadline)
        }
        let source = EndpointURL.local(path: "/tmp/deadline-source")
        let destination = EndpointURL.local(path: "/tmp/deadline-destination")

        try await transport.copy(from: source, to: destination)
        try await transport.remove(endpoint: destination)

        #expect(await observed.calls == [
            .init(path: "/bin/cp", arguments: ["-Rp", "/tmp/deadline-source", "/tmp/deadline-destination"], deadline: CommandDeadline.transfer),
            .init(path: "/bin/rm", arguments: ["-rf", "/tmp/deadline-destination"], deadline: CommandDeadline.transfer),
        ])
    }

    @Test("Sync creation, resume, and flush use the transfer class")
    func syncCommandsUseTransferDeadline() async throws {
        let observed = CommandObservations()
        let cli = CLI(executablePath: "/usr/bin/mutagen", baseArguments: []) { path, arguments, deadline in
            await observed.run(path, arguments, deadline)
        }
        let arguments = SyncCreateOptions().arguments(alpha: "/tmp/alpha", beta: "/tmp/beta")
        let identifier = try await cli.syncCreate(arguments: arguments)
        try await cli.syncResume(identifier)
        try await cli.syncFlush(identifier)

        #expect(await observed.calls == [
            .init(path: "/usr/bin/mutagen", arguments: ["sync", "create", "/tmp/alpha", "/tmp/beta"], deadline: CommandDeadline.transfer),
            .init(path: "/usr/bin/mutagen", arguments: ["sync", "resume", identifier], deadline: CommandDeadline.transfer),
            .init(path: "/usr/bin/mutagen", arguments: ["sync", "flush", identifier], deadline: CommandDeadline.transfer),
        ])
    }
}

private actor CommandObservations {
    struct Call: Equatable {
        let path: String
        let arguments: [String]
        let deadline: Duration
    }

    private(set) var calls: [Call] = []

    func run(_ path: String, _ arguments: [String], _ deadline: Duration) -> String {
        calls.append(.init(path: path, arguments: arguments, deadline: deadline))
        return "Created session sync_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
    }
}
