// ABOUTME: Builds every ssh and scp command line Helix runs, with the options that end one when its host stops answering.
// ABOUTME: The only place that names the ssh and scp executables, so no call can leave those options out.

import Foundation

/// An ssh or scp command line that cannot wait on a host for long: it never prompts, gives up connecting
/// after 5 seconds, and drops a connection that has been silent for 15.
public struct SSHCommand: Sendable, Equatable {
    public let executablePath: String
    public let arguments: [String]

    /// Option spellings are those of ssh_config(5); scp passes `-o` through to the ssh it starts.
    private static let connectionOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=3",
    ]

    private init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = Self.connectionOptions + arguments
    }

    /// Runs `command` in the remote user's shell.
    public static func remoteShell(user: String?, host: String, port: Int?, command: String) -> SSHCommand {
        var arguments: [String] = []
        if let port {
            arguments += ["-p", "\(port)"]
        }
        arguments += [login(user: user, host: host), command]
        return SSHCommand(executablePath: "/usr/bin/ssh", arguments: arguments)
    }

    /// Copies a file or a directory tree. Each of `source` and `destination` is a local path or `[user@]host:path`.
    /// - Parameter betweenRemoteHosts: both ends are remote, and the data passes through this machine.
    public static func recursiveCopy(from source: String, to destination: String, port: Int?, betweenRemoteHosts: Bool = false) -> SSHCommand {
        var arguments: [String] = []
        if betweenRemoteHosts {
            arguments.append("-3")
        }
        arguments.append("-r")
        if let port {
            arguments += ["-P", "\(port)"]
        }
        arguments += [source, destination]
        return SSHCommand(executablePath: "/usr/bin/scp", arguments: arguments)
    }

    /// The `[user@]host` that ssh and scp take.
    public static func login(user: String?, host: String) -> String {
        if let user {
            return "\(user)@\(host)"
        }
        return host
    }
}
