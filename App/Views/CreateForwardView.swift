// ABOUTME: Single-step form for creating a new network forwarding session.
// ABOUTME: Configures source/destination endpoints with protocol and address fields.

import SwiftUI
import HelixKit

struct CreateForwardView: View {
    let store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var sessionName = ""

    // Source endpoint
    @State private var sourceTransport: TransportType = .local
    @State private var sourceAddress = "tcp:localhost:"
    @State private var sourceHost = ""
    @State private var sourceUser = ""
    @State private var sourcePort = ""

    // Destination endpoint
    @State private var destTransport: TransportType = .ssh
    @State private var destAddress = "tcp:localhost:"
    @State private var destHost = ""
    @State private var destUser = ""
    @State private var destPort = ""

    @State private var labels: [String: String] = [:]
    @State private var createPaused = false
    @State private var isCreating = false
    @State private var creationError: String?
    @State private var labelsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Create Forward Session")
                        .font(.title2)
                        .fontWeight(.semibold)

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Session Name (optional)", text: $sessionName)
                            .textFieldStyle(.roundedBorder)
                        if let error = nameValidationError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    DisclosureGroup(isExpanded: $labelsExpanded) {
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
                        .contentShape(Rectangle())
                        .onTapGesture { labelsExpanded.toggle() }
                    }

                    sourceSection
                    destinationSection

                    Toggle("Create paused", isOn: $createPaused)

                    Divider()

                    commandPreviewSection
                }
                .padding()
            }

            Divider()
            actionButtons
        }
        .frame(width: 480, height: 520)
    }

    // MARK: - Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source")
                .font(.headline)

            Picker("Transport", selection: $sourceTransport) {
                Text("Local").tag(TransportType.local)
                Text("SSH").tag(TransportType.ssh)
            }
            .pickerStyle(.segmented)

            if sourceTransport == .ssh {
                HStack(spacing: 8) {
                    TextField("User", text: $sourceUser)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                    TextField("Host", text: $sourceHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("Port", text: $sourcePort)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 60)
                }
            }

            TextField("Address (e.g. tcp:localhost:8080)", text: $sourceAddress)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    // MARK: - Destination

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destination")
                .font(.headline)

            Picker("Transport", selection: $destTransport) {
                Text("Local").tag(TransportType.local)
                Text("SSH").tag(TransportType.ssh)
            }
            .pickerStyle(.segmented)

            if destTransport == .ssh {
                HStack(spacing: 8) {
                    TextField("User", text: $destUser)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                    TextField("Host", text: $destHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("Port", text: $destPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 60)
                }
            }

            TextField("Address (e.g. tcp:localhost:3000)", text: $destAddress)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    // MARK: - Command Preview

    private var commandPreviewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CLI Command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    // MARK: - Actions

    private var actionButtons: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if let error = creationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Button("Create") {
                Task { await createSession() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid || isCreating)
        }
        .padding()
    }

    // MARK: - Data Assembly

    private var sourceFormatted: String {
        if sourceTransport == .ssh {
            var prefix = ""
            if !sourceUser.isEmpty { prefix += "\(sourceUser)@" }
            prefix += sourceHost
            if !sourcePort.isEmpty { prefix += ":\(sourcePort)" }
            return "\(prefix):\(sourceAddress)"
        }
        return sourceAddress
    }

    private var destFormatted: String {
        if destTransport == .ssh {
            var prefix = ""
            if !destUser.isEmpty { prefix += "\(destUser)@" }
            prefix += destHost
            if !destPort.isEmpty { prefix += ":\(destPort)" }
            return "\(prefix):\(destAddress)"
        }
        return destAddress
    }

    private var options: ForwardCreateOptions {
        var opts = ForwardCreateOptions()
        opts.name = sessionName.isEmpty ? nil : sessionName
        opts.labels = labels
        opts.paused = createPaused
        return opts
    }

    private var commandPreview: String {
        options.commandPreview(source: sourceFormatted, destination: destFormatted)
    }

    private var nameValidationError: String? {
        SessionName.validate(sessionName, existingNames: store.forwardSessionNames())?.message
    }

    private var isValid: Bool {
        !sourceAddress.isEmpty && !destAddress.isEmpty
            && (sourceTransport == .local || !sourceHost.isEmpty)
            && (destTransport == .local || !destHost.isEmpty)
            && nameValidationError == nil
    }

    private func createSession() async {
        isCreating = true
        creationError = await store.createForward(
            options: options,
            source: sourceFormatted,
            destination: destFormatted
        )
        isCreating = false
        if creationError == nil {
            dismiss()
        }
    }
}
