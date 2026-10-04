import Foundation

public enum AssistantFileAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case summarize, extractCSV, suggestFilename, renameScreenshots
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .summarize: "Summarize"
        case .extractCSV: "Extract CSV"
        case .suggestFilename: "Suggest filename"
        case .renameScreenshots: "Name screenshots"
        }
    }
    public var createsCopies: Bool { self == .suggestFilename || self == .renameScreenshots }
}

public enum AssistantFileFailure: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

public struct AssistantFileDocument: Sendable, Equatable {
    public let source: URL
    public let text: String
    public let sourceDigest: Data
    public init(source: URL, text: String, sourceDigest: Data) {
        self.source = source; self.text = text; self.sourceDigest = sourceDigest
    }
}

public enum AssistantFilePlanning {
    public static let maximumFiles = 16
    public static let maximumTextCharacters = 8_000
    public static func filenameStem(_ response: String) throws -> String {
        let value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\0").union(.controlCharacters)
        guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("."),
              value.utf8.count <= 150, value.rangeOfCharacter(from: forbidden) == nil,
              !value.contains("\n"), !value.contains("\r") else {
            throw AssistantFileFailure.invalid("The model must return one plain filename stem, without paths or an extension. Retry or edit the proposal.")
        }
        return value
    }
    public static func boundedText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AssistantFileFailure.invalid("The file has no readable text. Scanned PDFs need OCR before this action.") }
        return String(trimmed.prefix(maximumTextCharacters))
    }
    /// Parses CSV with quoted commas/newlines and escaped quotes; rejects malformed model output.
    public static func csvRows(_ input: String) throws -> [[String]] {
        guard !input.isEmpty, input.utf8.count <= 200_000 else { throw AssistantFileFailure.invalid("The CSV response is empty or too large.") }
        let characters = Array(input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var rows: [[String]] = []; var row: [String] = []; var field = ""
        var quoted = false; var closedQuote = false; var index = 0
        func invalid() -> AssistantFileFailure { .invalid("The model did not return well-formed CSV. Review the response and retry.") }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closedQuote = true }
                } else { field.append(character) }
            } else if character == "," {
                row.append(field); field = ""; closedQuote = false
            } else if character == "\n" {
                row.append(field); rows.append(row); row = []; field = ""; closedQuote = false
            } else if character == "\"" {
                guard field.isEmpty, !closedQuote else { throw invalid() }
                quoted = true
            } else {
                guard !closedQuote else { throw invalid() }
                field.append(character)
            }
            guard rows.count <= 200, row.count < 32, field.utf8.count <= 20_000 else { throw invalid() }
            index += 1
        }
        guard !quoted else { throw invalid() }
        if !row.isEmpty || !field.isEmpty || closedQuote || characters.last == "," { row.append(field); rows.append(row) }
        guard let columns = rows.first?.count, (1...32).contains(columns), rows.count >= 2,
              rows.count <= 200, rows.allSatisfy({ $0.count == columns }),
              rows.first?.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true else { throw invalid() }
        return rows
    }
    public static func csv(_ rows: [[String]]) -> String {
        rows.map { row in row.map { value in
            if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return value
        }.joined(separator: ",") }.joined(separator: "\n")
    }
}
