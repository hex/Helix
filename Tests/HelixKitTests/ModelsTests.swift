// ABOUTME: Tests for Codable model parsing from real mutagen JSON output.
// ABOUTME: Validates SyncSession, Endpoint, Conflict, and Change decoding.

import Testing
import Foundation
@testable import HelixKit

@Suite("Sync session model parsing")
struct SyncSessionTests {

    let decoder = JSONDecoder()

    func loadFixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    @Test("Decodes real sync list JSON into array of SyncSession")
    func decodeSyncList() throws {
        let data = try loadFixture("sync-list.json")
        let sessions = try decoder.decode([SyncSession].self, from: data)

        #expect(sessions.count == 1)
    }

    @Test("Parses session identity fields")
    func sessionIdentity() throws {
        let data = try loadFixture("sync-list.json")
        let session = try decoder.decode([SyncSession].self, from: data).first!

        #expect(session.identifier.hasPrefix("sync_"))
        #expect(session.version == 1)
        #expect(session.creatingVersion == "0.18.1")
        #expect(session.name == "claude-sessions")
        #expect(session.id == session.identifier)
    }

    @Test("Parses session state fields")
    func sessionState() throws {
        let data = try loadFixture("sync-list.json")
        let session = try decoder.decode([SyncSession].self, from: data).first!

        #expect(session.paused == false)
        #expect(session.status == "watching")
        #expect(session.successfulCycles != nil)
        #expect(session.successfulCycles! > 0)
        #expect(session.mode == "two-way-safe")
    }

    @Test("Parses creation time as ISO 8601 string")
    func creationTime() throws {
        let data = try loadFixture("sync-list.json")
        let session = try decoder.decode([SyncSession].self, from: data).first!

        #expect(session.creationTime == "2026-02-04T14:41:09.472233Z")
    }

