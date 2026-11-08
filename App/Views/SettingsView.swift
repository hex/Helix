// ABOUTME: Preferences window with launch-at-login, daemon control, updates, and version info.
// ABOUTME: Two tabs: General (app settings, daemon management, about) and Advanced (polling, CLI path).

import ServiceManagement
import Sparkle
import SwiftUI
import HelixKit

struct SettingsView: View {
    let store: SessionStore
    let updater: SPUUpdater
    @State private var pollingInterval: Double = 5.0
    @State private var launchAtLogin = false
    @AppStorage("cliPath") private var cliPath = HelixApp.defaultCLIPath
    @AppStorage(MenuBarIconStyle.storageKey) private var iconStyle = MenuBarIconStyle.defaultStyle

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            advancedTab
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
        }
        .frame(width: 450, height: 360)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .task {
            await store.fetchVersion()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Helix") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !enabled
                        }
                    }
            }

            Section("Menu Bar") {
                Picker("Icon style", selection: $iconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                LabeledContent("Preview") {
                    HStack(spacing: 8) {
                        ForEach(HealthStatus.allCases, id: \.self) { health in
                            MenuBarIconImage(style: iconStyle, health: health)
                                .help(health.title)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }

            Section("Daemon") {
                HStack {
                    Circle()
                        .fill(store.daemonRunning ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(store.daemonRunning ? "Running" : "Stopped")
                    Spacer()

                    if store.daemonRunning {
                        Button("Stop") {
                            Task { await store.stopDaemon() }
                        }
                        Button("Restart") {
                            Task {
                                await store.stopDaemon()
                                try? await Task.sleep(for: .seconds(1))
                                await store.startDaemon()
                            }
                        }
                    } else {
                        Button("Start") {
                            Task { await store.startDaemon() }
                        }
                    }
                }

            }

            if let error = store.lastError {
                Section("Status") {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section("About") {
                LabeledContent("Helix Version", value: "2026.2.0")
                LabeledContent("Mutagen CLI") {
                    if let version = store.mutagenVersion {
                        Text("v\(version)")
                    } else {
                        Text("Not detected")
                            .foregroundStyle(.secondary)
                    }
                }
                CheckForUpdatesButton(updater: updater)
                Link("helix.hexul.com", destination: URL(string: "https://helix.hexul.com")!)
                Text("\u{00A9} 2026 Hexul. All rights reserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Advanced Tab

    private var advancedTab: some View {
        Form {
            Section("Polling") {
                HStack {
                    Text("Refresh interval")
                    Spacer()
                    Text("\(Int(pollingInterval))s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $pollingInterval, in: 2...30, step: 1) {
                    Text("Interval")
                } minimumValueLabel: {
                    Text("2s").font(.caption2)
                } maximumValueLabel: {
                    Text("30s").font(.caption2)
                }
                .onChange(of: pollingInterval) { _, newValue in
                    store.startPolling(interval: newValue)
                }

                Text("How often the app checks mutagen for session updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("CLI Path") {
                HStack {
                    TextField("Path to mutagen", text: $cliPath)
                        .monospaced()
                        .font(.caption)

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        if panel.runModal() == .OK, let url = panel.url {
                            cliPath = url.path
                        }
                    }
                }
                .onChange(of: cliPath) { _, newPath in
                    store.replaceProvider(CLI(executablePath: newPath))
                }

                Text("Path to the mutagen binary. Changes take effect immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private extension HealthStatus {
    var title: String {
        switch self {
        case .healthy: "All sessions watching"
        case .active: "Syncing"
        case .partiallyPaused: "Some sessions paused"
        case .paused: "All sessions paused"
        case .warning: "Conflicts or a halted session"
        case .error: "A session lost its connection"
        case .daemonStopped: "Daemon not running"
        case .idle: "No sessions"
        }
    }
}
