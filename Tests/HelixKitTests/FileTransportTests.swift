// ABOUTME: Tests for FileTransport command generation and stat output parsing.
// ABOUTME: Uses injectable execute closure to verify correct commands without running processes.

import Testing
import Foundation
@testable import HelixKit

@Suite("FileTransport copy commands")
struct FileTransportCopyTests {

    // MARK: - Local to Local

    @Test("local to local uses cp")
    func localToLocal() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.copy(
            from: .local(path: "/tmp/a/file.txt"),
            to: .local(path: "/tmp/b/file.txt")
        )

        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/bin/cp")
        #expect(cmd.arguments == ["-Rp", "/tmp/a/file.txt", "/tmp/b/file.txt"])
    }

    // MARK: - Local <-> SSH

    @Test("local to ssh uses scp")
    func localToSSH() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.copy(
            from: .local(path: "/tmp/a/file.txt"),
            to: .ssh(user: "deploy", host: "server.example.test", port: nil, path: "/opt/file.txt")
        )

        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/scp")
        #expect(cmd.arguments == connectionOptions + ["-r", "/tmp/a/file.txt", "deploy@server.example.test:/opt/file.txt"])
    }

    @Test("ssh to local uses scp")
    func sshToLocal() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.copy(
            from: .ssh(user: nil, host: "server.example.test", port: nil, path: "/opt/file.txt"),
            to: .local(path: "/tmp/b/file.txt")
        )

        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/scp")
        #expect(cmd.arguments == connectionOptions + ["-r", "server.example.test:/opt/file.txt", "/tmp/b/file.txt"])
    }

    @Test("ssh with port uses scp -P flag")
    func sshWithPort() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.copy(
            from: .local(path: "/tmp/file.txt"),
            to: .ssh(user: "root", host: "box", port: 2222, path: "/data/file.txt")
        )

        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/scp")
        #expect(cmd.arguments == connectionOptions + ["-r", "-P", "2222", "/tmp/file.txt", "root@box:/data/file.txt"])
    }

    // MARK: - Local <-> Docker

    @Test("local to docker uses docker cp")
    func localToDocker() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.copy(
            from: .local(path: "/tmp/a/file.txt"),
            to: .docker(container: "myapp", path: "/app/file.txt")
        )

        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/docker")
        #expect(cmd.arguments == ["cp", "/tmp/a/file.txt", "myapp:/app/file.txt"])
    }

    @Test("docker to local uses docker cp")
    func dockerToLocal() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.copy(
            from: .docker(container: "myapp", path: "/app/file.txt"),
            to: .local(path: "/tmp/b/file.txt")
        )

        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/docker")
        #expect(cmd.arguments == ["cp", "myapp:/app/file.txt", "/tmp/b/file.txt"])
    }

    // MARK: - SSH to SSH

    @Test("ssh to ssh uses scp directly")
    func sshToSSH() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.copy(
            from: .ssh(user: "a", host: "host1", port: nil, path: "/file.txt"),
            to: .ssh(user: "b", host: "host2", port: nil, path: "/file.txt")
        )

        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/scp")
        #expect(cmd.arguments == connectionOptions + ["-3", "-r", "a@host1:/file.txt", "b@host2:/file.txt"])
    }

    // MARK: - Cross-transport (via temp file)

    @Test("ssh to docker copies via temp file")
    func sshToDocker() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.copy(
            from: .ssh(user: "deploy", host: "server", port: nil, path: "/opt/file.txt"),
            to: .docker(container: "myapp", path: "/app/file.txt")
        )

        // Should be 2 commands: scp to temp, docker cp from temp
        #expect(recorder.commands.count == 2)
        let scpCmd = recorder.commands[0]
        #expect(scpCmd.executable == "/usr/bin/scp")
        #expect(scpCmd.arguments.contains("deploy@server:/opt/file.txt"))

        let dockerCmd = recorder.commands[1]
        #expect(dockerCmd.executable == "/usr/bin/docker")
        #expect(dockerCmd.arguments.first == "cp")
        #expect(dockerCmd.arguments.last == "myapp:/app/file.txt")
    }

    @Test("docker to ssh copies via temp file")
    func dockerToSSH() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.copy(
            from: .docker(container: "myapp", path: "/app/file.txt"),
            to: .ssh(user: "deploy", host: "server", port: nil, path: "/opt/file.txt")
        )

        #expect(recorder.commands.count == 2)
        let dockerCmd = recorder.commands[0]
        #expect(dockerCmd.executable == "/usr/bin/docker")

        let scpCmd = recorder.commands[1]
        #expect(scpCmd.executable == "/usr/bin/scp")
    }

    @Test("docker to docker copies via temp file")
    func dockerToDocker() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.copy(
            from: .docker(container: "app1", path: "/file.txt"),
            to: .docker(container: "app2", path: "/file.txt")
        )

        #expect(recorder.commands.count == 2)
        #expect(recorder.commands[0].executable == "/usr/bin/docker")
        #expect(recorder.commands[1].executable == "/usr/bin/docker")
    }
}

