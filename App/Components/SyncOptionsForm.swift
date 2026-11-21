// ABOUTME: Form for sync session options (ignore, symlink, compression, watch, staging).
// ABOUTME: Extracted for reuse in both CreateSyncView and EditSyncConfigView.

import SwiftUI

struct SyncOptionsForm: View {
    @Binding var ignoreInput: String
    @Binding var ignoreVCS: Bool
    @Binding var symlinkMode: String
    @Binding var compression: String
    @Binding var watchMode: String
    @Binding var stageMode: String

    @State private var showIgnore = false
    @State private var showSymlink = false
    @State private var showCompression = false
    @State private var showWatch = false
    @State private var showStaging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisclosureGroup(isExpanded: $showIgnore) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("One pattern per line. Uses gitignore-style syntax.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(Self.presets, id: \.self) { preset in
                            IgnorePresetChip(
                                pattern: preset,
                                isActive: ignorePatterns.contains(preset),
                                toggle: { togglePreset(preset) }
                            )
                        }
                    }

                    TextEditor(text: $ignoreInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                    Toggle("Ignore version control metadata", isOn: $ignoreVCS)
                }
                .padding(.top, 4)
            } label: {
                tappableLabel("Ignore Rules") { showIgnore.toggle() }
            }

            DisclosureGroup(isExpanded: $showSymlink) {
                Picker("Mode", selection: $symlinkMode) {
                    Text("Portable (safe relative links)").tag("portable")
                    Text("Ignore (skip all symlinks)").tag("ignore")
                    Text("POSIX Raw (all links, POSIX only)").tag("posix-raw")
                }
                .padding(.top, 4)
            } label: {
                tappableLabel("Symlink Handling") { showSymlink.toggle() }
            }

            DisclosureGroup(isExpanded: $showCompression) {
                Picker("Algorithm", selection: $compression) {
                    Text("None").tag("none")
                    Text("Deflate (zlib)").tag("deflate")
                    Text("Zstandard (faster)").tag("zstandard")
                }
                .padding(.top, 4)
            } label: {
                tappableLabel("Compression") { showCompression.toggle() }
            }

            DisclosureGroup(isExpanded: $showWatch) {
                Picker("Mode", selection: $watchMode) {
                    Text("Portable (automatic)").tag("portable")
                    Text("Force Poll (unreliable FS)").tag("force-poll")
                    Text("No Watch (manual flush only)").tag("no-watch")
                }
                .padding(.top, 4)
            } label: {
                tappableLabel("Watch Mode") { showWatch.toggle() }
            }

            DisclosureGroup(isExpanded: $showStaging) {
                Picker("Mode", selection: $stageMode) {
                    Text("Mutagen (in ~/.mutagen)").tag("mutagen")
                    Text("Neighboring (beside sync root)").tag("neighboring")
                    Text("Internal (inside sync root)").tag("internal")
                }
                .padding(.top, 4)
            } label: {
                tappableLabel("Staging") { showStaging.toggle() }
            }
        }
    }

    static let presets = [
        "**/.git", "**/node_modules", "**/.venv", "**/__pycache__",
        ".DS_Store", "*.log",
        "**/.idea", "**/.vscode",
        "**/dist", "**/build", "**/target",
    ]

    private var ignorePatterns: Set<String> {
        Set(
            ignoreInput
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    private func togglePreset(_ pattern: String) {
        var patterns = ignoreInput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if let index = patterns.firstIndex(of: pattern) {
            patterns.remove(at: index)
        } else {
            patterns.append(pattern)
        }
        ignoreInput = patterns.joined(separator: "\n")
    }

    private func tappableLabel(_ title: String, action: @escaping () -> Void) -> some View {
        Text(title)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

private struct IgnorePresetChip: View {
    let pattern: String
    let isActive: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Text(pattern)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isActive ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
