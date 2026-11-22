// ABOUTME: Tests for CommandBuilder that assembles CLI arguments from creation options.
// ABOUTME: Validates argument generation for sync and forward session creation.

import Testing
import Foundation
@testable import HelixKit

@Suite("Sync create command building")
struct SyncCommandBuilderTests {

    @Test("Minimal sync create with just endpoints")
    func minimalCreate() {
        let options = SyncCreateOptions()
        let args = options.arguments(alpha: "/tmp/a", beta: "/tmp/b")

        #expect(args == ["sync", "create", "/tmp/a", "/tmp/b"])
    }

    @Test("Sync create with name and labels")
    func nameAndLabels() {
        var options = SyncCreateOptions()
        options.name = "my-session"
        options.labels = ["env": "dev", "project": "test"]
        let args = options.arguments(alpha: "/tmp/a", beta: "/tmp/b")

        #expect(args.contains("--name"))
        #expect(args.contains("my-session"))
        #expect(args.contains("--label"))
        // Labels can be in either order
        #expect(args.contains("env=dev") || args.contains("project=test"))
    }

    @Test("Sync create with mode")
    func syncMode() {
        var options = SyncCreateOptions()
        options.mode = "one-way-safe"
        let args = options.arguments(alpha: "/tmp/a", beta: "/tmp/b")

        #expect(args.contains("--mode"))
        #expect(args.contains("one-way-safe"))
    }

    @Test("Sync create with ignore rules")
    func ignoreRules() {
        var options = SyncCreateOptions()
        options.ignorePaths = ["**/.git", "node_modules"]
        options.ignoreVCS = true
        let args = options.arguments(alpha: "/tmp/a", beta: "/tmp/b")

        let ignoreIndices = args.enumerated().filter { $0.element == "--ignore" }.map(\.offset)
        #expect(ignoreIndices.count == 2)
        #expect(args.contains("--ignore-vcs"))
    }

    @Test("Sync create paused")
    func paused() {
        var options = SyncCreateOptions()
        options.paused = true
        let args = options.arguments(alpha: "/tmp/a", beta: "/tmp/b")

        #expect(args.contains("--paused"))
    }

    @Test("SSH endpoint URL formatting")
    func sshEndpointURL() {
        let url = EndpointURL.ssh(user: "alice", host: "example.com", port: nil, path: "~/project")
        #expect(url.formatted == "alice@example.com:~/project")
    }

    @Test("SSH endpoint URL with port")
    func sshEndpointURLWithPort() {
        let url = EndpointURL.ssh(user: "alice", host: "example.com", port: 2222, path: "~/project")
        #expect(url.formatted == "alice@example.com:2222:~/project")
    }

    @Test("SSH endpoint URL without user")
    func sshEndpointURLNoUser() {
        let url = EndpointURL.ssh(user: nil, host: "example.com", port: nil, path: "~/project")
        #expect(url.formatted == "example.com:~/project")
    }

    @Test("Docker endpoint URL formatting")
    func dockerEndpointURL() {
        let url = EndpointURL.docker(container: "mycontainer", path: "/app/src")
        #expect(url.formatted == "docker://mycontainer/app/src")
    }

    @Test("Local endpoint URL is just the path")
    func localEndpointURL() {
        let url = EndpointURL.local(path: "/Users/alex/project")
        #expect(url.formatted == "/Users/alex/project")
    }

    @Test("Command preview string")
    func commandPreview() {
        var options = SyncCreateOptions()
        options.name = "test"
        options.mode = "two-way-safe"
        let preview = options.commandPreview(alpha: "/tmp/a", beta: "/tmp/b")

        #expect(preview.contains("mutagen"))
        #expect(preview.contains("sync"))
        #expect(preview.contains("create"))
        #expect(preview.contains("--name"))
        #expect(preview.contains("test"))
        #expect(preview.contains("/tmp/a"))
        #expect(preview.contains("/tmp/b"))
    }

    @Test("Full options produce all expected flags")
    func fullOptions() {
        var options = SyncCreateOptions()
        options.name = "full-test"
        options.mode = "one-way-replica"
        options.symlinkMode = "ignore"
        options.compression = "zstandard"
        options.ignorePaths = [".git"]
        options.paused = true

        let args = options.arguments(alpha: "/tmp/a", beta: "/tmp/b")

        #expect(args.contains("--name"))
        #expect(args.contains("--mode"))
        #expect(args.contains("--symlink-mode"))
        #expect(args.contains("--compression"))
        #expect(args.contains("--ignore"))
        #expect(args.contains("--paused"))
    }
}

@Suite("SyncCreateOptions from SyncSession")
struct SyncCreateOptionsFromSessionTests {

    @Test("Preserves session name")
    func preservesName() {
        let session = makeSyncSession(id: "sync_1", name: "my-session")
        let options = SyncCreateOptions(from: session)
        #expect(options.name == "my-session")
    }

    @Test("Preserves nil name")
    func preservesNilName() {
        let session = makeSyncSession(id: "sync_1", name: nil)
        let options = SyncCreateOptions(from: session)
        #expect(options.name == nil)
    }

    @Test("Preserves sync mode")
    func preservesMode() {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let options = SyncCreateOptions(from: session)
        #expect(options.mode == "two-way-safe")
    }