@Suite("FileTransport stat parsing")
struct FileTransportStatTests {

    @Test("stat parses local macOS output")
    func statLocal() async throws {
        let recorder = CommandRecorder(output: "1024 1700000000")
        let transport = FileTransport(execute: recorder.execute)

        let info = try await transport.stat(endpoint: .local(path: "/tmp/file.txt"))

        #expect(info.size == 1024)
        #expect(info.modifiedAt == Date(timeIntervalSince1970: 1700000000))
        #expect(info.isSymlink == false)
        #expect(info.symlinkTarget == nil)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/stat")
        #expect(cmd.arguments == ["-f", "%z %m", "/tmp/file.txt"])
    }

    @Test("stat parses ssh remote output")
    func statSSH() async throws {
        let recorder = CommandRecorder(output: "2048 1700000000")
        let transport = FileTransport(execute: recorder.execute)

        let info = try await transport.stat(
            endpoint: .ssh(user: "deploy", host: "server", port: nil, path: "/opt/file.txt")
        )

        #expect(info.size == 2048)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        // Uses cross-platform stat: tries GNU stat first, falls back to macOS stat
        #expect(cmd.arguments == connectionOptions + ["deploy@server", "stat -c '%s %Y' '/opt/file.txt' 2>/dev/null || stat -f '%z %m' '/opt/file.txt'"])
    }

    @Test("stat parses docker exec output")
    func statDocker() async throws {
        let recorder = CommandRecorder(output: "4096 1700000000")
        let transport = FileTransport(execute: recorder.execute)

        let info = try await transport.stat(
            endpoint: .docker(container: "myapp", path: "/app/file.txt")
        )

        #expect(info.size == 4096)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/docker")
        #expect(cmd.arguments == ["exec", "myapp", "stat", "-c", "%s %Y", "/app/file.txt"])
    }

    @Test("stat ssh with port passes -p flag")
    func statSSHWithPort() async throws {
        let recorder = CommandRecorder(output: "512 1700000000")
        let transport = FileTransport(execute: recorder.execute)

        _ = try await transport.stat(
            endpoint: .ssh(user: nil, host: "box", port: 2222, path: "/file.txt")
        )

        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments == connectionOptions + ["-p", "2222", "box", "stat -c '%s %Y' '/file.txt' 2>/dev/null || stat -f '%z %m' '/file.txt'"])
    }

    @Test("stat throws on malformed output")
    func statMalformedOutput() async throws {
        let recorder = CommandRecorder(output: "garbage")
        let transport = FileTransport(execute: recorder.execute)

        await #expect(throws: FileTransportError.self) {
            try await transport.stat(endpoint: .local(path: "/tmp/file.txt"))
        }
    }
}

@Suite("FileTransport remove commands")
struct FileTransportRemoveTests {

    @Test("remove local uses rm -rf")
    func removeLocal() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.remove(endpoint: .local(path: "/tmp/a/dir"))

        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/bin/rm")
        #expect(cmd.arguments == ["-rf", "/tmp/a/dir"])
    }

    @Test("remove ssh uses ssh rm -rf")
    func removeSSH() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.remove(
            endpoint: .ssh(user: "deploy", host: "server.example.test", port: nil, path: "/opt/dir")
        )

        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments == connectionOptions + ["deploy@server.example.test", "rm -rf '/opt/dir'"])
    }

    @Test("remove ssh with port passes -p flag")
    func removeSSHWithPort() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.remove(
            endpoint: .ssh(user: nil, host: "box", port: 2222, path: "/data/dir")
        )

        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments == connectionOptions + ["-p", "2222", "box", "rm -rf '/data/dir'"])
    }

    @Test("remove docker uses docker exec rm -rf")
    func removeDocker() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.remove(
            endpoint: .docker(container: "myapp", path: "/app/dir")
        )

        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/docker")
        #expect(cmd.arguments == ["exec", "myapp", "rm", "-rf", "/app/dir"])
    }
}

