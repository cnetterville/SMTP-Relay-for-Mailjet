import Foundation

struct EmailMessage: Sendable {
    let envelopeFrom: String
    let envelopeTo: [String]
    let rawData: String

    struct ParsedAddress: Sendable {
        let email: String
        let name: String?
    }

    var subject: String {
        headerValue(for: "Subject") ?? "(no subject)"
    }

    var parsedFrom: ParsedAddress {
        if let fromHeader = headerValue(for: "From") {
            return Self.parseAddress(fromHeader)
        }
        return ParsedAddress(email: envelopeFrom, name: nil)
    }

    var parsedTo: [ParsedAddress] {
        if let toHeader = headerValue(for: "To") {
            return toHeader.split(separator: ",").map {
                Self.parseAddress(String($0).trimmingCharacters(in: .whitespaces))
            }
        }
        return envelopeTo.map { ParsedAddress(email: $0, name: nil) }
    }

    var textBody: String? {
        let contentType = headerValue(for: "Content-Type") ?? "text/plain"
        if contentType.contains("multipart/") {
            return extractMimePart(targetType: "text/plain")
        }
        if contentType.contains("text/plain") {
            return body
        }
        return body
    }

    var htmlBody: String? {
        let contentType = headerValue(for: "Content-Type") ?? "text/plain"
        if contentType.contains("multipart/") {
            return extractMimePart(targetType: "text/html")
        }
        if contentType.contains("text/html") {
            return body
        }
        return nil
    }

    private var body: String {
        guard let range = rawData.range(of: "\r\n\r\n") else {
            return rawData
        }
        return String(rawData[range.upperBound...])
    }

    private func headerValue(for name: String) -> String? {
        let lines = rawData.components(separatedBy: "\r\n")
        for (index, line) in lines.enumerated() {
            if line.isEmpty { break }
            let prefix = name.lowercased() + ":"
            if line.lowercased().hasPrefix(prefix) {
                var value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                var nextIndex = index + 1
                while nextIndex < lines.count {
                    let nextLine = lines[nextIndex]
                    if nextLine.hasPrefix(" ") || nextLine.hasPrefix("\t") {
                        value += " " + nextLine.trimmingCharacters(in: .whitespaces)
                        nextIndex += 1
                    } else {
                        break
                    }
                }
                return value
            }
        }
        return nil
    }

    private func extractMimePart(targetType: String) -> String? {
        let mainContentType = headerValue(for: "Content-Type") ?? ""
        guard let boundary = extractBoundary(from: mainContentType) else { return nil }

        let parts = body.components(separatedBy: "--" + boundary)
        for part in parts {
            if part.hasPrefix("--") { continue }
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if trimmed.lowercased().contains("content-type: \(targetType)") ||
                trimmed.lowercased().contains("content-type:\(targetType)") {
                if let bodyRange = trimmed.range(of: "\r\n\r\n") {
                    return String(trimmed[bodyRange.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private func extractBoundary(from contentType: String) -> String? {
        let parts = contentType.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var boundary = String(trimmed.dropFirst("boundary=".count))
                boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return boundary
            }
        }
        return nil
    }

    static func parseAddress(_ address: String) -> ParsedAddress {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if let ltIdx = trimmed.firstIndex(of: "<"),
           let gtIdx = trimmed.firstIndex(of: ">"),
           ltIdx < gtIdx {
            let email = String(trimmed[trimmed.index(after: ltIdx)..<gtIdx])
            let namePart = String(trimmed[trimmed.startIndex..<ltIdx])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let name = namePart.isEmpty ? nil : namePart
            return ParsedAddress(email: email, name: name)
        }
        return ParsedAddress(email: trimmed, name: nil)
    }
}