    @Test("Parses staging progress on the endpoint being staged")
    func stagingProgress() throws {
        let data = try loadFixture("sync-list-staging.json")
        let session = try decoder.decode([SyncSession].self, from: data).first!

        #expect(session.status == "staging-beta")
        #expect(session.alpha.stagingProgress == nil)
        #expect(session.beta.stagingProgress == StagingProgress(
            path: "project/data.bin",
            receivedSize: 2557935616,
            expectedSize: 15285403017,
            receivedFiles: 58796,
            expectedFiles: 159582,
            totalReceivedSize: 16435630359
        ))
    }

    @Test("Parses staging progress whose zero-valued fields mutagen omits")
    func stagingProgressOmittedFields() throws {
        let json = """
        [{"identifier":"sync_test","version":1,"creationTime":"2026-01-01T00:00:00Z",
          "creatingVersion":"0.18.1","alpha":{"protocol":"local","path":"/tmp/a",
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},
          "connected":true,"scanned":true,"directories":2,"files":9,"totalFileSize":8192},
          "beta":{"protocol":"local","path":"/tmp/b",
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},
          "connected":true,"scanned":true,
          "stagingProgress":{"path":"project/data.bin","expectedSize":2048,
            "receivedFiles":3,"expectedFiles":9,"totalReceivedSize":4096}},
          "mode":"two-way-safe","ignore":{},"symlink":{},"watch":{},
          "permissions":{},"compression":{},
          "paused":false,"status":"staging-beta"}]
        """
        let sessions = try decoder.decode([SyncSession].self, from: json.data(using: .utf8)!)
        #expect(sessions[0].beta.stagingProgress == StagingProgress(
            path: "project/data.bin",
            receivedSize: nil,
            expectedSize: 2048,
            receivedFiles: 3,
            expectedFiles: 9,
            totalReceivedSize: 4096
        ))
    }

    @Test("Parses the session's last error, which mutagen omits when there is none")
    func lastError() throws {
        let json = """
        [{"identifier":"sync_a","version":1,"creationTime":"2026-01-01T00:00:00Z",
          "creatingVersion":"0.18.1","alpha":{"protocol":"local","path":"/tmp/a",
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},"connected":true},
          "beta":{"protocol":"ssh","host":"example.com","path":"/tmp/b",
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},"connected":false},
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},
          "paused":false,"status":"connecting-beta",
          "lastError":"beta polling error: unable to send poll request: message transmission failed: write |1: broken pipe"},
         {"identifier":"sync_b","version":1,"creationTime":"2026-01-01T00:00:00Z",
          "creatingVersion":"0.18.1","alpha":{"protocol":"local","path":"/tmp/c",
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},"connected":true},
          "beta":{"protocol":"local","path":"/tmp/d",
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},"connected":true},
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},
          "paused":false,"status":"watching"}]
        """
        let sessions = try decoder.decode([SyncSession].self, from: json.data(using: .utf8)!)
        #expect(sessions[0].lastError == "beta polling error: unable to send poll request: message transmission failed: write |1: broken pipe")
        #expect(sessions[1].lastError == nil)
    }

    @Test("Parses alpha endpoint with SSH protocol")
    func alphaEndpoint() throws {
        let data = try loadFixture("sync-list.json")
        let session = try decoder.decode([SyncSession].self, from: data).first!

        #expect(session.alpha.protocol_ == "ssh")
        #expect(session.alpha.user == "hex")
        #expect(session.alpha.host == "hex-macbookair.local")
        #expect(session.alpha.path == "~/.claude-sessions")
        #expect(session.alpha.connected == true)
        #expect(session.alpha.scanned == true)
        #expect(session.alpha.directories! > 0)
        #expect(session.alpha.files! > 0)
        #expect(session.alpha.totalFileSize! > 0)
    }

    @Test("Parses beta endpoint with local protocol")
    func betaEndpoint() throws {
        let data = try loadFixture("sync-list.json")
        let session = try decoder.decode([SyncSession].self, from: data).first!

        #expect(session.beta.protocol_ == "local")
        #expect(session.beta.user == nil)
        #expect(session.beta.host == nil)
        #expect(session.beta.path == "/Users/alex.geana/.claude-sessions")
        #expect(session.beta.connected == true)
    }

    @Test("Parses ignore configuration")
    func ignoreConfig() throws {
        let data = try loadFixture("sync-list.json")
        let session = try decoder.decode([SyncSession].self, from: data).first!

        #expect(session.ignore.paths == ["**/.git", "**/.venv", "**/__pycache__", "*.log", ".DS_Store"])
    }

    @Test("Parses symlink configuration")
    func symlinkConfig() throws {
        let data = try loadFixture("sync-list.json")
        let session = try decoder.decode([SyncSession].self, from: data).first!

        #expect(session.symlink.mode == "ignore")
    }

    @Test("Parses conflicts array with all fields")
    func conflicts() throws {
        let data = try loadFixture("sync-list.json")
        let session = try decoder.decode([SyncSession].self, from: data).first!

        let conflicts = session.conflicts!
        #expect(conflicts.count == 5)

        let first = conflicts[0]
        #expect(first.root == "alimentara")
        #expect(first.alphaChanges.count == 1)
        #expect(first.betaChanges.count == 1)
    }

    @Test("Parses conflict changes with old/new entries")
    func conflictChanges() throws {
        let data = try loadFixture("sync-list.json")
        let session = try decoder.decode([SyncSession].self, from: data).first!

        let change = session.conflicts![0].alphaChanges[0]
        #expect(change.path == "alimentara")
        #expect(change.old?.kind == "directory")
        #expect(change.new == nil)

        let betaChange = session.conflicts![0].betaChanges[0]
        #expect(betaChange.path == "alimentara/logs/session.log")
        #expect(betaChange.old == nil)
        #expect(betaChange.new?.kind == "untracked")
    }

    @Test("SyncSession conforms to Identifiable using identifier")
    func identifiable() throws {
        let data = try loadFixture("sync-list.json")
        let session = try decoder.decode([SyncSession].self, from: data).first!

        #expect(session.id == session.identifier)
    }

    @Test("SyncSession conforms to Hashable")
    func hashable() throws {
        let data = try loadFixture("sync-list.json")
        let sessions = try decoder.decode([SyncSession].self, from: data)

        let set = Set(sessions)
        #expect(set.count == 1)
    }
}

@Suite("Forward session model parsing")
struct ForwardSessionTests {

    let decoder = JSONDecoder()

    func loadFixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    @Test("Decodes forward list JSON into array of ForwardSession")
    func decodeForwardList() throws {
        let data = try loadFixture("forward-list.json")
        let sessions = try decoder.decode([ForwardSession].self, from: data)

        #expect(sessions.count == 1)
        #expect(sessions[0].name == "api-tunnel")
    }

    @Test("Parses forward session identity fields")
    func forwardIdentity() throws {
        let data = try loadFixture("forward-list.json")
        let session = try decoder.decode([ForwardSession].self, from: data).first!

        #expect(session.identifier.hasPrefix("fwd_"))
        #expect(session.id == session.identifier)
        #expect(session.paused == false)
    }