@Suite("FileTransport SSH tilde expansion")
struct FileTransportTildeTests {

    @Test("remove ssh with tilde uses $HOME instead of literal ~")
    func removeTilde() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.remove(
            endpoint: .ssh(user: "alice", host: "server", port: nil, path: "~/.claude-sessions/teamcity/logs")
        )

        let cmd = recorder.commands[0]
        #expect(cmd.arguments == connectionOptions + ["alice@server", "rm -rf \"$HOME\"/'.claude-sessions/teamcity/logs'"])
    }

    @Test("directoryExists ssh with tilde uses $HOME")
    func directoryExistsTilde() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        _ = try await transport.directoryExists(
            endpoint: .ssh(user: "alice", host: "server", port: nil, path: "~/.claude-sessions/.git")
        )

        let cmd = recorder.commands[0]
        #expect(cmd.arguments == connectionOptions + ["alice@server", "test -d \"$HOME\"/'.claude-sessions/.git'"])
    }

    @Test("run ssh with tilde uses $HOME in cd")
    func runTilde() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        _ = try await transport.run(
            on: .ssh(user: "alice", host: "server", port: nil, path: "~/.claude-sessions"),
            command: "git init"
        )

        let cmd = recorder.commands[0]
        #expect(cmd.arguments == connectionOptions + ["alice@server", "cd \"$HOME\"/'.claude-sessions' && git init"])
    }

    @Test("absolute paths still use single quotes")
    func absolutePathStillSingleQuoted() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        try await transport.remove(
            endpoint: .ssh(user: "deploy", host: "server", port: nil, path: "/opt/dir")
        )

        let cmd = recorder.commands[0]
        #expect(cmd.arguments == connectionOptions + ["deploy@server", "rm -rf '/opt/dir'"])
    }
}

@Suite("FileTransport remote shell words")
struct FileTransportShellWordTests {

    @Test("a single quote inside a path stays part of one quoted word")
    func embeddedSingleQuote() {
        #expect(FileTransport.shellWord("/opt/it's.txt") == "'/opt/it'\\''s.txt'")
    }

    @Test("a home-relative path expands only $HOME and keeps command substitution literal")
    func homeRelativeCommandSubstitution() {
        #expect(FileTransport.shellWord("~/$(touch x)") == "\"$HOME\"/'$(touch x)'")
    }
}

@Suite("FileTransport replace")
struct FileTransportReplaceTests {

    private let source = EndpointURL.local(path: "/tmp/a/file.txt")
    private let destination = EndpointURL.ssh(user: "deploy", host: "server", port: nil, path: "/opt/app/file.txt")

    /// The per-call token in the sibling names, read from the copy that replace issues first.
    private func token(in commands: [RecordedCommand]) throws -> String {
        let copyTarget = try #require(commands.first?.arguments.last)
        let marker = "deploy@server:/opt/app/.helix-incoming-"
        try #require(copyTarget.hasPrefix(marker))
        return String(copyTarget.dropFirst(marker.count))
    }

    @Test("replacing local to ssh copies beside the destination before anything touches it")
    func copiesBesideBeforeTouchingDestination() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport { executable, arguments in
            let output = try await recorder.execute(executable, arguments)
            if let command = arguments.last,
               command.hasPrefix("test -e '/opt/app/file.txt/") || command.hasPrefix("test -L '/opt/app/file.txt/") {
                throw CLIError(exitCode: 1, stderr: "")
            }
            return output
        }

        let outcome = try await transport.replace(ReplacePlan(replacing: destination, withCopyOf: source))

