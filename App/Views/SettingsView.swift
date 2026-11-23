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
    @AppStorage(MenuBarIcon.showsPauseKey) private var showsPause = true
    @AppStorage(MenuBarPopover.compactListKey) private var compactList = false

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
                Toggle(isOn: $showsPause) {
                    Text("Show paused state")
                    Text("When off, paused sessions look like everything is running normally.")
                }
                LabeledContent("Preview") {
                    HStack(spacing: 8) {
                        ForEach(HealthStatus.allCases.filter { showsPause || $0.ignoringPause == $0 }, id: \.self) { health in
                            MenuBarIconImage(style: iconStyle, health: health)
                                .help(health.title)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Toggle(isOn: $compactList) {
                    Text("Compact session list")
                    Text("Show only session names in the menu bar popover.")
                }
            }

            Section("Daemon") {
                HStack {
                    Circle()
                        .fill(store.daemonStatus.indicatorColor)
                        .frame(width: 8, height: 8)
                    Text(store.daemonStatus.rawValue)
                    Spacer()

                    if store.daemonStatus == .running {
                        Button("Stop") {
                            Task { await store.stopDaemon() }
                        }
                        Button("Restart") {
                            Task {
                                guard await store.stopDaemon() else { return }
                                try? await Task.sleep(for: .seconds(1))
                                await store.startDaemon()
                            }
                        }
                    } else if store.daemonStatus != .startedOutside {
                        Button("Start") {
                            Task {
                                await store.startDaemon()
                                if store.daemonRunning { await store.fetchVersion() }
                            }
                        }
                    }
                }

                if store.daemonStatus == .startedOutside {
                    ExternalDaemonActions(store: store)
                }

                if let progress = store.daemonStopProgress {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(progress)
                    }
                }

                Text("After Stop, Helix does not start Mutagen until you choose Start. Login items and other tools can still start Mutagen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Run sync at background priority", isOn: Binding(
                    get: {
                        store.isMutagenStoppedByHelix ? store.daemonBackgroundPriorityRequested : store.daemonBackgroundPriority
                    },
                    set: { enabled in Task { await store.setDaemonBackgroundPriority(enabled) } }
                ))

                if store.isMutagenStoppedByHelix {
                    if store.daemonBackgroundPriorityRequested {
                        Text("Background priority applies when Mutagen starts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = store.daemonPriorityError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    if store.daemonBackgroundPriorityRequested {
                        Button("Cancel Background Priority Request") {
                            Task { await store.setDaemonBackgroundPriority(false) }
                        }
                    }
                }

                Text("Mutagen yields CPU and disk to whatever you are doing. Transfers slow down while the Mac is busy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    store.replaceDaemonProcess(MutagenDaemon(cliPath: newPath))
                }

                Text("Path to the mutagen binary. Changes take effect immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ExternalDaemonActions: View {
    let store: SessionStore

    var body: some View {
        HStack {
            Button("Manage Sessions") { Task { await store.manageExternalDaemon() } }
            Button("Stop Again") { Task { await store.stopDaemon() } }
        }
        .buttonStyle(.borderless)
    }
}

extension DaemonStatus {
    var indicatorColor: Color {
        switch self {
        case .running: .green
        case .stopped: .red
        case .startedOutside: .secondary
        case .unknown: .orange
        }
    }
}

private extension HealthStatus {
    var title: String {
        switch self {
        case .healthy: "All sessions watching"
        case .active: "Syncing or connecting"
        case .partiallyPaused: "Some sessions paused"
        case .paused: "All sessions paused"
        case .warning: "Conflicts, sync problems or a session that cannot connect"
        case .error: "A session lost its connection"
        case .daemonStopped: "Daemon not running"
        case .idle: "No sessions"
        }
    }
}
