import Foundation

public enum CornerClipboardMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case plainText, jsonPretty, jsonMinify, urlEncode, urlDecode, base64Encode, base64Decode
    case uppercase, lowercase, titleCase, snakeCase, kebabCase, stripTracking, trimLines, dedupeLines
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .plainText: "Clean Plain Text"
        case .jsonPretty: "JSON: Pretty"
        case .jsonMinify: "JSON: Minify"
        case .urlEncode: "URL: Encode Value"
        case .urlDecode: "URL: Decode Value"
        case .base64Encode: "Base64: Encode Text"
        case .base64Decode: "Base64: Decode Text"
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        case .titleCase: "Title Case"
        case .snakeCase: "snake_case"
        case .kebabCase: "kebab-case"
        case .stripTracking: "Remove URL Tracking"
        case .trimLines: "Trim Each Line"
        case .dedupeLines: "Remove Duplicate Lines"
        }
    }
}
public enum CornerClipboardError: Error, LocalizedError, Equatable, Sendable {
    case inputTooLarge, outputTooLarge, invalidJSON, nestingTooDeep, invalidPercentEncoding, invalidBase64, binaryBase64
    case noText, readFirst, clipboardChanged, backupTooLarge, cannotBackup, writeFailed, noUndo, unknownAction
    public var errorDescription: String? {
        switch self {
        case .inputTooLarge: "Clipboard text exceeds the 1 MB input limit. No clipboard data was changed."
        case .outputTooLarge: "The transformed text exceeds 2 MB. No clipboard data was changed."
        case .invalidJSON: "Enter valid JSON. The original text is unchanged."
        case .nestingTooDeep: "JSON nesting exceeds 128 levels. The original text is unchanged."
        case .invalidPercentEncoding: "This value contains incomplete percent escapes or invalid UTF-8. Use URL Encode Value for a query/path value, not an entire URL."
        case .invalidBase64: "Enter canonical Base64 text with valid padding. The original text is unchanged."
        case .binaryBase64: "The Base64 value decodes to binary data, not UTF-8 text. The clipboard is unchanged."
        case .noText: "The clipboard has no plain-text representation."
        case .readFirst: "Choose Read Clipboard before previewing or applying a change."
        case .clipboardChanged: "Another app changed the clipboard. Read it again; Undo will never replace another app's newer contents."
        case .backupTooLarge: "The original clipboard exceeds the 2 MB Undo limit or contains too many items/types. Nothing was replaced."
        case .cannotBackup: "An original clipboard type could not be backed up. Nothing was replaced."
        case .writeFailed: "The clipboard write failed. Review the retained in-memory Undo backup before retrying."
        case .noUndo: "There is no clipboard change from this session to undo."
        case .unknownAction: "This action is not a clipboard transform."
        }
    }
}