        #expect(outcome == .replaced)
        let token = try token(in: recorder.commands)
        let incoming = "/opt/app/.helix-incoming-\(token)"
        let setAside = "/opt/app/.helix-replaced-\(token)"
        #expect(recorder.commands.map(\.executable) == ["/usr/bin/scp"] + Array(repeating: "/usr/bin/ssh", count: 7))
        #expect(recorder.commands.map(\.arguments) == [
            connectionOptions + ["-r", "/tmp/a/file.txt", "deploy@server:\(incoming)"],
            connectionOptions + ["deploy@server", "test -e '/opt/app/file.txt'"],
            connectionOptions + ["deploy@server", "test -d '/opt/app/file.txt'"],
            connectionOptions + ["deploy@server", "mv '/opt/app/file.txt' '\(setAside)'"],
            connectionOptions + ["deploy@server", "mv '\(incoming)' '/opt/app/file.txt'"],
            connectionOptions + ["deploy@server", "test -e '/opt/app/file.txt/.helix-incoming-\(token)'"],
            connectionOptions + ["deploy@server", "test -L '/opt/app/file.txt/.helix-incoming-\(token)'"],
            connectionOptions + ["deploy@server", "rm -rf '\(setAside)'"],
        ])
    }

    @Test("a file replacing a file takes its name in one rename, with nothing set aside")
    func fileOverFileRenamesOnce() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport { executable, arguments in
            let output = try await recorder.execute(executable, arguments)
            // Neither the destination nor the copy beside it is a directory.
            if arguments.last?.hasPrefix("test -d ") == true {
                throw CLIError(exitCode: 1, stderr: "")
            }
            return output
        }

        let outcome = try await transport.replace(ReplacePlan(replacing: destination, withCopyOf: source))

        #expect(outcome == .replaced)
        let token = try token(in: recorder.commands)
        let incoming = "/opt/app/.helix-incoming-\(token)"
        #expect(recorder.commands.map(\.arguments) == [
            connectionOptions + ["-r", "/tmp/a/file.txt", "deploy@server:\(incoming)"],
            connectionOptions + ["deploy@server", "test -e '/opt/app/file.txt'"],
            connectionOptions + ["deploy@server", "test -d '/opt/app/file.txt'"],
            connectionOptions + ["deploy@server", "test -d '\(incoming)'"],
            connectionOptions + ["deploy@server", "mv '\(incoming)' '/opt/app/file.txt'"],
        ])
    }

    @Test("a failed copy removes the partial copy, leaves the destination alone, and throws")
    func failedCopyLeavesDestinationAlone() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport { executable, arguments in
            let output = try await recorder.execute(executable, arguments)
            if executable == "/usr/bin/scp" {
                throw CLIError(exitCode: 1, stderr: "lost connection")
            }
            return output
        }

        let error = try await #require(throws: (any Error).self) {
            _ = try await transport.replace(ReplacePlan(replacing: destination, withCopyOf: source))
        }

        let token = try token(in: recorder.commands)
        let incoming = "/opt/app/.helix-incoming-\(token)"
        #expect(error.localizedDescription == "Could not copy /tmp/a/file.txt to deploy@server:\(incoming): lost connection")
        #expect(recorder.commands.map(\.arguments) == [
            connectionOptions + ["-r", "/tmp/a/file.txt", "deploy@server:\(incoming)"],
            connectionOptions + ["deploy@server", "rm -rf '\(incoming)'"],
        ])
    }

    @Test("a failed move into place moves the original back, removes the unused copy, and throws")
    func failedMoveIntoPlaceRestoresOriginal() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport { executable, arguments in
            let movedAside = recorder.commands.contains { $0.arguments.last?.hasPrefix("mv '/opt/app/file.txt' ") == true }
            let output = try await recorder.execute(executable, arguments)
            if arguments.last?.hasPrefix("mv '/opt/app/.helix-incoming-") == true {
                throw CLIError(exitCode: 1, stderr: "permission denied")
            }
            // Once the original is set aside, nothing holds the destination's name.
            if movedAside, arguments.last == "test -e '/opt/app/file.txt'" || arguments.last == "test -L '/opt/app/file.txt'" {
                throw CLIError(exitCode: 1, stderr: "")
            }
            return output
        }

        let error = try await #require(throws: (any Error).self) {
            _ = try await transport.replace(ReplacePlan(replacing: destination, withCopyOf: source))
        }

        let token = try token(in: recorder.commands)
        let incoming = "/opt/app/.helix-incoming-\(token)"
        let setAside = "/opt/app/.helix-replaced-\(token)"
        #expect(error.localizedDescription == "Could not move deploy@server:\(incoming) into place at deploy@server:/opt/app/file.txt: permission denied. deploy@server:/opt/app/file.txt is unchanged")
        #expect(recorder.commands.map(\.arguments) == [
            connectionOptions + ["-r", "/tmp/a/file.txt", "deploy@server:\(incoming)"],
            connectionOptions + ["deploy@server", "test -e '/opt/app/file.txt'"],
            connectionOptions + ["deploy@server", "test -d '/opt/app/file.txt'"],
            connectionOptions + ["deploy@server", "mv '/opt/app/file.txt' '\(setAside)'"],
            connectionOptions + ["deploy@server", "mv '\(incoming)' '/opt/app/file.txt'"],
            connectionOptions + ["deploy@server", "test -e '/opt/app/file.txt'"],
            connectionOptions + ["deploy@server", "test -L '/opt/app/file.txt'"],
            connectionOptions + ["deploy@server", "test -e '\(incoming)'"],
            connectionOptions + ["deploy@server", "test -e '\(setAside)'"],
            connectionOptions + ["deploy@server", "mv '\(setAside)' '/opt/app/file.txt'"],
            connectionOptions + ["deploy@server", "rm -rf '\(incoming)'"],
        ])
    }
}

