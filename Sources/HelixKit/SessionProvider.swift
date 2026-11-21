// ABOUTME: Protocol abstracting mutagen CLI access for testability.
// ABOUTME: SessionStore depends on this rather than CLI directly.

import Foundation

public protocol SessionProvider: Sendable {
    // Read operations
    func syncList() async throws -> [SyncSession]
    func forwardList() async throws -> [ForwardSession]
    func daemonRunning() async throws -> Bool
    func version() async throws -> String

    // Session creation
    func syncCreate(arguments: [String]) async throws -> String
    func forwardCreate(arguments: [String]) async throws

    // Sync actions
    func syncPause(_ identifier: String) async throws
    func syncResume(_ identifier: String) async throws
    func syncFlush(_ identifier: String) async throws
    func syncReset(_ identifier: String) async throws
    func syncTerminate(_ identifier: String) async throws

    // Forward actions
    func forwardPause(_ identifier: String) async throws
    func forwardResume(_ identifier: String) async throws
    func forwardTerminate(_ identifier: String) async throws

    // Daemon
    func daemonStart() async throws
    func daemonStop() async throws
    func daemonRegister() async throws
    func daemonUnregister() async throws
}

extension CLI: SessionProvider {}
