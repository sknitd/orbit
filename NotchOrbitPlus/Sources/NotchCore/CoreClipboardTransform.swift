import Foundation

public enum CoreClipboardTransform: String, CaseIterable, Sendable, Identifiable {
    case jsonPretty, jsonMinify, urlEncode, urlDecode, base64Encode, base64Decode
    case uppercase, lowercase, titleCase, stripTracking, trim, deduplicateLines
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .jsonPretty: "Format JSON"; case .jsonMinify: "Minify JSON"
        case .urlEncode: "URL encode"; case .urlDecode: "URL decode"
        case .base64Encode: "Base64 encode UTF-8"; case .base64Decode: "Base64 decode to UTF-8"
        case .uppercase: "UPPERCASE"; case .lowercase: "lowercase"; case .titleCase: "Title Case"
        case .stripTracking: "Remove URL tracking"; case .trim: "Trim outer whitespace"
        case .deduplicateLines: "Deduplicate lines"
        }
    }
    public func apply(to input: String) throws -> String {
        guard input.utf8.count <= 100_000 else { throw CoreTransformError.tooLarge }
        let output: String
        switch self {
        case .jsonPretty, .jsonMinify:
            guard let data = input.data(using: .utf8) else { throw CoreTransformError.invalidJSON }
            do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
            catch { throw CoreTransformError.invalidJSON }
            output = Self.formatJSON(input, pretty: self == .jsonPretty)
        case .urlEncode:
            guard let value = input.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else { throw CoreTransformError.invalidURL }
            output = value
        case .urlDecode:
            guard let value = input.removingPercentEncoding else { throw CoreTransformError.invalidURL }
            output = value
        case .base64Encode: output = Data(input.utf8).base64EncodedString()
        case .base64Decode:
            guard let data = Data(base64Encoded: input), let value = String(data: data, encoding: .utf8) else { throw CoreTransformError.invalidBase64 }
            output = value
        case .uppercase: output = input.uppercased()
        case .lowercase: output = input.lowercased()
        case .titleCase: output = input.capitalized
        case .trim: output = input.trimmingCharacters(in: .whitespacesAndNewlines)
        case .deduplicateLines:
            var seen = Set<String>()
            output = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n").filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .stripTracking:
            let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard source.removingPercentEncoding != nil, var components = URLComponents(string: source),
                  ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { throw CoreTransformError.invalidURL }
            let tracking: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid"]
            if let query = components.percentEncodedQuery {
                let retained = query.components(separatedBy: "&").filter { segment in
                    let name = String(segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                        .removingPercentEncoding?.lowercased() ?? ""
                    return !(name.hasPrefix("utm_") || tracking.contains(name))
                }
                // Preserve every remaining query segment exactly, including
                // %2B versus + and duplicate parameters with meaningful order.
                components.percentEncodedQuery = retained.isEmpty ? nil : retained.joined(separator: "&")
            }
            guard let value = components.url?.absoluteString else { throw CoreTransformError.invalidURL }
            output = value
        }
        guard output.utf8.count <= 500_000 else { throw CoreTransformError.tooLarge }
        return output
    }
    /// Preserve string escapes and numeric lexemes instead of converting a
    /// large JSON integer through floating-point serialization.
    private static func formatJSON(_ source: String, pretty: Bool) -> String {
        var tokens: [String] = []; var token = ""; var quoted = false; var escaped = false
        func flush() { if !token.isEmpty { tokens.append(token); token = "" } }
        for character in source {
            if quoted {
                token.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false; flush() }
            } else if character == "\"" { flush(); quoted = true; token.append(character) }
            else if "{}[],:".contains(character) { flush(); tokens.append(String(character)) }
            else if character.isWhitespace { flush() }
            else { token.append(character) }
        }
        flush()
        guard pretty else { return tokens.joined() }
        var result = ""; var depth = 0
        func newline() { result += "\n" + String(repeating: "  ", count: depth) }
        for (index, token) in tokens.enumerated() {
            switch token {
            case "{", "[":
                result += token; depth += 1
                if index + 1 < tokens.count, !["}", "]"].contains(tokens[index + 1]) { newline() }
            case "}", "]":
                depth -= 1
                if index > 0, !["{", "["].contains(tokens[index - 1]) { newline() }
                result += token
            case ",": result += token; newline()
            case ":": result += ": "
            default: result += token
            }
        }
        return result
    }
}

public enum CoreTransformError: LocalizedError, Sendable, Equatable {
    case tooLarge, invalidJSON, invalidURL, invalidBase64
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "Use at most 100 KB of input; transformed output is limited to 500 KB."
        case .invalidJSON: "This is not valid JSON. No transformed output was produced."
        case .invalidURL: "This URL or percent-encoded text is invalid. No transformed output was produced."
        case .invalidBase64: "Use valid Base64 containing UTF-8 text. Binary data cannot be copied as text."
        }
    }
}