@Suite("FileTransport error propagation")
struct FileTransportErrorTests {

    @Test("copy propagates execute errors")
    func copyError() async throws {
        let transport = FileTransport { _, _ in
            throw CLIError(exitCode: 1, stderr: "permission denied")
        }

        await #expect(throws: CLIError.self) {
            try await transport.copy(
                from: .local(path: "/a"),
                to: .local(path: "/b")
            )
        }
    }

    @Test("stat propagates execute errors")
    func statError() async throws {
        let transport = FileTransport { _, _ in
            throw CLIError(exitCode: 1, stderr: "no such file")
        }

        await #expect(throws: CLIError.self) {
            try await transport.stat(endpoint: .local(path: "/nonexistent"))
        }
    }
}

@Suite("FileTransport directoryExists commands")
struct FileTransportDirectoryExistsTests {

    @Test("local directory exists runs test -d and returns true")
    func localExists() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.directoryExists(endpoint: .local(path: "/tmp/project/.git"))

        #expect(result == true)
        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/bin/test")
        #expect(cmd.arguments == ["-d", "/tmp/project/.git"])
    }

    @Test("local directory missing (exit 1) returns false")
    func localMissing() async throws {
        let recorder = CommandRecorder(error: CLIError(exitCode: 1, stderr: ""))
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.directoryExists(endpoint: .local(path: "/tmp/project/.git"))

        #expect(result == false)
    }

    @Test("ssh directory exists runs ssh test -d")
    func sshExists() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.directoryExists(
            endpoint: .ssh(user: "deploy", host: "server.example.test", port: nil, path: "/opt/project/.git")
        )

        #expect(result == true)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments == connectionOptions + ["deploy@server.example.test", "test -d '/opt/project/.git'"])
    }

    @Test("ssh with port includes -p flag")
    func sshWithPort() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.directoryExists(
            endpoint: .ssh(user: "root", host: "box", port: 2222, path: "/data/.git")
        )

        #expect(result == true)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments == connectionOptions + ["-p", "2222", "root@box", "test -d '/data/.git'"])
    }

    @Test("docker directory exists runs docker exec test -d")
    func dockerExists() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.directoryExists(
            endpoint: .docker(container: "myapp", path: "/app/.git")
        )

        #expect(result == true)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/docker")
        #expect(cmd.arguments == ["exec", "myapp", "test", "-d", "/app/.git"])
    }

    @Test("transport error (exit 255) rethrows instead of returning false")
    func transportError() async throws {
        let recorder = CommandRecorder(error: CLIError(exitCode: 255, stderr: "connection refused"))
        let transport = FileTransport(execute: recorder.execute)

        await #expect(throws: CLIError.self) {
            try await transport.directoryExists(endpoint: .local(path: "/tmp/.git"))
        }
    }
}

@Suite("FileTransport isSymlink commands")
struct FileTransportIsSymlinkTests {

    @Test("local symlink runs test -L and returns true")
    func localSymlink() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.isSymlink(endpoint: .local(path: "/tmp/link"))