    @Test("Preserves paused state")
    func preservesPaused() {
        let session = makeSyncSession(id: "sync_1", name: "test", paused: true)
        let options = SyncCreateOptions(from: session)
        #expect(options.paused == true)
    }

    @Test("Preserves ignore paths")
    func preservesIgnorePaths() {
        var session = makeSyncSession(id: "sync_1", name: "test")
        session = SyncSession(
            identifier: session.identifier, version: session.version,
            creationTime: session.creationTime, creatingVersion: session.creatingVersion,
            name: session.name, labels: session.labels, paused: session.paused, status: session.status,
            successfulCycles: session.successfulCycles, mode: session.mode,
            alpha: session.alpha, beta: session.beta,
            ignore: IgnoreConfig(paths: ["**/.git", "node_modules"], syntax: nil),
            symlink: session.symlink, watch: session.watch,
            permissions: session.permissions, compression: session.compression,
            conflicts: session.conflicts
        )
        let options = SyncCreateOptions(from: session)
        #expect(options.ignorePaths == ["**/.git", "node_modules"])
    }

    @Test("Preserves nil ignore paths as empty array")
    func nilIgnorePaths() {
        let session = makeSyncSession(id: "sync_1", name: "test")
        let options = SyncCreateOptions(from: session)
        #expect(options.ignorePaths.isEmpty)
    }

    @Test("Preserves symlink mode")
    func preservesSymlinkMode() {
        let session = SyncSession(
            identifier: "sync_1", version: 1,
            creationTime: "2026-01-01T00:00:00Z", creatingVersion: "0.18.1",
            name: "test", labels: nil, paused: false, status: "watching", successfulCycles: 0,
            mode: "two-way-safe",
            alpha: Endpoint(protocol_: "local", user: nil, host: nil, port: nil, path: "/tmp/a",
                            connected: true, scanned: true, directories: 0, files: 0, totalFileSize: 0),
            beta: Endpoint(protocol_: "local", user: nil, host: nil, port: nil, path: "/tmp/b",
                           connected: true, scanned: true, directories: 0, files: 0, totalFileSize: 0),
            ignore: IgnoreConfig(paths: nil, syntax: nil),
            symlink: SymlinkConfig(mode: "ignore"),
            watch: WatchConfig(mode: "force-poll", pollingInterval: 10),
            permissions: PermissionsConfig(mode: nil, defaultFileMode: nil, defaultDirectoryMode: nil, defaultOwner: nil, defaultGroup: nil),
            compression: CompressionConfig(algorithm: "zstandard"),
            conflicts: nil
        )
        let options = SyncCreateOptions(from: session)
        #expect(options.symlinkMode == "ignore")
        #expect(options.watchMode == "force-poll")
        #expect(options.watchPollingInterval == 10)
        #expect(options.compression == "zstandard")
    }

    @Test("Round-trips through arguments correctly")
    func roundTrips() {
        let session = SyncSession(
            identifier: "sync_1", version: 1,
            creationTime: "2026-01-01T00:00:00Z", creatingVersion: "0.18.1",
            name: "roundtrip", labels: nil, paused: false, status: "watching", successfulCycles: 5,
            mode: "one-way-safe",
            alpha: Endpoint(protocol_: "ssh", user: "alice", host: "server.example.test", port: nil, path: "~/proj",
                            connected: true, scanned: true, directories: 10, files: 50, totalFileSize: 1000),
            beta: Endpoint(protocol_: "local", user: nil, host: nil, port: nil, path: "/tmp/b",
                           connected: true, scanned: true, directories: 10, files: 50, totalFileSize: 1000),
            ignore: IgnoreConfig(paths: ["**/.git"], syntax: nil),
            symlink: SymlinkConfig(mode: "ignore"),
            watch: WatchConfig(mode: nil, pollingInterval: nil),
            permissions: PermissionsConfig(mode: nil, defaultFileMode: nil, defaultDirectoryMode: nil, defaultOwner: nil, defaultGroup: nil),
            compression: CompressionConfig(algorithm: nil),
            conflicts: nil
        )
        let options = SyncCreateOptions(from: session)
        let args = options.arguments(
            alpha: session.alpha.endpointURL.formatted,
            beta: session.beta.endpointURL.formatted
        )
        #expect(args.contains("--name"))
        #expect(args.contains("roundtrip"))
        #expect(args.contains("--mode"))
        #expect(args.contains("one-way-safe"))
        #expect(args.contains("--symlink-mode"))
        #expect(args.contains("ignore"))
        #expect(args.contains("--ignore"))
        #expect(args.contains("**/.git"))
        #expect(args.contains("alice@server.example.test:~/proj"))
        #expect(args.contains("/tmp/b"))
    }
}

@Suite("Forward create command building")
struct ForwardCommandBuilderTests {

    @Test("Minimal forward create")
    func minimalForwardCreate() {
        let options = ForwardCreateOptions()
        let args = options.arguments(source: "tcp:localhost:8080", destination: "tcp:localhost:3000")

        #expect(args == ["forward", "create", "tcp:localhost:8080", "tcp:localhost:3000"])
    }

    @Test("Forward create with name")
    func forwardWithName() {
        var options = ForwardCreateOptions()
        options.name = "api-tunnel"
        let args = options.arguments(source: "tcp::8080", destination: "user@host:tcp::3000")

        #expect(args.contains("--name"))
        #expect(args.contains("api-tunnel"))
    }
}