    @Test("Parses forward endpoints")
    func forwardEndpoints() throws {
        let data = try loadFixture("forward-list.json")
        let session = try decoder.decode([ForwardSession].self, from: data).first!

        #expect(session.source.protocol_ == "local")
        #expect(session.source.connected == true)
        #expect(session.destination.protocol_ == "ssh")
        #expect(session.destination.user == "hex")
        #expect(session.destination.host == "hex-macbookair.local")
    }

    @Test("Decodes empty forward list")
    func emptyForwardList() throws {
        let data = try loadFixture("forward-list-empty.json")
        let sessions = try decoder.decode([ForwardSession].self, from: data)
        #expect(sessions.isEmpty)
    }

    @Test("ForwardSession conforms to Hashable")
    func forwardHashable() throws {
        let data = try loadFixture("forward-list.json")
        let sessions = try decoder.decode([ForwardSession].self, from: data)
        let set = Set(sessions)
        #expect(set.count == 1)
    }
}

@Suite("Endpoint URL reconstruction")
struct EndpointURLTests {

    @Test("Local endpoint reconstructs path-only URL")
    func localEndpoint() {
        let endpoint = Endpoint(
            protocol_: "local", user: nil, host: nil, port: nil,
            path: "/Users/alex/.claude-sessions",
            connected: true, scanned: true, directories: 10, files: 50, totalFileSize: 1000
        )
        let url = endpoint.endpointURL
        #expect(url.formatted == "/Users/alex/.claude-sessions")
    }

    @Test("SSH endpoint reconstructs user@host:path URL")
    func sshEndpoint() {
        let endpoint = Endpoint(
            protocol_: "ssh", user: "hex", host: "hex-macbookair.local", port: nil,
            path: "~/.claude-sessions",
            connected: true, scanned: true, directories: 10, files: 50, totalFileSize: 1000
        )
        let url = endpoint.endpointURL
        #expect(url.formatted == "hex@hex-macbookair.local:~/.claude-sessions")
    }

    @Test("SSH endpoint with port includes port in URL")
    func sshEndpointWithPort() {
        let endpoint = Endpoint(
            protocol_: "ssh", user: "deploy", host: "server.com", port: 2222,
            path: "/var/www",
            connected: true, scanned: true, directories: 5, files: 20, totalFileSize: 500
        )
        let url = endpoint.endpointURL
        #expect(url.formatted == "deploy@server.com:2222:/var/www")
    }

    @Test("SSH endpoint without user omits user@")
    func sshEndpointNoUser() {
        let endpoint = Endpoint(
            protocol_: "ssh", user: nil, host: "server.com", port: nil,
            path: "/data",
            connected: true, scanned: true, directories: 1, files: 1, totalFileSize: 100
        )
        let url = endpoint.endpointURL
        #expect(url.formatted == "server.com:/data")
    }

    @Test("Docker endpoint reconstructs docker:// URL")
    func dockerEndpoint() {
        let endpoint = Endpoint(
            protocol_: "docker", user: nil, host: "mycontainer", port: nil,
            path: "/app/src",
            connected: true, scanned: true, directories: 3, files: 15, totalFileSize: 200
        )
        let url = endpoint.endpointURL
        #expect(url.formatted == "docker://mycontainer/app/src")
    }
}

@Suite("Empty and edge-case JSON")
struct EdgeCaseTests {

    let decoder = JSONDecoder()

    @Test("Decodes empty session list")
    func emptyList() throws {
        let data = "[]".data(using: .utf8)!
        let sessions = try decoder.decode([SyncSession].self, from: data)
        #expect(sessions.isEmpty)
    }

    @Test("Decodes session without name")
    func sessionWithoutName() throws {
        let json = """
        [{"identifier":"sync_test","version":1,"creationTime":"2026-01-01T00:00:00Z",
          "creatingVersion":"0.18.1","alpha":{"protocol":"local","path":"/tmp/a",
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},
          "connected":true,"scanned":false,"directories":0,"files":0,"totalFileSize":0},
          "beta":{"protocol":"local","path":"/tmp/b",
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},
          "connected":true,"scanned":false,"directories":0,"files":0,"totalFileSize":0},
          "mode":"two-way-safe","ignore":{},"symlink":{},"watch":{},
          "permissions":{},"compression":{},
          "paused":false,"status":"connecting"}]
        """
        let sessions = try decoder.decode([SyncSession].self, from: json.data(using: .utf8)!)
        #expect(sessions[0].name == nil)
        #expect(sessions[0].successfulCycles == nil)
        #expect(sessions[0].conflicts == nil)
    }