        #expect(result == true)
        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/bin/test")
        #expect(cmd.arguments == ["-L", "/tmp/link"])
    }

    @Test("local non-symlink (exit 1) returns false")
    func localNotSymlink() async throws {
        let recorder = CommandRecorder(error: CLIError(exitCode: 1, stderr: ""))
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.isSymlink(endpoint: .local(path: "/tmp/regular"))

        #expect(result == false)
    }

    @Test("ssh symlink runs ssh test -L")
    func sshSymlink() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.isSymlink(
            endpoint: .ssh(user: "deploy", host: "server.example.test", port: nil, path: "/opt/link")
        )

        #expect(result == true)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments == connectionOptions + ["deploy@server.example.test", "test -L '/opt/link'"])
    }

    @Test("ssh with port includes -p flag")
    func sshWithPort() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.isSymlink(
            endpoint: .ssh(user: "root", host: "box", port: 2222, path: "/data/link")
        )

        #expect(result == true)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments == connectionOptions + ["-p", "2222", "root@box", "test -L '/data/link'"])
    }

    @Test("docker symlink runs docker exec test -L")
    func dockerSymlink() async throws {
        let recorder = CommandRecorder()
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.isSymlink(
            endpoint: .docker(container: "myapp", path: "/app/link")
        )

        #expect(result == true)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/docker")
        #expect(cmd.arguments == ["exec", "myapp", "test", "-L", "/app/link"])
    }

    @Test("transport error (exit 255) rethrows")
    func transportError() async throws {
        let recorder = CommandRecorder(error: CLIError(exitCode: 255, stderr: "connection refused"))
        let transport = FileTransport(execute: recorder.execute)

        await #expect(throws: CLIError.self) {
            try await transport.isSymlink(endpoint: .local(path: "/tmp/link"))
        }
    }
}

@Suite("FileTransport readLink commands")
struct FileTransportReadLinkTests {

    @Test("local readLink uses readlink")
    func readLinkLocal() async throws {
        let recorder = CommandRecorder(output: "/actual/target/path")
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.readLink(endpoint: .local(path: "/tmp/link"))

        #expect(result == "/actual/target/path")
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/readlink")
        #expect(cmd.arguments == ["/tmp/link"])
    }

    @Test("ssh readLink uses ssh readlink")
    func readLinkSSH() async throws {
        let recorder = CommandRecorder(output: "/remote/target\n")
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.readLink(
            endpoint: .ssh(user: "deploy", host: "server.example.test", port: nil, path: "/opt/link")
        )

        #expect(result == "/remote/target")
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments == connectionOptions + ["deploy@server.example.test", "readlink '/opt/link'"])
    }

    @Test("ssh readLink with port includes -p flag")
    func readLinkSSHWithPort() async throws {
        let recorder = CommandRecorder(output: "/target\n")
        let transport = FileTransport(execute: recorder.execute)

        _ = try await transport.readLink(
            endpoint: .ssh(user: nil, host: "box", port: 2222, path: "/data/link")
        )

        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments == connectionOptions + ["-p", "2222", "box", "readlink '/data/link'"])
    }

    @Test("docker readLink uses docker exec readlink")
    func readLinkDocker() async throws {
        let recorder = CommandRecorder(output: "/container/target\n")
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.readLink(
            endpoint: .docker(container: "myapp", path: "/app/link")
        )

        #expect(result == "/container/target")
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/docker")
        #expect(cmd.arguments == ["exec", "myapp", "readlink", "/app/link"])
    }

    @Test("ssh readLink with tilde uses $HOME")
    func readLinkSSHTilde() async throws {
        let recorder = CommandRecorder(output: "/target\n")
        let transport = FileTransport(execute: recorder.execute)

        _ = try await transport.readLink(
            endpoint: .ssh(user: "alice", host: "server", port: nil, path: "~/project/link")
        )

        let cmd = recorder.commands[0]
        #expect(cmd.arguments == connectionOptions + ["alice@server", "readlink \"$HOME\"/'project/link'"])
    }
}

@Suite("FileTransport run commands")
struct FileTransportRunTests {

    @Test("local run uses sh -c with cd")
    func runLocal() async throws {
        let recorder = CommandRecorder(output: "Initialized empty Git repository")
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.run(
            on: .local(path: "/tmp/project"),
            command: "git init"
        )

        #expect(result == "Initialized empty Git repository")
        #expect(recorder.commands.count == 1)
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/bin/sh")
        #expect(cmd.arguments == ["-c", "cd '/tmp/project' && git init"])
    }

