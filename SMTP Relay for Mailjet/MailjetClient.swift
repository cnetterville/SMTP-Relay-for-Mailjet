import Foundation

struct MailjetClient: Sendable {
    let apiKey: String
    let secretKey: String

    enum MailjetError: Error, LocalizedError {
        case invalidCredentials
        case sendFailed(String)
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidCredentials:
                return "Invalid Mailjet API credentials"
            case .sendFailed(let msg):
                return "Send failed: \(msg)"
            case .httpError(let code, let body):
                return "HTTP \(code): \(body)"
            }
        }
    }

    private struct SendResponse: Decodable {
        let Messages: [MessageResult]
    }

    private struct MessageResult: Decodable {
        let Status: String
        let Errors: [MessageError]?
    }

    private struct MessageError: Decodable {
        let ErrorMessage: String
        let StatusCode: Int
    }

    func send(message: EmailMessage) async throws {
        let url = URL(string: "https://api.mailjet.com/v3.1/send")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let credentials = Data("\(apiKey):\(secretKey)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let from = message.parsedFrom
        var mailjetMessage: [String: Any] = [
            "From": buildAddress(email: from.email, name: from.name),
            "To": message.parsedTo.map { buildAddress(email: $0.email, name: $0.name) },
            "Subject": message.subject
        ]

        if let text = message.textBody {
            mailjetMessage["TextPart"] = text
        }
        if let html = message.htmlBody {
            mailjetMessage["HTMLPart"] = html
        }
        if mailjetMessage["TextPart"] == nil && mailjetMessage["HTMLPart"] == nil {
            mailjetMessage["TextPart"] = ""
        }

        let body: [String: Any] = ["Messages": [mailjetMessage]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MailjetError.sendFailed("Invalid response")
        }

        if httpResponse.statusCode == 401 {
            throw MailjetError.invalidCredentials
        }

        let responseBody = String(data: data, encoding: .utf8) ?? ""

        guard (200...299).contains(httpResponse.statusCode) else {
            throw MailjetError.httpError(httpResponse.statusCode, responseBody)
        }

        let sendResponse = try JSONDecoder().decode(SendResponse.self, from: data)
        if let result = sendResponse.Messages.first, result.Status == "error" {
            let errorMsg = result.Errors?.first?.ErrorMessage ?? "Unknown error"
            throw MailjetError.sendFailed(errorMsg)
        }
    }

    private func buildAddress(email: String, name: String?) -> [String: String] {
        var dict = ["Email": email]
        if let name, !name.isEmpty {
            dict["Name"] = name
        }
        return dict
    }
}
