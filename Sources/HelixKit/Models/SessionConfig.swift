// ABOUTME: Codable models for mutagen session configuration sections.
// ABOUTME: Covers ignore rules, symlinks, watching, permissions, and compression settings.

import Foundation

public struct SyncConfiguration: Hashable, Sendable {
    public var mode: String? = nil
    public var hash: String? = nil
    public var maxEntryCount: UInt64? = nil
    public var maxStagingFileSize: UInt64? = nil
    public var probeMode: String? = nil
    public var scanMode: String? = nil
    public var stageMode: String? = nil
    public var ignore: IgnoreConfig? = nil
    public var symlink: SymlinkConfig? = nil
    public var watch: WatchConfig? = nil
    public var permissions: PermissionsConfig? = nil
    public var compression: CompressionConfig? = nil

    public static func defaults(forVersion version: Int) -> Self {
        guard version == 1 else { return Self() }
        return Self(
            mode: "two-way-safe",
            hash: "sha1",
            maxEntryCount: UInt64.max,
            maxStagingFileSize: UInt64.max,
            probeMode: "probe",
            scanMode: "accelerated",
            stageMode: "mutagen",
            ignore: IgnoreConfig(paths: nil, syntax: "mutagen", vcs: false),
            symlink: SymlinkConfig(mode: "portable"),
            watch: WatchConfig(mode: "portable", pollingInterval: 10),
            permissions: PermissionsConfig(
                mode: "portable", defaultFileMode: "0600", defaultDirectoryMode: "0700",
                defaultOwner: nil, defaultGroup: nil
            ),
            compression: CompressionConfig(algorithm: "deflate")
        )
    }
}

public struct IgnoreConfig: Codable, Hashable, Sendable {
    public let paths: [String]?
    public let syntax: String?
    public var vcs: Bool? = nil
}

public struct SymlinkConfig: Codable, Hashable, Sendable {
    public let mode: String?
}

public struct WatchConfig: Codable, Hashable, Sendable {
    public let mode: String?
    public let pollingInterval: Int?
}

public struct PermissionsConfig: Codable, Hashable, Sendable {
    public let mode: String?
    public let defaultFileMode: String?
    public let defaultDirectoryMode: String?
    public let defaultOwner: String?
    public let defaultGroup: String?
}

public struct CompressionConfig: Codable, Hashable, Sendable {
    public let algorithm: String?
}