    @Test("ssh run uses ssh with cd")
    func runSSH() async throws {
        let recorder = CommandRecorder(output: "main")
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.run(
            on: .ssh(user: "deploy", host: "server.example.test", port: nil, path: "/opt/project"),
            command: "git rev-parse --abbrev-ref HEAD"
        )

        #expect(result == "main")
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments == connectionOptions + ["deploy@server.example.test", "cd '/opt/project' && git rev-parse --abbrev-ref HEAD"])
    }

    @Test("ssh run with port includes -p flag")
    func runSSHWithPort() async throws {
        let recorder = CommandRecorder(output: "origin\thttps://git.example.test/example/repo.git")
        let transport = FileTransport(execute: recorder.execute)

        _ = try await transport.run(
            on: .ssh(user: "root", host: "box", port: 2222, path: "/data/project"),
            command: "git config --get remote.origin.url"
        )

        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments == connectionOptions + ["-p", "2222", "root@box", "cd '/data/project' && git config --get remote.origin.url"])
    }

    @Test("docker run uses docker exec sh -c")
    func runDocker() async throws {
        let recorder = CommandRecorder(output: "")
        let transport = FileTransport(execute: recorder.execute)

        _ = try await transport.run(
            on: .docker(container: "myapp", path: "/app"),
            command: "git init"
        )

        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/docker")
        #expect(cmd.arguments == ["exec", "myapp", "sh", "-c", "cd '/app' && git init"])
    }

    @Test("run propagates execute errors")
    func runError() async throws {
        let transport = FileTransport { _, _ in
            throw CLIError(exitCode: 128, stderr: "not a git repository")
        }

        await #expect(throws: CLIError.self) {
            try await transport.run(
                on: .local(path: "/tmp/project"),
                command: "git config --get remote.origin.url"
            )
        }
    }
}

@Suite("FileTransport readFile commands")
struct FileTransportReadFileTests {

    @Test("local readFile uses cat")
    func readLocal() async throws {
        let recorder = CommandRecorder(output: "file contents here")
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.readFile(endpoint: .local(path: "/tmp/file.txt"))

        #expect(result == "file contents here")
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/bin/cat")
        #expect(cmd.arguments == ["/tmp/file.txt"])
    }

    @Test("ssh readFile uses ssh cat")
    func readSSH() async throws {
        let recorder = CommandRecorder(output: "remote content")
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.readFile(
            endpoint: .ssh(user: "deploy", host: "server.example.test", port: nil, path: "/opt/file.txt")
        )

        #expect(result == "remote content")
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.arguments == connectionOptions + ["deploy@server.example.test", "cat '/opt/file.txt'"])
    }

    @Test("ssh readFile with port passes -p flag")
    func readSSHWithPort() async throws {
        let recorder = CommandRecorder(output: "data")
        let transport = FileTransport(execute: recorder.execute)

        _ = try await transport.readFile(
            endpoint: .ssh(user: nil, host: "box", port: 2222, path: "/file.txt")
        )

        let cmd = recorder.commands[0]
        #expect(cmd.arguments == connectionOptions + ["-p", "2222", "box", "cat '/file.txt'"])
    }

    @Test("docker readFile uses docker exec cat")
    func readDocker() async throws {
        let recorder = CommandRecorder(output: "container content")
        let transport = FileTransport(execute: recorder.execute)

        let result = try await transport.readFile(
            endpoint: .docker(container: "myapp", path: "/app/file.txt")
        )

        #expect(result == "container content")
        let cmd = recorder.commands[0]
        #expect(cmd.executable == "/usr/bin/docker")
        #expect(cmd.arguments == ["exec", "myapp", "cat", "/app/file.txt"])
    }

    @Test("readFile ssh with tilde uses $HOME")
    func readSSHTilde() async throws {
        let recorder = CommandRecorder(output: "tilde content")
        let transport = FileTransport(execute: recorder.execute)

        _ = try await transport.readFile(
            endpoint: .ssh(user: "alice", host: "server", port: nil, path: "~/project/file.txt")
        )

        let cmd = recorder.commands[0]
        #expect(cmd.arguments == connectionOptions + ["alice@server", "cat \"$HOME\"/'project/file.txt'"])
    }
}

@Suite("FileTransport ssh connection options")
struct FileTransportConnectionOptionsTests {

    private static let ssh = "/usr/bin/ssh"
    private static let scp = "/usr/bin/scp"
    private static let docker = "/usr/bin/docker"

