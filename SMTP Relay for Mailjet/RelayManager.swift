import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
    let isError: Bool
    var emailDetail: EmailDetail?

    struct EmailDetail {
        let from: String
        let to: [String]
        let subject: String
        let bodyPreview: String
        let status: String
    }

    init(_ message: String, isError: Bool = false, emailDetail: EmailDetail? = nil) {
        self.message = message
        self.isError = isError
        self.emailDetail = emailDetail
    }
}

struct PendingRetry: Identifiable {
    let id = UUID()
    let message: EmailMessage
    var retryCount: Int
    var nextRetryDate: Date
    static let maxRetries = 5
}

@Observable
final class RelayManager {
    var isRunning = false
    var logEntries: [LogEntry] = []
    var messagesRelayed = 0
    var messagesFailed = 0
    var retryQueue: [PendingRetry] = []
    var apiKey: String = ""
    var secretKey: String = ""

    private var server: SMTPServer?
    private var retryTask: Task<Void, Never>?

    init() {
        if let stored = UserDefaults.standard.string(forKey: "mailjetApiKey"), !stored.isEmpty {
            KeychainManager.save(key: "mailjet-api-key", value: stored)
            UserDefaults.standard.removeObject(forKey: "mailjetApiKey")
            apiKey = stored
        } else {
            apiKey = KeychainManager.load(key: "mailjet-api-key") ?? ""
        }

        if let stored = UserDefaults.standard.string(forKey: "mailjetSecretKey"), !stored.isEmpty {
            KeychainManager.save(key: "mailjet-secret-key", value: stored)
            UserDefaults.standard.removeObject(forKey: "mailjetSecretKey")
            secretKey = stored
        } else {
            secretKey = KeychainManager.load(key: "mailjet-secret-key") ?? ""
        }
    }

    func saveCredentials() {
        KeychainManager.save(key: "mailjet-api-key", value: apiKey)
        KeychainManager.save(key: "mailjet-secret-key", value: secretKey)
    }

    func startServer(port: UInt16) {
        guard !apiKey.isEmpty, !secretKey.isEmpty else {
            addLog("Cannot start: API Key and Secret Key are required", isError: true)
            return
        }

        saveCredentials()

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
                if running {
                    self?.startRetryLoop()
                }
            }
        }

        server.onMessageReceived = { [weak self] message in
            Task { @MainActor in
                await self?.relayMessage(message)
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
        retryTask?.cancel()
        retryTask = nil
        addLog("Server stopped")
    }

    func sendTestEmail(from: String, to: String) async {
        guard !apiKey.isEmpty, !secretKey.isEmpty else {
            addLog("Cannot send test: API Key and Secret Key are required", isError: true)
            return
        }

        saveCredentials()

        let timestamp = Date.now.formatted(date: .abbreviated, time: .standard)
        let message = EmailMessage(
            envelopeFrom: from,
            envelopeTo: [to],
            rawData: "From: \(from)\r\nTo: \(to)\r\nSubject: SMTP Relay Test\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nThis is a test email sent from SMTP Relay for Mailjet.\nTimestamp: \(timestamp)\n\nIf you received this, your relay is configured correctly."
        )

        addLog("Sending test email to \(to)...")
        let client = MailjetClient(apiKey: apiKey, secretKey: secretKey)
        do {
            try await client.send(message: message)
            messagesRelayed += 1
            let detail = LogEntry.EmailDetail(
                from: from, to: [to], subject: "SMTP Relay Test",
                bodyPreview: "Test email", status: "Delivered"
            )
            addLog("Test email delivered to \(to)", emailDetail: detail)
        } catch {
            messagesFailed += 1
            addLog("Test email failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func relayMessage(_ message: EmailMessage) async {
        let detail = LogEntry.EmailDetail(
            from: message.envelopeFrom,
            to: message.envelopeTo,
            subject: message.subject,
            bodyPreview: String(message.textBody?.prefix(200) ?? ""),
            status: "Delivering"
        )
        addLog("Relaying: \(message.subject) to \(message.envelopeTo.joined(separator: ", "))", emailDetail: detail)

        let client = MailjetClient(apiKey: apiKey, secretKey: secretKey)
        do {
            try await client.send(message: message)
            messagesRelayed += 1
            let successDetail = LogEntry.EmailDetail(
                from: detail.from, to: detail.to, subject: detail.subject,
                bodyPreview: detail.bodyPreview, status: "Delivered"
            )
            addLog("Delivered: \(message.subject)", emailDetail: successDetail)
        } catch {
            addLog("Failed: \(error.localizedDescription)", isError: true)
            scheduleRetry(message: message, retryCount: 0)
        }
    }

    private func scheduleRetry(message: EmailMessage, retryCount: Int) {
        guard retryCount < PendingRetry.maxRetries else {
            messagesFailed += 1
            addLog("Permanently failed after \(PendingRetry.maxRetries) attempts: \(message.subject)", isError: true)
            return
        }

        let delay = pow(2.0, Double(retryCount + 1)) * 5.0
        let retry = PendingRetry(
            message: message,
            retryCount: retryCount,
            nextRetryDate: Date.now.addingTimeInterval(delay)
        )
        retryQueue.append(retry)
        addLog("Queued for retry in \(Int(delay))s (attempt \(retryCount + 1)/\(PendingRetry.maxRetries)): \(message.subject)")
    }

    private func startRetryLoop() {
        retryTask?.cancel()
        retryTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await processRetryQueue()
            }
        }
    }

    private func processRetryQueue() async {
        let now = Date.now
        let readyItems = retryQueue.filter { $0.nextRetryDate <= now }
        retryQueue.removeAll { item in readyItems.contains { $0.id == item.id } }

        for item in readyItems {
            addLog("Retrying (\(item.retryCount + 1)/\(PendingRetry.maxRetries)): \(item.message.subject)")

            let client = MailjetClient(apiKey: apiKey, secretKey: secretKey)
            do {
                try await client.send(message: item.message)
                messagesRelayed += 1
                let detail = LogEntry.EmailDetail(
                    from: item.message.envelopeFrom, to: item.message.envelopeTo,
                    subject: item.message.subject,
                    bodyPreview: String(item.message.textBody?.prefix(200) ?? ""),
                    status: "Delivered (retry \(item.retryCount + 1))"
                )
                addLog("Delivered on retry: \(item.message.subject)", emailDetail: detail)
            } catch {
                scheduleRetry(message: item.message, retryCount: item.retryCount + 1)
            }
        }
    }

    private func addLog(_ message: String, isError: Bool = false, emailDetail: LogEntry.EmailDetail? = nil) {
        logEntries.insert(LogEntry(message, isError: isError, emailDetail: emailDetail), at: 0)
        if logEntries.count > 500 {
            logEntries.removeLast()
        }
    }
}
