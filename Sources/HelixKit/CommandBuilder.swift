// ABOUTME: Assembles CLI arguments from typed option structs for session creation.
// ABOUTME: Generates both argument arrays and human-readable command previews.

import Foundation

// MARK: - Endpoint URL

public enum EndpointURL {
    case local(path: String)
    case ssh(user: String?, host: String, port: Int?, path: String)
    case docker(container: String, path: String)

    public var formatted: String {
        switch self {
        case .local(let path):
            return path
        case .ssh(let user, let host, let port, let path):
            var url = ""
            if let user {
                url += "\(user)@"
            }
            url += host
            if let port {
                url += ":\(port)"
            }
            url += ":\(path)"
            return url
        case .docker(let container, let path):
            return "docker://\(container)\(path)"
        }
    }
}

// MARK: - Sync Create Options

public struct SyncCreateOptions {
    public var name: String?
    public var labels: [String: String] = [:]
    public var paused: Bool = false
    public var mode: String?
    public var symlinkMode: String?
    public var compression: String?
    public var hash: String?
    public var watchMode: String?
    public var watchPollingInterval: Int?
    public var permissionsMode: String?
    public var stageMode: String?
    public var ignorePaths: [String] = []
    public var ignoreVCS: Bool?
    public var maxEntryCount: UInt64?
    public var maxStagingFileSize: String?
    private var ignoreSyntax: String?
    private var probeMode: String?
    private var scanMode: String?
    private var permissions: PermissionsConfig?
    private var alphaConfiguration: SyncConfiguration?
    private var betaConfiguration: SyncConfiguration?

    public init() {}

    public init(from session: SyncSession) {
        self.init()
        name = session.name
        labels = session.labels ?? [:]
        mode = session.mode
        paused = session.paused
        ignorePaths = session.ignore.paths ?? []
        symlinkMode = session.symlink.mode
        watchMode = session.watch.mode
        watchPollingInterval = session.watch.pollingInterval
        permissionsMode = session.permissions.mode
        compression = session.compression.algorithm
        stageMode = session.stageMode
        ignoreVCS = session.ignore.vcs
        hash = session.hash
        maxEntryCount = session.maxEntryCount
        maxStagingFileSize = session.maxStagingFileSize.map { String($0) }
        ignoreSyntax = session.ignore.syntax
        probeMode = session.probeMode
        scanMode = session.scanMode
        permissions = session.permissions
        preserveEndpointOverrides(from: session)
    }

    mutating func preserveEndpointOverrides(from session: SyncSession) {
        alphaConfiguration = session.alpha.configuration
        betaConfiguration = session.beta.configuration
    }

    var unsupportedEndpointOverrides: [String] {
        let alpha = alphaConfiguration?.settingsWithoutEndpointFlags ?? []
        let beta = betaConfiguration?.settingsWithoutEndpointFlags ?? []
        return alpha.map { "Alpha " + $0 } + beta.map { "Beta " + $0 }
    }

    public func arguments(alpha: String, beta: String) -> [String] {
        var args = ["sync", "create", alpha, beta]

        if let name { args += ["--name", name] }
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            args += ["--label", "\(key)=\(value)"]
        }
        if paused { args += ["--paused"] }
        if let mode { args += ["--mode", mode] }
        if let symlinkMode { args += ["--symlink-mode", symlinkMode] }
        if let compression { args += ["--compression", compression] }
        if let hash { args += ["--hash", hash] }
        if let watchMode { args += ["--watch-mode", watchMode] }
        if let interval = watchPollingInterval { args += ["--watch-polling-interval", String(interval)] }
        if let permissionsMode { args += ["--permissions-mode", permissionsMode] }
        if let stageMode { args += ["--stage-mode", stageMode] }
        for path in ignorePaths {
            args += ["--ignore", path]
        }
        if let ignoreVCS {
            args.append(ignoreVCS ? "--ignore-vcs" : "--no-ignore-vcs")
        }
        if let maxEntryCount { args += ["--max-entry-count", String(maxEntryCount)] }
        if let maxStagingFileSize { args += ["--max-staging-file-size", maxStagingFileSize] }
        if let ignoreSyntax { args += ["--ignore-syntax", ignoreSyntax] }
        if let probeMode { args += ["--probe-mode", probeMode] }
        if let scanMode { args += ["--scan-mode", scanMode] }
        args += Self.permissionArguments(permissions)
        if let alphaConfiguration { args += Self.endpointArguments(alphaConfiguration, suffix: "-alpha") }
        if let betaConfiguration { args += Self.endpointArguments(betaConfiguration, suffix: "-beta") }

