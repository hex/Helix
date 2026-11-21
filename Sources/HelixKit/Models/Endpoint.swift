// ABOUTME: Codable model for a mutagen session endpoint (alpha/beta or source/destination).
// ABOUTME: Represents local, SSH, or Docker endpoints with connection state and file statistics.

import Foundation

public struct Endpoint: Codable, Hashable, Sendable {
    public let protocol_: String
    public let user: String?
    public let host: String?
    public let port: Int?
    public let path: String?
    public let connected: Bool?
    public let scanned: Bool?
    public let directories: Int?
    public let files: Int?
    public let totalFileSize: Int?
    public var stagingProgress: StagingProgress? = nil

    enum CodingKeys: String, CodingKey {
        case protocol_ = "protocol"
        case user, host, port, path
        case connected, scanned, directories, files, totalFileSize, stagingProgress
    }

    public var shortLabel: String {
        switch protocol_ {
        case "ssh":
            let target = [user, host].compactMap { $0 }.joined(separator: "@")
            return target.isEmpty ? "ssh" : target
        case "docker":
            return host ?? "docker"
        default:
            let hostName = ProcessInfo.processInfo.hostName
                .replacingOccurrences(of: ".local", with: "")
            if let path, let last = path.split(separator: "/").last {
                return "\(hostName):\(last)"
            }
            return hostName
        }
    }

    public var endpointURL: EndpointURL {
        let path = self.path ?? ""
        switch protocol_ {
        case "ssh":
            return .ssh(user: user, host: host ?? "", port: port, path: path)
        case "docker":
            return .docker(container: host ?? "", path: path)
        default:
            return .local(path: path)
        }
    }
}
