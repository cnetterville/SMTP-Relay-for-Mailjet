import Foundation
import Network

final class SMTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.smtprelay.server", attributes: .concurrent)
    nonisolated(unsafe) private var listener: NWListener?
    nonisolated(unsafe) private var connections: [UUID: SMTPConnection] = [:]
    private let connectionsLock = NSLock()

    nonisolated(unsafe) var onMessageReceived: (@Sendable (EmailMessage) -> Void)?
    nonisolated(unsafe) var onLog: (@Sendable (String) -> Void)?
    nonisolated(unsafe) var onStateChanged: (@Sendable (Bool) -> Void)?

    nonisolated init() {}

    nonisolated func start(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SMTPServerError.invalidPort
        }

        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] nwConnection in
            self?.handleNewConnection(nwConnection)
        }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onLog?("SMTP server listening on port \(port)")
                self?.onStateChanged?(true)
            case .failed(let error):
                self?.onLog?("Server failed: \(error.localizedDescription)")
                self?.onStateChanged?(false)
            case .cancelled:
                self?.onStateChanged?(false)
            default:
                break
            }
        }

        listener.start(queue: queue)
    }

    nonisolated func stop() {
        listener?.cancel()
        listener = nil
        connectionsLock.lock()
        let conns = connections
        connections.removeAll()
        connectionsLock.unlock()
        conns.values.forEach { $0.stop() }
    }

    nonisolated private func handleNewConnection(_ nwConnection: NWConnection) {
        let id = UUID()
        let connection = SMTPConnection(id: id, connection: nwConnection, queue: queue)

        connection.onMessageReceived = { [weak self] message in
            self?.onMessageReceived?(message)
        }

        connection.onLog = { [weak self] log in
            self?.onLog?(log)
        }

        connection.onDisconnected = { [weak self] in
            self?.connectionsLock.lock()
            self?.connections.removeValue(forKey: id)
            self?.connectionsLock.unlock()
        }

        connectionsLock.lock()
        connections[id] = connection
        connectionsLock.unlock()

        onLog?("New connection from \(nwConnection.endpoint)")
        connection.start()
    }
}

enum SMTPServerError: Error, LocalizedError {
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPort: return "Invalid port number"
        }
    }
}

// MARK: - SMTP Connection Handler

private final class SMTPConnection: @unchecked Sendable {
    let id: UUID
    private let connection: NWConnection
    private let queue: DispatchQueue
    nonisolated(unsafe) private var buffer = Data()
    nonisolated(unsafe) private var sessionState: SessionState = .connected
    nonisolated(unsafe) private var envelopeFrom = ""
    nonisolated(unsafe) private var envelopeTo: [String] = []
    nonisolated(unsafe) private var dataBuffer = ""

    nonisolated(unsafe) var onMessageReceived: ((EmailMessage) -> Void)?
    nonisolated(unsafe) var onLog: ((String) -> Void)?
    nonisolated(unsafe) var onDisconnected: (() -> Void)?

    enum SessionState: Sendable, Equatable {
        case connected, ready, receivingData

        nonisolated static func == (lhs: SessionState, rhs: SessionState) -> Bool {
            switch (lhs, rhs) {
            case (.connected, .connected), (.ready, .ready), (.receivingData, .receivingData):
                return true
            default:
                return false
            }
        }
    }

    nonisolated init(id: UUID, connection: NWConnection, queue: DispatchQueue) {
        self.id = id
        self.connection = connection
        self.queue = queue
    }

    nonisolated func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.sendLine("220 localhost SMTP Relay for Mailjet Ready")
                self?.receive()
            case .failed, .cancelled:
                self?.onDisconnected?()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    nonisolated func stop() {
        connection.cancel()
    }

    nonisolated private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                self?.buffer.append(data)
                self?.processBuffer()
            }
            if isComplete || error != nil {
                self?.onDisconnected?()
                return
            }
            self?.receive()
        }
    }

    nonisolated private func processBuffer() {
        if sessionState == .receivingData {
            processDataMode()
            return
        }

        while let range = buffer.range(of: Data("\r\n".utf8)) {
            let lineData = buffer[buffer.startIndex..<range.lowerBound]
            buffer = Data(buffer[range.upperBound...])

            if let line = String(data: Data(lineData), encoding: .utf8) {
                processCommand(line)
            }
        }
    }

    nonisolated private func processCommand(_ command: String) {
        let upper = command.uppercased().trimmingCharacters(in: .whitespaces)

        if upper.hasPrefix("EHLO") || upper.hasPrefix("HELO") {
            sessionState = .ready
            sendLine("250-localhost Hello")
            sendLine("250-SIZE 10485760")
            sendLine("250-8BITMIME")
            sendLine("250 OK")
        } else if upper.hasPrefix("MAIL FROM:") {
            envelopeFrom = extractAddress(from: command)
            onLog?("MAIL FROM: \(envelopeFrom)")
            sendLine("250 OK")
        } else if upper.hasPrefix("RCPT TO:") {
            let addr = extractAddress(from: command)
            envelopeTo.append(addr)
            onLog?("RCPT TO: \(addr)")
            sendLine("250 OK")
        } else if upper == "DATA" {
            sessionState = .receivingData
            dataBuffer = ""
            sendLine("354 End data with <CR><LF>.<CR><LF>")
        } else if upper == "QUIT" {
            sendLine("221 Bye")
            connection.cancel()
        } else if upper == "RSET" {
            resetTransaction()
            sendLine("250 OK")
        } else if upper == "NOOP" {
            sendLine("250 OK")
        } else if upper.hasPrefix("VRFY") {
            sendLine("252 Cannot VRFY user")
        } else {
            sendLine("502 Command not recognized")
        }
    }

    nonisolated private func processDataMode() {
        guard let text = String(data: buffer, encoding: .utf8) else { return }
        dataBuffer += text
        buffer = Data()

        guard let endRange = dataBuffer.range(of: "\r\n.\r\n") else { return }

        var emailData = String(dataBuffer[dataBuffer.startIndex..<endRange.lowerBound])
        let remaining = String(dataBuffer[endRange.upperBound...])

        // Dot-unstuffing: remove leading dots that were doubled by the sender
        emailData = emailData.replacingOccurrences(of: "\r\n..", with: "\r\n.")

        let message = EmailMessage(
            envelopeFrom: envelopeFrom,
            envelopeTo: envelopeTo,
            rawData: emailData
        )

        onLog?("Received message: \(message.subject) from \(envelopeFrom) to \(envelopeTo.joined(separator: ", "))")
        onMessageReceived?(message)

        resetTransaction()
        sessionState = .ready
        buffer = Data(remaining.utf8)

        sendLine("250 OK message queued for delivery")
        processBuffer()
    }

    nonisolated private func resetTransaction() {
        envelopeFrom = ""
        envelopeTo = []
        dataBuffer = ""
    }

    nonisolated private func extractAddress(from command: String) -> String {
        if let ltIdx = command.firstIndex(of: "<"),
           let gtIdx = command.firstIndex(of: ">"),
           ltIdx < gtIdx {
            return String(command[command.index(after: ltIdx)..<gtIdx])
        }
        if let colonIdx = command.firstIndex(of: ":") {
            return String(command[command.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return command
    }

    nonisolated private func sendLine(_ text: String) {
        let data = Data((text + "\r\n").utf8)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