        return args
    }

    private static func endpointArguments(_ configuration: SyncConfiguration, suffix: String) -> [String] {
        var args: [String] = []
        if let value = configuration.probeMode { args += ["--probe-mode\(suffix)", value] }
        if let value = configuration.scanMode { args += ["--scan-mode\(suffix)", value] }
        if let value = configuration.stageMode { args += ["--stage-mode\(suffix)", value] }
        if let value = configuration.watch?.mode { args += ["--watch-mode\(suffix)", value] }
        if let value = configuration.watch?.pollingInterval { args += ["--watch-polling-interval\(suffix)", String(value)] }
        args += permissionArguments(configuration.permissions, suffix: suffix)
        if let value = configuration.compression?.algorithm { args += ["--compression\(suffix)", value] }
        return args
    }

    private static func permissionArguments(_ permissions: PermissionsConfig?, suffix: String = "") -> [String] {
        var args: [String] = []
        if let value = permissions?.defaultFileMode { args += ["--default-file-mode\(suffix)", value] }
        if let value = permissions?.defaultDirectoryMode { args += ["--default-directory-mode\(suffix)", value] }
        if let value = permissions?.defaultOwner { args += ["--default-owner\(suffix)", value] }
        if let value = permissions?.defaultGroup { args += ["--default-group\(suffix)", value] }
        return args
    }

    public func commandPreview(alpha: String, beta: String) -> String {
        let args = arguments(alpha: alpha, beta: beta)
        var parts = ["mutagen"]
        for arg in args {
            if arg.contains(" ") || arg.contains("*") {
                parts.append("\"\(arg)\"")
            } else if arg.starts(with: "--") {
                parts.append(arg)
            } else if parts.last?.starts(with: "--") == true {
                parts.append("\"\(arg)\"")
            } else {
                parts.append(arg)
            }
        }
        return parts.joined(separator: " \\\n  ")
    }
}

private extension SyncConfiguration {
    var settingsWithoutEndpointFlags: [String] {
        var settings: [String] = []
        if mode != nil { settings.append("mode") }
        if hash != nil { settings.append("hash") }
        if maxEntryCount != nil { settings.append("max-entry-count") }
        if maxStagingFileSize != nil { settings.append("max-staging-file-size") }
        if ignore?.paths?.isEmpty == false { settings.append("ignore") }
        if ignore?.syntax != nil { settings.append("ignore-syntax") }
        if ignore?.vcs != nil { settings.append("ignore-vcs") }
        if symlink?.mode != nil { settings.append("symlink-mode") }
        if permissions?.mode != nil { settings.append("permissions-mode") }
        return settings
    }
}

// MARK: - Forward Create Options

public struct ForwardCreateOptions {
    public var name: String?
    public var labels: [String: String] = [:]
    public var paused: Bool = false
    public var socketOverwriteMode: String?

    public init() {}

    public func arguments(source: String, destination: String) -> [String] {
        var args = ["forward", "create", source, destination]

        if let name { args += ["--name", name] }
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            args += ["--label", "\(key)=\(value)"]
        }
        if paused { args += ["--paused"] }
        if let socketOverwriteMode { args += ["--socket-overwrite-mode", socketOverwriteMode] }

        return args
    }

    public func commandPreview(source: String, destination: String) -> String {
        let args = arguments(source: source, destination: destination)
        var parts = ["mutagen"]
        for arg in args {
            if arg.starts(with: "--") {
                parts.append(arg)
            } else if parts.last?.starts(with: "--") == true {
                parts.append("\"\(arg)\"")
            } else {
                parts.append(arg)
            }
        }
        return parts.joined(separator: " \\\n  ")
    }
}
