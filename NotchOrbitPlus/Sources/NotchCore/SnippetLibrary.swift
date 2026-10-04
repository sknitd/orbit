import Foundation

public struct CoreSnippetFolder: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct CoreSnippet: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var folderID: UUID?
    public var title: String
    public var text: String
    /// Explicit opt-in: secrets and verification codes must stay local.
    public var allowsSync: Bool
    public init(id: UUID = UUID(), folderID: UUID? = nil, title: String, text: String, allowsSync: Bool = false) {
        self.id = id; self.folderID = folderID; self.title = title; self.text = text; self.allowsSync = allowsSync
    }
}

public struct CoreSnippetLibrary: Codable, Equatable, Sendable {
    public static let maximumBytes = 1_048_576
    public var schemaVersion = 1
    public var folders: [CoreSnippetFolder]
    public var snippets: [CoreSnippet]
    public init(folders: [CoreSnippetFolder] = [], snippets: [CoreSnippet] = []) { self.folders = folders; self.snippets = snippets }
    public func validate() throws {
        guard schemaVersion == 1, folders.count <= 50, snippets.count <= 500,
              Set(folders.map(\.id)).count == folders.count, Set(snippets.map(\.id)).count == snippets.count else {
            throw SyncFailure.invalid("Snippets support up to 50 folders and 500 unique snippets.")
        }
        let folderIDs = Set(folders.map(\.id))
        guard folders.allSatisfy({ Self.validTitle($0.name) }), snippets.allSatisfy({
            Self.validTitle($0.title) && !$0.text.isEmpty && $0.text.utf8.count <= 32_768 && !$0.text.contains("\0")
                && ($0.folderID == nil || folderIDs.contains($0.folderID!))
        }) else { throw SyncFailure.invalid("A snippet needs a short title, valid folder and 1–32 KB of text.") }
    }
    private static func validTitle(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 120 && text.rangeOfCharacter(from: .controlCharacters) == nil
    }
    public func encoded() throws -> Data {
        try validate(); let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw SyncFailure.invalid("The snippet library exceeds 1 MB.") }; return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw SyncFailure.invalid("The snippet library exceeds 1 MB; its original is retained.") }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
    public func syncLibrary() -> Self {
        let shared = snippets.filter(\.allowsSync), used = Set(shared.compactMap(\.folderID))
        return Self(folders: folders.filter { used.contains($0.id) }, snippets: shared)
    }
    public func applyingShared(_ shared: Self) throws -> Self {
        try shared.validate()
        guard shared.snippets.allSatisfy(\.allowsSync) else { throw SyncFailure.invalid("Local-only snippets cannot appear in a shared snapshot.") }
        let privateSnippets = snippets.filter { !$0.allowsSync }
        guard Set(privateSnippets.map(\.id)).isDisjoint(with: Set(shared.snippets.map(\.id))) else {
            throw SyncFailure.invalid("A shared snippet conflicts with a local-only identity; the local original is retained.")
        }
        let privateFolderIDs = Set(privateSnippets.compactMap(\.folderID))
        let previouslySharedFolders = Set(snippets.filter(\.allowsSync).compactMap(\.folderID))
        var nextFolders = folders.filter { privateFolderIDs.contains($0.id) || !previouslySharedFolders.contains($0.id) }
        for folder in shared.folders {
            if let previous = nextFolders.first(where: { $0.id == folder.id }) {
                guard previous == folder else { throw SyncFailure.invalid("A shared folder conflicts with a local-only snippet folder; both originals are retained.") }
            } else { nextFolders.append(folder) }
        }
        let result = Self(folders: nextFolders, snippets: privateSnippets + shared.snippets); try result.validate(); return result
    }
    public func search(_ query: String, folderID: UUID? = nil) -> [CoreSnippet] {
        let terms = ShelfLibrarySearch.fold(query).split(whereSeparator: \.isWhitespace)
        return snippets.filter { snippet in
            guard folderID == nil || snippet.folderID == folderID else { return false }
            let folder = folders.first(where: { $0.id == snippet.folderID })?.name ?? ""
            let text = ShelfLibrarySearch.fold(snippet.title + " " + snippet.text + " " + folder)
            return terms.allSatisfy { text.contains($0) }
        }
    }
}