    private struct Operation: Sendable {
        let name: String
        let executables: [String]
        let run: @Sendable (FileTransport) async throws -> Void
    }

    private static func operations(remote: EndpointURL, otherRemote: EndpointURL) -> [Operation] {
        let local = EndpointURL.local(path: "/tmp/file.txt")
        let container = EndpointURL.docker(container: "myapp", path: "/app/file.txt")
        return [
            Operation(name: "directoryExists", executables: [ssh]) { _ = try await $0.directoryExists(endpoint: remote) },
            Operation(name: "pathExists", executables: [ssh]) { _ = try await $0.pathExists(endpoint: remote) },
            Operation(name: "isSymlink", executables: [ssh]) { _ = try await $0.isSymlink(endpoint: remote) },
            Operation(name: "readLink", executables: [ssh]) { _ = try await $0.readLink(endpoint: remote) },
            Operation(name: "readFile", executables: [ssh]) { _ = try await $0.readFile(endpoint: remote) },
            Operation(name: "stat", executables: [ssh]) { _ = try await $0.stat(endpoint: remote) },
            Operation(name: "remove", executables: [ssh]) { try await $0.remove(endpoint: remote) },
            Operation(name: "run", executables: [ssh]) { _ = try await $0.run(on: remote, command: "git init") },
            Operation(name: "copy local to ssh", executables: [scp]) { try await $0.copy(from: local, to: remote) },
            Operation(name: "copy ssh to local", executables: [scp]) { try await $0.copy(from: remote, to: local) },
            Operation(name: "copy ssh to ssh", executables: [scp]) { try await $0.copy(from: remote, to: otherRemote) },
            Operation(name: "copy ssh to docker", executables: [scp, docker]) { try await $0.copy(from: remote, to: container) },
            Operation(name: "copy docker to ssh", executables: [docker, scp]) { try await $0.copy(from: container, to: remote) },
            // Checks placement before removing the set-aside original.
            Operation(name: "replace", executables: [scp] + Array(repeating: ssh, count: 7)) {
                _ = try await $0.replace(ReplacePlan(replacing: remote, withCopyOf: local))
            },
        ]
    }

    @Test("every ssh and scp command starts with the options that end it when the host does not answer", arguments: [
        EndpointURL.ssh(user: "deploy", host: "server", port: nil, path: "/opt/app/file.txt"),
        EndpointURL.ssh(user: nil, host: "box", port: 2222, path: "/data/file.txt"),
    ])
    func everyRemoteCommandStartsWithConnectionOptions(remote: EndpointURL) async throws {
        let otherRemote = EndpointURL.ssh(user: "backup", host: "mirror", port: nil, path: "/srv/file.txt")
        for operation in Self.operations(remote: remote, otherRemote: otherRemote) {
            let recorder = CommandRecorder(output: "1024 1700000000")
            let transport = FileTransport { executable, arguments in
                let output = try await recorder.execute(executable, arguments)
                if let command = arguments.last, command.hasPrefix("test "),
                   command.contains("/file.txt/.helix-incoming-") {
                    throw CLIError(exitCode: 1, stderr: "")
                }
                return output
            }

            try await operation.run(transport)

            #expect(recorder.commands.map(\.executable) == operation.executables, "\(operation.name)")
            for command in recorder.commands where command.executable != Self.docker {
                #expect(Array(command.arguments.prefix(8)) == [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=5",
                    "-o", "ServerAliveInterval=5",
                    "-o", "ServerAliveCountMax=3",
                ], "\(operation.name): \(command.executable) \(command.arguments)")
            }
        }
    }
}

// MARK: - Test Helpers

/// What every ssh and scp command line starts with.
private let connectionOptions = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=3",
]

struct RecordedCommand: Sendable {
    let executable: String
    let arguments: [String]
}

final class CommandRecorder: @unchecked Sendable {
    private var _commands: [RecordedCommand] = []
    private let lock = NSLock()
    private let output: String
    private let error: CLIError?

    init(output: String = "", error: CLIError? = nil) {
        self.output = output
        self.error = error
    }

    var commands: [RecordedCommand] {
        lock.lock()
        defer { lock.unlock() }
        return _commands
    }

    func execute(_ executable: String, _ arguments: [String]) async throws -> String {
        lock.lock()
        _commands.append(RecordedCommand(executable: executable, arguments: arguments))
        lock.unlock()
        if let error { throw error }
        return output
    }
}