    @Test("Decodes session with default mode omitted")
    func sessionWithDefaultMode() throws {
        let json = """
        [{"identifier":"sync_test","version":1,"creationTime":"2026-01-01T00:00:00Z",
          "creatingVersion":"0.18.1","alpha":{"protocol":"local","path":"/tmp/a",
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},
          "connected":true,"scanned":false,"directories":0,"files":0,"totalFileSize":0},
          "beta":{"protocol":"local","path":"/tmp/b",
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},
          "connected":true,"scanned":false,"directories":0,"files":0,"totalFileSize":0},
          "ignore":{},"symlink":{},"watch":{},
          "permissions":{},"compression":{},
          "paused":false,"status":"watching","successfulCycles":3}]
        """
        let sessions = try decoder.decode([SyncSession].self, from: json.data(using: .utf8)!)
        #expect(sessions[0].mode == nil)
    }

    @Test("Decodes session with empty ignore paths")
    func emptyIgnore() throws {
        let json = """
        [{"identifier":"sync_test","version":1,"creationTime":"2026-01-01T00:00:00Z",
          "creatingVersion":"0.18.1","alpha":{"protocol":"local","path":"/tmp/a",
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},
          "connected":true,"scanned":false,"directories":0,"files":0,"totalFileSize":0},
          "beta":{"protocol":"local","path":"/tmp/b",
          "ignore":{},"symlink":{},"watch":{},"permissions":{},"compression":{},
          "connected":true,"scanned":false,"directories":0,"files":0,"totalFileSize":0},
          "mode":"one-way-safe","ignore":{},"symlink":{},"watch":{},
          "permissions":{},"compression":{},
          "paused":true,"status":"halted"}]
        """
        let sessions = try decoder.decode([SyncSession].self, from: json.data(using: .utf8)!)
        #expect(sessions[0].ignore.paths == nil)
        #expect(sessions[0].symlink.mode == nil)
    }
}

@Suite("Transfer progress")
struct TransferProgressTests {

    @Test("Counts files when the staged set differs from the source tree")
    func fileCountFraction() {
        let session = makeSyncSession(
            id: "sync_1", name: "staging", status: "staging-beta",
            alpha: makeEndpoint(path: "/tmp/a", files: 10, totalFileSize: 1000),
            beta: makeEndpoint(path: "/tmp/b", stagingProgress: StagingProgress(
                path: "project/data.bin", receivedSize: 64, expectedSize: 256,
                receivedFiles: 1, expectedFiles: 4, totalReceivedSize: 500
            ))
        )

        #expect(session.transferProgress == TransferProgress(
            receivedFiles: 1, expectedFiles: 4,
            receivedBytes: 500, expectedBytes: nil, fraction: 0.25,
            currentPath: "project/data.bin", currentReceivedBytes: 64, currentExpectedBytes: 256
        ))
    }

    @Test("Counts bytes when the staged set is the whole source tree")
    func byteFraction() {
        let session = makeSyncSession(
            id: "sync_1", name: "staging", status: "staging-alpha",
            alpha: makeEndpoint(path: "/tmp/a", stagingProgress: StagingProgress(
                path: nil, receivedSize: nil, expectedSize: nil,
                receivedFiles: 1, expectedFiles: 4, totalReceivedSize: 750
            )),
            beta: makeEndpoint(path: "/tmp/b", files: 4, totalFileSize: 1000)
        )

        #expect(session.transferProgress == TransferProgress(
            receivedFiles: 1, expectedFiles: 4,
            receivedBytes: 750, expectedBytes: 1000, fraction: 0.75,
            currentPath: nil, currentReceivedBytes: 0, currentExpectedBytes: nil
        ))
    }

    @Test("Reports no progress outside a staging status")
    func noProgressWhileWatching() {
        let session = makeSyncSession(
            id: "sync_1", name: "idle", status: "watching",
            alpha: makeEndpoint(path: "/tmp/a", files: 4, totalFileSize: 1000),
            beta: makeEndpoint(path: "/tmp/b", stagingProgress: StagingProgress(
                path: "project/data.bin", receivedSize: 64, expectedSize: 256,
                receivedFiles: 1, expectedFiles: 4, totalReceivedSize: 500
            ))
        )

        #expect(session.transferProgress == nil)
    }
}
