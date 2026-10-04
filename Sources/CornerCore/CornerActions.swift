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
    case chromePrivateWindow, chromeSearchClipboard, safariNewTab, finderNewWindow
    case textEditFromClipboard, newPages, newNumbers, newKeynote
    case runShortcut, screenshotToolbar, screenSaver, openFile
    case windowLeft, windowRight, windowMaximize, windowCenter, windowNextDisplay
    case windowRestore, windowMinimize, windowFullscreen, hideOtherApps, restoreHiddenApps
    case favoriteWebsites, openURLGroup, clipboardWorkspace
    case clipboardPlainText, clipboardJSONPretty, clipboardJSONMinify
    case clipboardURLEncode, clipboardURLDecode, clipboardBase64Encode, clipboardBase64Decode
    case clipboardUppercase, clipboardLowercase, clipboardTitleCase, clipboardSnakeCase, clipboardKebabCase
    case clipboardStripTracking, clipboardTrimLines, clipboardDedupeLines, clipboardUndo

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
        case .chromePrivateWindow: "Chrome Incognito Window"
        case .chromeSearchClipboard: "Search Clipboard with Google in Chrome"
        case .safariNewTab: "Safari New Tab"
        case .finderNewWindow: "New Finder Window"
        case .textEditFromClipboard: "Clipboard to TextEdit Draft"
        case .newPages: "New Pages Document"
        case .newNumbers: "New Numbers Spreadsheet"
        case .newKeynote: "New Keynote Presentation"
        case .runShortcut: "Run Shortcut"
        case .screenshotToolbar: "Screenshot Toolbar"
        case .screenSaver: "Start Screen Saver"
        case .openFile: "Open File or Folder"
        case .windowLeft: "Window Left Half"
        case .windowRight: "Window Right Half"
        case .windowMaximize: "Maximize Window"
        case .windowCenter: "Center Window"
        case .windowNextDisplay: "Window to Next Display"
        case .windowRestore: "Restore Window Frame"
        case .windowMinimize: "Minimize Window"
        case .windowFullscreen: "Toggle Window Full Screen"
        case .hideOtherApps: "Hide Other Apps"
        case .restoreHiddenApps: "Restore Hidden Apps"
        case .favoriteWebsites: "Favorite Websites"
        case .openURLGroup: "Open Website Group"
        case .clipboardWorkspace: "Clipboard Workspace"
        case .clipboardPlainText: "Clipboard to Plain Text"
        case .clipboardJSONPretty: "Format Clipboard JSON"
        case .clipboardJSONMinify: "Minify Clipboard JSON"
        case .clipboardURLEncode: "URL Encode Clipboard"
        case .clipboardURLDecode: "URL Decode Clipboard"
        case .clipboardBase64Encode: "Base64 Encode Clipboard"
        case .clipboardBase64Decode: "Base64 Decode Clipboard"
        case .clipboardUppercase: "Uppercase Clipboard"
        case .clipboardLowercase: "Lowercase Clipboard"
        case .clipboardTitleCase: "Title Case Clipboard"
        case .clipboardSnakeCase: "Snake Case Clipboard"
        case .clipboardKebabCase: "Kebab Case Clipboard"
        case .clipboardStripTracking: "Remove URL Tracking from Clipboard"
        case .clipboardTrimLines: "Trim Clipboard Lines"
        case .clipboardDedupeLines: "Deduplicate Clipboard Lines"
        case .clipboardUndo: "Undo Clipboard Change"
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
        case .chromePrivateWindow: "eye.slash"
        case .chromeSearchClipboard: "magnifyingglass"
        case .safariNewTab: "safari"
        case .finderNewWindow: "folder.badge.plus"
        case .textEditFromClipboard: "doc.on.clipboard"
        case .newPages: "doc.badge.plus"
        case .newNumbers: "tablecells"
        case .newKeynote: "rectangle.on.rectangle"
        case .runShortcut: "command.square"
        case .screenshotToolbar: "camera.viewfinder"
        case .screenSaver: "display"
        case .openFile: "folder"
        case .windowLeft: "rectangle.lefthalf.inset.filled"
        case .windowRight: "rectangle.righthalf.inset.filled"
        case .windowMaximize: "arrow.up.left.and.arrow.down.right"
        case .windowCenter: "rectangle.center.inset.filled"
        case .windowNextDisplay: "display.2"
        case .windowRestore: "arrow.uturn.backward"
        case .windowMinimize: "minus.rectangle"
        case .windowFullscreen: "arrow.up.backward.and.arrow.down.forward"
        case .hideOtherApps: "eye.slash"
        case .restoreHiddenApps: "eye"
        case .favoriteWebsites: "star"
        case .openURLGroup: "link.badge.plus"
        case .clipboardWorkspace: "clipboard"
        case .clipboardPlainText: "text.alignleft"
        case .clipboardJSONPretty, .clipboardJSONMinify: "curlybraces"
        case .clipboardURLEncode, .clipboardURLDecode, .clipboardStripTracking: "link"
        case .clipboardBase64Encode, .clipboardBase64Decode: "number"
        case .clipboardUppercase, .clipboardLowercase, .clipboardTitleCase, .clipboardSnakeCase, .clipboardKebabCase: "textformat"
        case .clipboardTrimLines, .clipboardDedupeLines: "line.3.horizontal.decrease"
        case .clipboardUndo: "arrow.uturn.backward"
        }
    }
    public var defaultBundleID: String? {
        switch self {
        case .chromeNewTab, .chromeHistory, .chromePrivateWindow, .chromeSearchClipboard, .whatsAppWeb, .openURL: "com.google.Chrome"
        case .chatGPT: "com.openai.chat"
        case .claude: "com.anthropic.claudefordesktop"
        case .newWord: "com.microsoft.Word"
        case .newExcel: "com.microsoft.Excel"
        case .newPowerPoint: "com.microsoft.Powerpoint"
        case .newTextEdit, .textEditFromClipboard: "com.apple.TextEdit"
        case .safariNewTab: "com.apple.Safari"
        case .finderNewWindow: "com.apple.finder"
        case .newPages: "com.apple.iWork.Pages"
        case .newNumbers: "com.apple.iWork.Numbers"
        case .newKeynote: "com.apple.iWork.Keynote"
        case .screenshotToolbar: "com.apple.screencaptureui"
        case .screenSaver: "com.apple.ScreenSaver.Engine"
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
    public var parameterKind: CornerActionParameterKind {
        switch self {
        case .openURL: .website
        case .openApplication: .application
        case .openFile: .file
        case .runShortcut: .shortcut
        case .openURLGroup: .urlGroup
        default: .none
        }
    }
    public var isWindowAction: Bool {
        switch self {
        case .windowLeft, .windowRight, .windowMaximize, .windowCenter, .windowNextDisplay,
             .windowRestore, .windowMinimize, .windowFullscreen, .hideOtherApps, .restoreHiddenApps: true
        default: false
        }
    }
    public var isClipboardTransform: Bool {
        switch self {
        case .clipboardPlainText, .clipboardJSONPretty, .clipboardJSONMinify, .clipboardURLEncode,
             .clipboardURLDecode, .clipboardBase64Encode, .clipboardBase64Decode, .clipboardUppercase,
             .clipboardLowercase, .clipboardTitleCase, .clipboardSnakeCase, .clipboardKebabCase,
             .clipboardStripTracking, .clipboardTrimLines, .clipboardDedupeLines, .clipboardUndo: true
        default: false
        }
    }
    public var category: String {
        if isWindowAction { return "Windows" }
        if isClipboardTransform || self == .clipboardWorkspace || self == .textEditFromClipboard { return "Clipboard" }
        return switch self {
        case .chromeNewTab, .chromePrivateWindow, .chromeSearchClipboard, .safariNewTab, .chromeHistory,
             .recentWebsites, .favoriteWebsites, .openURLGroup, .whatsAppWeb, .openURL: "Websites"
        case .newWord, .newExcel, .newPowerPoint, .newTextEdit, .newPages, .newNumbers, .newKeynote: "Documents"
        case .runShortcut, .screenshotToolbar, .screenSaver, .activityMonitor, .openSystemSettings: "Utilities"
        case .finder, .finderNewWindow, .openDownloads, .openApplications, .openFile: "Files"
        case .none: "Disabled"
        default: "Applications"
        }
    }
    public var purpose: String {
        if isWindowAction { return "Apply this window action when explicitly run. Window controls may require Accessibility access." }
        if isClipboardTransform && self != .clipboardUndo { return "Transform the current plain clipboard text locally when explicitly run; invalid input produces an error." }
        return switch self {
        case .none: "Leave this gesture unassigned."
        case .chromeSearchClipboard: "Read plain clipboard text when run and send the encoded query to Google in Chrome."
        case .textEditFromClipboard: "Create a private CornerOrbit text draft from the current clipboard, then open it in TextEdit."
        case .runShortcut: "Run the selected macOS Shortcut by its exact name. Shortcuts can perform their configured actions."
        case .openFile: "Open the chosen local file or folder with its default application."
        case .screenshotToolbar: "Open the macOS Screenshot toolbar; choose capture options there."
        case .screenSaver: "Start the macOS screen saver; this action does not lock the Mac."
        case .chromeHistory: "Show Chrome history only after explicitly connecting the local history source."
        case .recentWebsites: "Show websites explicitly opened through CornerOrbit."
        case .favoriteWebsites: "Show locally saved favorite websites."
        case .openURLGroup: "Open the websites in the selected local group."
        case .clipboardWorkspace: "Show local clipboard tools without transforming the clipboard."
        case .clipboardUndo: "Restore the prior clipboard state if the current clipboard still matches CornerOrbit’s last change."
        default: title + " when explicitly run; an installed target is required."
        }
    }
    public var searchTerms: [String] { [rawValue, title, category, purpose] }
}

public enum CornerActionParameterKind: String, Codable, Hashable, Sendable {
    case none, website, application, file, shortcut, urlGroup
}

public struct CornerAction: Codable, Hashable, Sendable {
    public var kind: CornerActionKind
    public var url: String?
    public var bundleID: String?
    public var argument: String?
    public var parameterKind: CornerActionParameterKind { kind.parameterKind }
    public init(kind: CornerActionKind, url: String? = nil, bundleID: String? = nil, argument: String? = nil) {
        self.kind = kind; self.url = url; self.bundleID = bundleID; self.argument = argument
    }
    public static let none = CornerAction(kind: .none)
    private enum CodingKeys: String, CodingKey { case kind, url, bundleID, argument }
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        kind = try box.decode(CornerActionKind.self, forKey: .kind)
        url = try box.decodeIfPresent(String.self, forKey: .url)
        bundleID = try box.decodeIfPresent(String.self, forKey: .bundleID)
        argument = try box.decodeIfPresent(String.self, forKey: .argument)
        self = try validated()
    }
    public func encode(to encoder: any Encoder) throws {
        let valid = try validated()
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(valid.kind, forKey: .kind)
        try box.encodeIfPresent(valid.url, forKey: .url); try box.encodeIfPresent(valid.bundleID, forKey: .bundleID)
        try box.encodeIfPresent(valid.argument, forKey: .argument)
    }
    public var webURL: URL? {
        if kind == .openURL, let url { return try? CornerURLValidation.webURL(url) }
        return kind.defaultURL
    }
    public func validated() throws -> CornerAction {
        var result = self
        switch kind {
        case .openURL:
            guard bundleID == nil, argument == nil, let url else { throw CornerActionError.invalid("A custom website requires a URL and no application parameter.") }
            result.url = try CornerURLValidation.webURL(url).absoluteString
        case .openApplication:
            guard url == nil, argument == nil, let bundleID else { throw CornerActionError.invalid("A custom application requires its bundle identifier and no URL parameter.") }
            let value = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            let permitted = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            guard (3...255).contains(value.utf8.count), parts.count >= 2,
                  parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(permitted.contains) }) else {
                throw CornerActionError.invalid("Enter a valid application bundle identifier, such as com.apple.TextEdit.")
            }
            result.bundleID = value
        case .openFile:
            guard url == nil, bundleID == nil, let argument else { throw CornerActionError.invalid("Choose a local file or folder.") }
            result.argument = try CornerActionArgumentValidation.localPath(argument)
        case .runShortcut:
            guard url == nil, bundleID == nil, let argument else { throw CornerActionError.invalid("Choose a Shortcut by its exact name.") }
            result.argument = try CornerActionArgumentValidation.shortcutName(argument)
        case .openURLGroup:
            guard url == nil, bundleID == nil, let argument,
                  let id = UUID(uuidString: argument) else { throw CornerActionError.invalid("Choose a valid saved website group.") }
            result.argument = id.uuidString
        default:
            guard url == nil, bundleID == nil, argument == nil else { throw CornerActionError.invalid("This built-in action does not accept custom parameters.") }
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

public enum CornerActionArgumentValidation {
    public static func localPath(_ raw: String) throws -> String {
        guard raw.hasPrefix("/"), raw.utf8.count <= 4_096,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !raw.split(separator: "/", omittingEmptySubsequences: true).contains("..") else {
            throw CornerActionError.invalid("Choose an absolute local file or folder path without parent traversal.")
        }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }
    public static func shortcutName(_ raw: String) throws -> String {
        // Preserve intentional leading/trailing spaces in actual Shortcut names.
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !raw.hasPrefix("-"), raw.utf8.count <= 1_024,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CornerActionError.invalid("Choose a nonempty Shortcut name of at most 1,024 UTF-8 bytes that does not begin with a dash.")
        }
        return raw
    }
}
