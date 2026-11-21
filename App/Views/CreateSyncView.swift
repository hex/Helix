// ABOUTME: 4-step wizard for creating a new sync session.
// ABOUTME: Steps: Endpoints -> Mode -> Options -> Review with CLI command preview.

import SwiftUI
import HelixKit

struct CreateSyncView: View {
    let store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var maxStepReached = 0

    // Step 1: Endpoints
    @State private var sessionName = ""
    @State private var alphaTransport: TransportType = .local
    @State private var alphaPath = ""
    @State private var alphaHost = ""
    @State private var alphaUser = ""
    @State private var alphaPort = ""
    @State private var alphaContainer = ""
    @State private var betaTransport: TransportType = .ssh
    @State private var betaPath = ""
    @State private var betaHost = ""
    @State private var betaUser = ""
    @State private var betaPort = ""
    @State private var betaContainer = ""

    // Step 2: Mode
    @State private var syncMode = "two-way-safe"

    // Step 3: Options
    @State private var labels: [String: String] = [:]
    @State private var ignoreInput = ""
    @State private var ignoreVCS = false
    @State private var symlinkMode = "portable"
    @State private var compression = "none"
    @State private var watchMode = "portable"
    @State private var stageMode = "mutagen"
    @State private var createPaused = false

    // Step 4: Review
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
            Divider()

            Group {
                switch step {
                case 0: endpointsStep
                case 1: modeStep
                case 2: optionsStep
                default: reviewStep
                }
            }

            Divider()
            navigationButtons
        }
        .frame(width: 560, height: 520)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(Array(stepLabels.enumerated()), id: \.offset) { i, label in
                Button {
                    if i != step && i <= maxStepReached {
                        withAnimation { step = i }
                    }
                } label: {
                    VStack(spacing: 6) {
                        Text(label)
                            .font(.subheadline)
                            .fontWeight(step == i ? .semibold : .regular)
                            .foregroundStyle(step == i ? Color.primary : (i <= maxStepReached ? Color.secondary : Color(nsColor: .tertiaryLabelColor)))

                        Rectangle()
                            .fill(step == i ? Color.accentColor : .clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 0)
    }

    private var stepLabels: [String] {
        ["Endpoints", "Mode", "Options", "Review"]
    }

    // MARK: - Step 1: Endpoints

    private var endpointsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Session Name (optional)", text: $sessionName)
                        .textFieldStyle(.roundedBorder)
                    if let error = nameValidationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tag sessions for filtering and batch operations.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        LabelEditor(labels: $labels)
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text("Labels")
                        if !labels.isEmpty {
                            Text("\(labels.count)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                EndpointPicker(
                    label: "Alpha (Source)",
                    transport: $alphaTransport,
                    path: $alphaPath,
                    host: $alphaHost,
                    user: $alphaUser,
                    port: $alphaPort,
                    container: $alphaContainer
                )

                EndpointPicker(
                    label: "Beta (Destination)",
                    transport: $betaTransport,
                    path: $betaPath,
                    host: $betaHost,
                    user: $betaUser,
                    port: $betaPort,
                    container: $betaContainer
                )
            }
            .padding()
        }
    }

    // MARK: - Step 2: Mode

    private var modeStep: some View {
        ScrollView {
            SyncModePicker(selectedMode: $syncMode)
                .padding()
        }
    }

    // MARK: - Step 3: Options

    private var optionsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SyncOptionsForm(
                    ignoreInput: $ignoreInput,
                    ignoreVCS: $ignoreVCS,
                    symlinkMode: $symlinkMode,
                    compression: $compression,
                    watchMode: $watchMode,
                    stageMode: $stageMode
                )

                Toggle("Create session paused", isOn: $createPaused)
            }
            .padding()
        }
    }

    // MARK: - Step 4: Review

    private var reviewStep: some View {
        Form {
            Section("Summary") {
                if !sessionName.isEmpty {
                    LabeledContent("Name", value: sessionName)
                }
                LabeledContent("Alpha") {
                    Text(alphaEndpoint.formatted).monospaced()
                }
                LabeledContent("Beta") {
                    Text(betaEndpoint.formatted).monospaced()
                }
                LabeledContent("Mode", value: syncMode)
                if !labels.isEmpty {
                    LabeledContent("Labels") {
                        Text(labels.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                            .monospaced()
                    }
                }
                if !ignorePaths.isEmpty {
                    LabeledContent("Ignore") {
                        Text(ignorePaths.joined(separator: ", ")).monospaced()
                    }
                }
            }
            Section("CLI Command") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commandPreview, forType: .string)
                        }
                        .controlSize(.mini)
                    }

                    Text(commandPreview)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            if step > 0 {
                Button("Back") {
                    withAnimation { step -= 1 }
                }
            }

            if step < 3 {
                Button("Next") {
                    withAnimation {
                        step += 1
                        maxStepReached = max(maxStepReached, step)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
            } else {
                Button("Create") {
                    Task { await createSession() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating)
            }
        }
        .padding()
    }

    private var canAdvance: Bool {
        switch step {
        case 0:
            return alphaEndpointPicker.isValid && betaEndpointPicker.isValid
                && nameValidationError == nil
        default:
            return true
        }
    }

    private var nameValidationError: String? {
        SessionName.validate(sessionName, existingNames: store.syncSessionNames())?.message
    }

    // MARK: - Data Assembly

    private var alphaEndpointPicker: EndpointPicker {
        EndpointPicker(
            label: "Alpha",
            transport: .constant(alphaTransport),
            path: .constant(alphaPath),
            host: .constant(alphaHost),
            user: .constant(alphaUser),
            port: .constant(alphaPort),
            container: .constant(alphaContainer)
        )
    }

    private var betaEndpointPicker: EndpointPicker {
        EndpointPicker(
            label: "Beta",
            transport: .constant(betaTransport),
            path: .constant(betaPath),
            host: .constant(betaHost),
            user: .constant(betaUser),
            port: .constant(betaPort),
            container: .constant(betaContainer)
        )
    }

    private var alphaEndpoint: EndpointURL {
        alphaEndpointPicker.endpointURL
    }

    private var betaEndpoint: EndpointURL {
        betaEndpointPicker.endpointURL
    }

    private var ignorePaths: [String] {
        ignoreInput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var options: SyncCreateOptions {
        var opts = SyncCreateOptions()
        opts.name = sessionName.isEmpty ? nil : sessionName
        opts.labels = labels
        opts.mode = syncMode
        opts.paused = createPaused
        opts.ignorePaths = ignorePaths
        if ignoreVCS { opts.ignoreVCS = true }
        if symlinkMode != "portable" { opts.symlinkMode = symlinkMode }
        if compression != "none" { opts.compression = compression }
        if watchMode != "portable" { opts.watchMode = watchMode }
        if stageMode != "mutagen" { opts.stageMode = stageMode }
        return opts
    }

    private var commandPreview: String {
        options.commandPreview(alpha: alphaEndpoint.formatted, beta: betaEndpoint.formatted)
    }

    private func createSession() async {
        isCreating = true
        await store.createSync(
            options: options,
            alpha: alphaEndpoint.formatted,
            beta: betaEndpoint.formatted
        )
        isCreating = false
        if store.lastError == nil {
            dismiss()
        }
    }
}
