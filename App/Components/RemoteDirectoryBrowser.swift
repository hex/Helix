// ABOUTME: Sheet for browsing directories on a remote SSH host.
// ABOUTME: Uses ssh + ls to list entries, allowing navigation and path selection.

import SwiftUI
import HelixKit

struct RemoteDirectoryBrowser: View {
    let user: String?
    let host: String
    let port: Int?
    let initialPath: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var currentPath = ""
    @State private var entries: [DirectoryEntry] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            directoryList
            Divider()
            actionBar
        }
        .frame(width: 400, height: 350)
        .task {
            currentPath = initialPath
            await loadDirectory()
        }
    }

    // MARK: - Subviews

    private var pathBar: some View {
        HStack {
            TextField("Path", text: $currentPath)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await loadDirectory() } }
            Button("Go") { Task { await loadDirectory() } }
                .disabled(isLoading)
        }
        .padding()
    }

    private var directoryList: some View {
        List {
            if currentPath != "/" {
                Button("..") {
                    Task { await navigateUp() }
                }
            }
            ForEach(entries) { entry in
                Button {
                    if entry.isDirectory {
                        Task { await navigate(to: entry) }
                    }
                } label: {
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                        .foregroundStyle(entry.isDirectory ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if let error {
                Text(error)
                    .foregroundStyle(.secondary)
                    .padding()
            } else if entries.isEmpty {
                Text("Empty directory")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Select") {
                onSelect(currentPath)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Navigation

    private func navigate(to entry: DirectoryEntry) async {
        currentPath = currentPath.hasSuffix("/")
            ? currentPath + entry.name
            : currentPath + "/" + entry.name
        await loadDirectory()
    }

    private func navigateUp() async {
        // Drop trailing slash, then remove last path component
        var trimmed = currentPath
        if trimmed.hasSuffix("/") && trimmed != "/" {
            trimmed = String(trimmed.dropLast())
        }
        if let lastSlash = trimmed.lastIndex(of: "/") {
            currentPath = lastSlash == trimmed.startIndex
                ? "/"
                : String(trimmed[..<lastSlash])
        }
        await loadDirectory()
    }

    private func loadDirectory() async {
        isLoading = true
        error = nil
        entries = []
        defer { isLoading = false }

        // Resolve ~ to an absolute path via the remote shell
        if currentPath.hasPrefix("~") {
            do {
                let home = try await sshCommand("cd ~ && pwd").trimmingCharacters(in: .whitespacesAndNewlines)
                if currentPath == "~" {
                    currentPath = home
                } else {
                    // ~/foo → /home/user/foo
                    currentPath = home + String(currentPath.dropFirst())  // drop the ~
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
        }

        do {
            let output = try await sshCommand("ls -1pA \(shellEscape(currentPath)) 2>/dev/null")
            let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
            entries = lines.map { line in
                let name = String(line)
                if name.hasSuffix("/") {
                    return DirectoryEntry(name: String(name.dropLast()), isDirectory: true)
                } else {
                    return DirectoryEntry(name: name, isDirectory: false)
                }
            }
            .sorted { lhs, rhs in
                // Directories first, then alphabetical
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - SSH Helpers

    private func sshCommand(_ command: String) async throws -> String {
        let ssh = SSHCommand.remoteShell(user: user, host: host, port: port, command: command)
        return try await runProcess(executablePath: ssh.executablePath, arguments: ssh.arguments)
    }

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Supporting Types

struct DirectoryEntry: Identifiable {
    let name: String
    let isDirectory: Bool

    var id: String { name }
}
