// ABOUTME: Codable model for mutagen sync sessions parsed from JSON.
// ABOUTME: Represents the full state of a synchronization session including endpoints, config, and conflicts.

import Foundation

public struct SyncSession: Codable, Identifiable, Hashable, Sendable {
    public var id: String { identifier }

    public let identifier: String
    public let version: Int
    public let creationTime: String
    public let creatingVersion: String
    public let name: String?
    public let labels: [String: String]?
    public let paused: Bool
    public let status: String
    public let successfulCycles: Int?
    public let mode: String?
    public let alpha: Endpoint
    public let beta: Endpoint
    public let ignore: IgnoreConfig
    public let symlink: SymlinkConfig
    public let watch: WatchConfig
    public let permissions: PermissionsConfig
    public let compression: CompressionConfig
    public var conflicts: [Conflict]?
    public var excludedConflicts: UInt64? = nil
    /// Why mutagen last failed to connect or synchronize; absent when it reports no error.
    public var lastError: String? = nil
}
