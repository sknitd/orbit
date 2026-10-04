import Foundation

public enum CornerActionError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

public enum CornerActionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case none, chromeNewTab, chromeHistory, recentWebsites
    case newWord, newExcel, newPowerPoint, newTextEdit
    case whatsAppWeb, chatGPT, claude, spotify, activityMonitor, finder
    case openApplication, openURL, openDownloads, openApplications, openSystemSettings

    public var title: String {
        switch self {
        case .none: "None"
        case .chromeNewTab: "Chrome New Tab"
        case .chromeHistory: "Chrome History"
        case .recentWebsites: "Recent Websites"
        case .newWord: "New Word Document"
        case .newExcel: "New Excel Workbook"
        case .newPowerPoint: "New PowerPoint Presentation"
        case .newTextEdit: "New TextEdit Document"
        case .whatsAppWeb: "WhatsApp Web"
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .spotify: "Spotify"
        case .activityMonitor: "Activity Monitor"
        case .finder: "Finder"
        case .openApplication: "Custom Application"
        case .openURL: "Custom Website"
        case .openDownloads: "Downloads Folder"
        case .openApplications: "Applications Folder"
        case .openSystemSettings: "System Settings"
        }
    }
    public var systemImage: String {
        switch self {
        case .none: "minus.circle"
        case .chromeNewTab: "plus.square"
        case .chromeHistory: "clock.arrow.circlepath"
        case .recentWebsites: "globe"
        case .newWord, .newTextEdit: "doc.badge.plus"
        case .newExcel: "tablecells"
        case .newPowerPoint: "rectangle.on.rectangle"
        case .whatsAppWeb: "message"
        case .chatGPT, .claude: "sparkles"
        case .spotify: "music.note"
        case .activityMonitor: "waveform.path.ecg"
        case .finder, .openDownloads, .openApplications: "folder"
        case .openApplication: "app"
        case .openURL: "link"
        case .openSystemSettings: "gearshape"
        }
    }
    public var defaultBundleID: String? {
        switch self {
        case .chromeNewTab, .chromeHistory, .whatsAppWeb, .openURL: "com.google.Chrome"
        case .chatGPT: "com.openai.chat"
        case .claude: "com.anthropic.claudefordesktop"
        case .newWord: "com.microsoft.Word"
        case .newExcel: "com.microsoft.Excel"
        case .newPowerPoint: "com.microsoft.Powerpoint"
        case .newTextEdit: "com.apple.TextEdit"
        case .spotify: "com.spotify.client"
        case .activityMonitor: "com.apple.ActivityMonitor"
        case .finder: "com.apple.finder"
        case .openSystemSettings: "com.apple.systempreferences"
        default: nil
        }
    }
    public var defaultURL: URL? {
        switch self {
        case .whatsAppWeb: URL(string: "https://web.whatsapp.com/")
        default: nil
        }
    }
}

public struct CornerAction: Codable, Hashable, Sendable {
    public var kind: CornerActionKind
    public var url: String?
    public var bundleID: String?
    public init(kind: CornerActionKind, url: String? = nil, bundleID: String? = nil) {
        self.kind = kind; self.url = url; self.bundleID = bundleID
    }
    public static let none = CornerAction(kind: .none)
    private enum CodingKeys: String, CodingKey { case kind, url, bundleID }
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        kind = try box.decode(CornerActionKind.self, forKey: .kind)
        url = try box.decodeIfPresent(String.self, forKey: .url)
        bundleID = try box.decodeIfPresent(String.self, forKey: .bundleID)
        self = try validated()
    }
    public func encode(to encoder: any Encoder) throws {
        let valid = try validated()
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(valid.kind, forKey: .kind)
        try box.encodeIfPresent(valid.url, forKey: .url); try box.encodeIfPresent(valid.bundleID, forKey: .bundleID)
    }
    public var webURL: URL? {
        if kind == .openURL, let url { return try? CornerURLValidation.webURL(url) }
        return kind.defaultURL
    }
    public func validated() throws -> CornerAction {
        var result = self
        switch kind {
        case .openURL:
            guard bundleID == nil, let url else { throw CornerActionError.invalid("A custom website requires a URL and no application parameter.") }
            result.url = try CornerURLValidation.webURL(url).absoluteString
        case .openApplication:
            guard url == nil, let bundleID else { throw CornerActionError.invalid("A custom application requires its bundle identifier and no URL parameter.") }
            let value = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            let permitted = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            guard (3...255).contains(value.utf8.count), parts.count >= 2,
                  parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(permitted.contains) }) else {
                throw CornerActionError.invalid("Enter a valid application bundle identifier, such as com.apple.TextEdit.")
            }
            result.bundleID = value
        default:
            guard url == nil, bundleID == nil else { throw CornerActionError.invalid("This built-in action does not accept custom parameters.") }
        }
        return result
    }
}

public enum CornerActionCatalog {
    public static let all = CornerActionKind.allCases
    public static func action(for kind: CornerActionKind) -> CornerAction { .init(kind: kind) }
}

public enum CornerURLValidation {
    /// Custom website/history URLs are credential-free HTTP(S); executable, local,
    /// javascript and application-scheme URLs are deliberately outside this catalog.
    public static func webURL(_ raw: String) throws -> URL {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains("\\"),
              var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              !host.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              parts.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw CornerActionError.invalid("Enter a complete HTTP or HTTPS website URL without credentials.")
        }
        parts.scheme = scheme; parts.host = host.lowercased()
        guard let url = parts.url else { throw CornerActionError.invalid("The website URL is not valid.") }
        return url
    }
}
