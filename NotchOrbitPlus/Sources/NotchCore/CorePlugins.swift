import Foundation

public enum CorePluginPermission: String, Codable, Sendable, Hashable, CaseIterable {
    case clipboardRead, clipboardWrite, ownFolderWrite, selectedFolderRead
    public var title: String {
        switch self { case .clipboardRead: "Read clipboard text"; case .clipboardWrite: "Copy result to clipboard"
        case .ownFolderWrite: "Write inside this plugin's folder"; case .selectedFolderRead: "Read folders you explicitly choose" }
    }
}
public enum CorePluginItemKind: String, Codable, Sendable, Hashable { case text, list, button }
public struct CorePluginItem: Codable, Sendable, Hashable {
    public let kind: CorePluginItemKind
    public let text: String?
    public let title: String?
    public let values: [String]?
    public let commandID: String?
    public init(kind: CorePluginItemKind, text: String? = nil, title: String? = nil, values: [String]? = nil, commandID: String? = nil) {
        self.kind = kind; self.text = text; self.title = title; self.values = values; self.commandID = commandID
    }
}
public struct CorePluginCommand: Codable, Sendable, Hashable {
    public let id: String
    public let script: String
    public init(id: String, script: String) { self.id = id; self.script = script }
}
public struct CorePluginManifest: Codable, Sendable, Hashable {
    public let version: Int
    public let id: String
    public let name: String
    public let description: String?
    public let permissions: [CorePluginPermission]
    public let items: [CorePluginItem]
    public let commands: [CorePluginCommand]
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw CorePluginError.invalid("Manifest exceeds 64 KB.") }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw CorePluginError.invalid("Use a Plugin API v1 manifest with text, list, button items and shell commands. Network and other runtimes are unsupported.") }
        guard value.version == 1, validID(value.id), !value.name.isEmpty, value.name.count <= 80,
              (value.description?.count ?? 0) <= 500, value.permissions.count <= 4,
              Set(value.permissions).count == value.permissions.count, value.commands.count <= 20,
              Set(value.commands.map(\.id)).count == value.commands.count else { throw CorePluginError.invalid("Invalid or unsupported Plugin API v1 manifest.") }
        for command in value.commands {
            guard validID(command.id), safeFilename(command.script), command.script.hasSuffix(".sh") else {
                throw CorePluginError.invalid("Commands must reference a simple .sh filename inside the chosen plugin folder.")
            }
        }
        try validateItems(value.items, commands: Set(value.commands.map(\.id)))
        return value
    }
    public static func safeFilename(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 120 && !value.hasPrefix(".") && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
    }
    public static func validateItems(_ items: [CorePluginItem], commands: Set<String>) throws {
        guard items.count <= 50 else { throw CorePluginError.invalid("Plugin output contains too many items.") }
        for item in items {
            guard (item.text?.count ?? 0) <= 4_096, (item.title?.count ?? 0) <= 120,
                  (item.values?.count ?? 0) <= 100, item.values?.allSatisfy({ $0.count <= 2_048 }) ?? true else {
                throw CorePluginError.invalid("Plugin text or list exceeds the supported size.")
            }
            switch item.kind {
            case .text: guard item.text != nil, item.commandID == nil, item.values == nil else { throw CorePluginError.invalid("Text items need text only.") }
            case .list: guard item.values != nil, item.commandID == nil else { throw CorePluginError.invalid("List items need values.") }
            case .button: guard let command = item.commandID, commands.contains(command), let title = item.title, !title.isEmpty else { throw CorePluginError.invalid("Button references an undeclared command.") }
            }
        }
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
    }
}
public struct CorePluginOutput: Codable, Sendable, Hashable {
    public let items: [CorePluginItem]
    public let clipboardText: String?
    public static func decode(_ data: Data, manifest: CorePluginManifest) throws -> Self {
        guard data.count <= 65_536 else { throw CorePluginError.invalid("Plugin output exceeds 64 KB.") }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw CorePluginError.invalid("The command must print a Plugin API v1 JSON object containing items.") }
        try CorePluginManifest.validateItems(value.items, commands: Set(manifest.commands.map(\.id)))
        guard (value.clipboardText?.utf8.count ?? 0) <= 65_536 else { throw CorePluginError.invalid("Clipboard output exceeds 64 KB.") }
        if value.clipboardText != nil, !manifest.permissions.contains(.clipboardWrite) {
            throw CorePluginError.invalid("The plugin did not declare clipboardWrite permission.")
        }
        return value
    }
}
public enum CorePluginError: LocalizedError, Sendable, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let text): text } }
}
