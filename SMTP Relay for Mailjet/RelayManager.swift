import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
    let isError: Bool

    init(_ message: String, isError: Bool = false) {
        self.message = message
        self.isError = isError
    }
}

@Observable
final class RelayManager {
    var isRunning = false
    var logEntries: [LogEntry] = []
    var messagesRelayed = 0
    var messagesFailed = 0

    private var server: SMTPServer?

    func startServer(apiKey: String, secretKey: String, port: UInt16) {
        guard !apiKey.isEmpty, !secretKey.isEmpty else {
            addLog("Cannot start: API Key and Secret Key are required", isError: true)
            return
        }

        let server = SMTPServer()
        self.server = server

        server.onLog = { [weak self] message in
            Task { @MainActor in
                self?.addLog(message)
            }
        }

        server.onStateChanged = { [weak self] running in
            Task { @MainActor in
                self?.isRunning = running
            }
        }

        server.onMessageReceived = { [weak self] message in
            Task { @MainActor in
                await self?.relayMessage(message, apiKey: apiKey, secretKey: secretKey)
            }
        }

        do {
            try server.start(port: port)
            addLog("Starting SMTP server on port \(port)...")
        } catch {
            addLog("Failed to start: \(error.localizedDescription)", isError: true)
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        isRunning = false
        addLog("Server stopped")
    }

    private func relayMessage(_ message: EmailMessage, apiKey: String, secretKey: String) async {
        addLog("Relaying: \(message.subject) to \(message.envelopeTo.joined(separator: ", "))")

        let client = MailjetClient(apiKey: apiKey, secretKey: secretKey)
        do {
            try await client.send(message: message)
            messagesRelayed += 1
            addLog("Delivered: \(message.subject)")
        } catch {
            messagesFailed += 1
            addLog("Failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func addLog(_ message: String, isError: Bool = false) {
        logEntries.insert(LogEntry(message, isError: isError), at: 0)
        if logEntries.count > 500 {
            logEntries.removeLast()
        }
    }
}
