import SwiftUI

struct ContentView: View {
    @State private var relayManager = RelayManager()
    @AppStorage("mailjetApiKey") private var apiKey = ""
    @AppStorage("mailjetSecretKey") private var secretKey = ""
    @AppStorage("smtpPort") private var port = 2525

    var body: some View {
        HSplitView {
            settingsPane
                .frame(minWidth: 260, maxWidth: 320)

            logPane
                .frame(minWidth: 300)
        }
        .frame(minWidth: 600, minHeight: 400)
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
            }

            Section("Mailjet Credentials") {
                TextField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("Secret Key", text: $secretKey)
                    .textFieldStyle(.roundedBorder)
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
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.timestamp, style: .time)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Text(entry.message)
                            .font(.system(.caption))
                            .foregroundStyle(entry.isError ? .red : .primary)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func toggleServer() {
        if relayManager.isRunning {
            relayManager.stopServer()
        } else {
            relayManager.startServer(
                apiKey: apiKey,
                secretKey: secretKey,
                port: UInt16(clamping: port)
            )
        }
    }
}

#Preview {
    ContentView()
}
