import SwiftUI

struct ContentView: View {
    @Bindable var relayManager: RelayManager
    @AppStorage("smtpPort") private var port = 2525
    @AppStorage("autoStartServer") private var autoStart = false
    @AppStorage("hideDockIcon") private var hideDockIcon = false
    @AppStorage("testFromEmail") private var testFromEmail = ""
    @AppStorage("testToEmail") private var testToEmail = ""
    @State private var selectedLogEntry: LogEntry?
    @State private var isSendingTest = false

    var body: some View {
        HSplitView {
            settingsPane
                .frame(minWidth: 280, maxWidth: 340)

            logPane
                .frame(minWidth: 300)
        }
        .frame(minWidth: 650, minHeight: 450)
        .onAppear {
            if autoStart && !relayManager.isRunning {
                relayManager.startServer(port: UInt16(clamping: port))
            }
        }
        .sheet(item: $selectedLogEntry) { entry in
            LogDetailView(entry: entry)
        }
    }

    // MARK: - Settings Pane

    private var settingsPane: some View {
        Form {
            Section("Server") {
                HStack {
                    Circle()
                        .fill(relayManager.isRunning ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(relayManager.isRunning ? "Running on port \(port)" : "Stopped")
                        .font(.subheadline)
                }

                Button(relayManager.isRunning ? "Stop Server" : "Start Server") {
                    toggleServer()
                }
                .buttonStyle(.borderedProminent)
                .tint(relayManager.isRunning ? .red : .accentColor)
                .frame(maxWidth: .infinity)

                Toggle("Start automatically on launch", isOn: $autoStart)
                    .font(.caption)

                Toggle("Hide dock icon", isOn: $hideDockIcon)
                    .font(.caption)
                    .onChange(of: hideDockIcon) { _, hide in
                        NSApp.setActivationPolicy(hide ? .accessory : .regular)
                    }
            }

            Section("Mailjet Credentials") {
                TextField("API Key", text: $relayManager.apiKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("Secret Key", text: $relayManager.secretKey)
                    .textFieldStyle(.roundedBorder)
                Text("Stored securely in Keychain")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .disabled(relayManager.isRunning)

            Section("SMTP Settings") {
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)

                Text("Configure applications to use:\nlocalhost:\(port) as the SMTP server.\nNo authentication required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(relayManager.isRunning)

            Section("Test Email") {
                TextField("From", text: $testFromEmail)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                TextField("To", text: $testToEmail)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                Button("Send Test Email") {
                    isSendingTest = true
                    Task {
                        await relayManager.sendTestEmail(from: testFromEmail, to: testToEmail)
                        isSendingTest = false
                    }
                }
                .disabled(testFromEmail.isEmpty || testToEmail.isEmpty || isSendingTest)
                .buttonStyle(.bordered)
            }

            Section("Statistics") {
                LabeledContent("Relayed") {
                    Text("\(relayManager.messagesRelayed)")
                        .monospacedDigit()
                }
                LabeledContent("Failed") {
                    Text("\(relayManager.messagesFailed)")
                        .monospacedDigit()
                        .foregroundStyle(relayManager.messagesFailed > 0 ? .red : .primary)
                }
                LabeledContent("Pending Retries") {
                    Text("\(relayManager.retryQueue.count)")
                        .monospacedDigit()
                        .foregroundStyle(relayManager.retryQueue.isEmpty ? Color.primary : Color.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Log Pane

    private var logPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity Log")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    relayManager.logEntries.removeAll()
                }
                .buttonStyle(.borderless)
                .disabled(relayManager.logEntries.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if relayManager.logEntries.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "tray",
                    description: Text("Start the server to begin relaying emails")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(relayManager.logEntries) { entry in
                    Button {
                        if entry.emailDetail != nil {
                            selectedLogEntry = entry
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.timestamp, style: .time)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(entry.message)
                                .font(.system(.caption))
                                .foregroundStyle(entry.isError ? .red : .primary)
                            if entry.emailDetail != nil {
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private func toggleServer() {
        if relayManager.isRunning {
            relayManager.stopServer()
        } else {
            relayManager.startServer(port: UInt16(clamping: port))
        }
    }
}

// MARK: - Log Detail View

struct LogDetailView: View {
    let entry: LogEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Email Details")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if let detail = entry.emailDetail {
                Form {
                    LabeledContent("Status") {
                        Text(detail.status)
                            .foregroundStyle(
                                detail.status.contains("Delivered") ? .green :
                                detail.status.contains("Failed") ? .red : .orange
                            )
                    }
                    LabeledContent("From") {
                        Text(detail.from)
                            .textSelection(.enabled)
                    }
                    LabeledContent("To") {
                        Text(detail.to.joined(separator: ", "))
                            .textSelection(.enabled)
                    }
                    LabeledContent("Subject") {
                        Text(detail.subject)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Time") {
                        Text(entry.timestamp, format: .dateTime)
                    }

                    if !detail.bodyPreview.isEmpty {
                        Section("Body Preview") {
                            Text(detail.bodyPreview)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(minWidth: 450, minHeight: 300)
    }
}

#Preview {
    ContentView(relayManager: RelayManager())
}
