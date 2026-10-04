import Foundation

public enum CornerClipboardActionText {
    public static let maximumBytes = 65_536
    public static func bounded(_ text: String) throws -> String {
        guard text.utf8.count <= maximumBytes else {
            throw CornerActionError.invalid("Clipboard text exceeds the 64 KiB limit.")
        }
        return text
    }
    public static func googleSearchURL(_ text: String) throws -> URL {
        let text = try bounded(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CornerActionError.invalid("The clipboard has no text to search.")
        }
        var components = URLComponents()
        components.scheme = "https"; components.host = "www.google.com"; components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        guard let url = components.url else { throw CornerActionError.invalid("The clipboard search query could not be encoded.") }
        return url
    }
}
