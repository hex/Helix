// ABOUTME: Codable model for the staging progress mutagen reports on the endpoint receiving files,
// ABOUTME: and the transfer summary derived from it the way `mutagen sync list -l` computes it.

import Foundation

public struct StagingProgress: Codable, Hashable, Sendable {
    /// The file currently being received, relative to the sync root.
    public let path: String?
    public let receivedSize: Int?
    public let expectedSize: Int?
    public let receivedFiles: Int?
    public let expectedFiles: Int?
    public let totalReceivedSize: Int?
}

/// Progress of one staging pass. Mutagen omits zero-valued fields, so an absent count reads as zero.
public struct TransferProgress: Hashable, Sendable {
    public let receivedFiles: Int
    public let expectedFiles: Int
    public let receivedBytes: Int
    /// Known only when the staged files are the sending endpoint's whole tree.
    public let expectedBytes: Int?
    /// Received over expected, as files or bytes; nil when its denominator is absent or zero.
    public let fraction: Double?
    public let currentPath: String?
    public let currentReceivedBytes: Int
    public let currentExpectedBytes: Int?
}

extension SyncSession {
    /// Nil unless the session is staging and the receiving endpoint reports progress.
    public var transferProgress: TransferProgress? {
        guard let endpoints = stagingEndpoints,
              let progress = endpoints.receiving.stagingProgress else { return nil }

        let receivedFiles = progress.receivedFiles ?? 0
        let expectedFiles = progress.expectedFiles ?? 0
        let receivedBytes = progress.totalReceivedSize ?? 0

        let expectedBytes: Int?
        let fraction: Double?
        if expectedFiles == endpoints.sending.files ?? 0 {
            let sendingBytes = endpoints.sending.totalFileSize ?? 0
            expectedBytes = sendingBytes > 0 ? sendingBytes : nil
            fraction = expectedBytes.map { Double(receivedBytes) / Double($0) }
        } else {
            expectedBytes = nil
            fraction = expectedFiles > 0 ? Double(receivedFiles) / Double(expectedFiles) : nil
        }

        return TransferProgress(
            receivedFiles: receivedFiles,
            expectedFiles: expectedFiles,
            receivedBytes: receivedBytes,
            expectedBytes: expectedBytes,
            fraction: fraction,
            currentPath: progress.path,
            currentReceivedBytes: progress.receivedSize ?? 0,
            currentExpectedBytes: progress.expectedSize
        )
    }
}