public enum CornerClipboardTransform {
    public static let maximumInputBytes = 1_048_576
    public static let maximumOutputBytes = 2_097_152
    public static func apply(_ text: String, mode: CornerClipboardMode) throws -> String {
        guard text.utf8.count <= maximumInputBytes else { throw CornerClipboardError.inputTooLarge }
        let result: String
        switch mode {
        case .plainText:
            let normalized = lineBreaks(text)
            result = String(String.UnicodeScalarView(normalized.unicodeScalars.filter {
                !((($0.value < 0x20 || (0x7f...0x9f).contains($0.value)) && $0.value != 9 && $0.value != 10) || $0.value == 0xfeff || $0.value == 0x200b)
            }))
        case .jsonPretty, .jsonMinify: result = try json(text, pretty: mode == .jsonPretty)
        case .urlEncode:
            guard let encoded = text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else { throw CornerClipboardError.invalidPercentEncoding }
            result = encoded
        case .urlDecode:
            guard let decoded = text.removingPercentEncoding else { throw CornerClipboardError.invalidPercentEncoding }
            result = decoded
        case .base64Encode: result = Data(text.utf8).base64EncodedString()
        case .base64Decode:
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: value), data.base64EncodedString() == value else { throw CornerClipboardError.invalidBase64 }
            guard let decoded = String(data: data, encoding: .utf8) else { throw CornerClipboardError.binaryBase64 }
            result = decoded
        case .uppercase: result = text.uppercased()
        case .lowercase: result = text.lowercased()
        case .titleCase: result = text.capitalized(with: Locale(identifier: "en_US_POSIX"))
        case .snakeCase, .kebabCase:
            var words = text
            for (pattern, replacement) in [("(\\p{Lu})(\\p{Lu}\\p{Ll})", "$1 $2"), ("([\\p{Ll}\\p{Nd}\\p{M}])(\\p{Lu})", "$1 $2"), ("[^\\p{L}\\p{M}\\p{N}]+", " ")] {
                let expression = try NSRegularExpression(pattern: pattern)
                words = expression.stringByReplacingMatches(in: words, range: NSRange(words.startIndex..., in: words), withTemplate: replacement)
            }
            result = words.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: mode == .snakeCase ? "_" : "-")
        case .stripTracking: result = try stripTracking(text)
        case .trimLines: result = lineBreaks(text).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        case .dedupeLines:
            var seen = Set<String>()
            result = lineBreaks(text).components(separatedBy: "\n").filter { seen.insert($0).inserted }.joined(separator: "\n")
        }
        guard result.utf8.count <= maximumOutputBytes else { throw CornerClipboardError.outputTooLarge }
        return result
    }
    private static func lineBreaks(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
    private static func stripTracking(_ text: String) throws -> String {
        let url = try CornerURLValidation.webURL(text)
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CornerClipboardError.invalidPercentEncoding }
        if let query = parts.percentEncodedQuery {
            let known: Set<String> = ["gclid", "dclid", "fbclid", "msclkid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "vero_id", "igshid", "yclid", "gbraid", "wbraid"]
            let retained = query.components(separatedBy: "&").filter { field in
                let name = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                let decoded = (name.removingPercentEncoding ?? name).lowercased()
                return !decoded.hasPrefix("utm_") && !known.contains(decoded)
            }
            parts.percentEncodedQuery = retained.isEmpty ? nil : retained.joined(separator: "&")
        }
        guard let clean = parts.url else { throw CornerClipboardError.invalidPercentEncoding }
        return clean.absoluteString
    }
    /// Reformat validated JSON lexically, keeping number lexemes, key order,
    /// duplicate keys and string escapes rather than round-tripping numbers.
    private static func json(_ text: String, pretty: Bool) throws -> String {
        var compact: [UInt8] = []; compact.reserveCapacity(text.utf8.count)
        var quoted = false, escaped = false, depth = 0
        for byte in text.utf8 {
            if quoted {
                compact.append(byte)
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else {
                if byte == 34 { quoted = true; compact.append(byte) }
                else if ![9, 10, 13, 32].contains(byte) {
                    if byte == 123 || byte == 91 { depth += 1; guard depth <= 128 else { throw CornerClipboardError.nestingTooDeep } }
                    if byte == 125 || byte == 93 { depth -= 1; guard depth >= 0 else { throw CornerClipboardError.invalidJSON } }
                    compact.append(byte)
                }
            }
        }
        var validator = StrictJSON(bytes: Array(text.utf8))
        try validator.validate()
        if !pretty { return String(decoding: compact, as: UTF8.self) }
        var output: [UInt8] = []; quoted = false; escaped = false; depth = 0
        func append(_ bytes: [UInt8]) throws {
            guard output.count + bytes.count <= maximumOutputBytes else { throw CornerClipboardError.outputTooLarge }
            output.append(contentsOf: bytes)
        }
        func newline() throws { try append([10] + Array(repeating: 32, count: depth * 2)) }
        for (index, byte) in compact.enumerated() {
            if quoted {
                try append([byte]); if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
                continue
            }
            switch byte {
            case 34: quoted = true; try append([byte])
            case 123, 91:
                try append([byte]); depth += 1
                if index + 1 < compact.count, compact[index + 1] != 125, compact[index + 1] != 93 { try newline() }
            case 125, 93:
                depth -= 1
                if index > 0, compact[index - 1] != 123, compact[index - 1] != 91 { try newline() }
                try append([byte])
            case 44: try append([byte]); try newline()
            case 58: try append([58, 32])
            default: try append([byte])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
    private struct StrictJSON {
        let bytes: [UInt8]
        var index = 0
        mutating func validate() throws { try value(); whitespace(); guard index == bytes.count else { throw CornerClipboardError.invalidJSON } }
        mutating func value() throws {
            whitespace()
            guard index < bytes.count else { throw CornerClipboardError.invalidJSON }
            switch bytes[index] {
            case 123:
                index += 1
                whitespace(); if consume(125) { return }
                while true { whitespace(); try string(); whitespace(); guard consume(58) else { throw CornerClipboardError.invalidJSON }; try value(); whitespace(); if consume(125) { return }; guard consume(44) else { throw CornerClipboardError.invalidJSON } }
            case 91:
                index += 1
                whitespace(); if consume(93) { return }
                while true { try value(); whitespace(); if consume(93) { return }; guard consume(44) else { throw CornerClipboardError.invalidJSON } }
            case 34: try string()
            case 116: try literal(Array("true".utf8))
            case 102: try literal(Array("false".utf8))
            case 110: try literal(Array("null".utf8))
            default: try number()
            }
        }
        mutating func consume(_ byte: UInt8) -> Bool { guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true }
        mutating func whitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func literal(_ expected: [UInt8]) throws { guard index + expected.count <= bytes.count, Array(bytes[index..<(index + expected.count)]) == expected else { throw CornerClipboardError.invalidJSON }; index += expected.count }
        mutating func string() throws {
            guard consume(34) else { throw CornerClipboardError.invalidJSON }
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return }
                guard byte >= 0x20 else { throw CornerClipboardError.invalidJSON }
                if byte != 92 { continue }
                guard index < bytes.count else { throw CornerClipboardError.invalidJSON }
                let escape = bytes[index]; index += 1
                if [34, 92, 47, 98, 102, 110, 114, 116].contains(escape) { continue }
                guard escape == 117 else { throw CornerClipboardError.invalidJSON }
                let scalar = try hexadecimal()
                if (0xd800...0xdbff).contains(scalar) {
                    guard consume(92), consume(117), (0xdc00...0xdfff).contains(try hexadecimal()) else { throw CornerClipboardError.invalidJSON }
                } else if (0xdc00...0xdfff).contains(scalar) { throw CornerClipboardError.invalidJSON }
            }
            throw CornerClipboardError.invalidJSON
        }
        mutating func hexadecimal() throws -> Int {
            guard index + 4 <= bytes.count else { throw CornerClipboardError.invalidJSON }
            var result = 0
            for _ in 0..<4 {
                let byte = bytes[index]; index += 1
                let digit: Int
                switch byte { case 48...57: digit = Int(byte - 48); case 65...70: digit = Int(byte - 55); case 97...102: digit = Int(byte - 87); default: throw CornerClipboardError.invalidJSON }
                result = result * 16 + digit
            }
            return result
        }
        mutating func number() throws {
            _ = consume(45)
            guard index < bytes.count else { throw CornerClipboardError.invalidJSON }
            if consume(48) { }
            else { guard (49...57).contains(bytes[index]) else { throw CornerClipboardError.invalidJSON }; digits() }
            if consume(46) { guard index < bytes.count, (48...57).contains(bytes[index]) else { throw CornerClipboardError.invalidJSON }; digits() }
            if consume(101) || consume(69) {
                if !consume(43) { _ = consume(45) }
                guard index < bytes.count, (48...57).contains(bytes[index]) else { throw CornerClipboardError.invalidJSON }; digits()
            }
        }
        mutating func digits() { while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 } }
    }
}
