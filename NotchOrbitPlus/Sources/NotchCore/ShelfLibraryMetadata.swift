import Foundation

public struct ShelfFileMetadata: Codable, Equatable, Sendable {
    public var tags: [String]
    public var favourite: Bool
    public init(tags: [String] = [], favourite: Bool = false) {
        self.tags = Self.normalizedTags(tags)
        self.favourite = favourite
    }
    private enum CodingKeys: String, CodingKey { case tags, favourite }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tags: try values.decodeIfPresent([String].self, forKey: .tags) ?? [],
                  favourite: try values.decodeIfPresent(Bool.self, forKey: .favourite) ?? false)
    }
    public static func normalizedTags(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap {
            let tag = String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            guard !tag.isEmpty, seen.insert(ShelfLibrarySearch.fold(tag)).inserted else { return nil }
            return tag
        }.prefix(20).map { $0 }
    }
}

/// Keeps the old shelf's top-level keys and defaults only the added metadata.
/// Reading an old index therefore retains its IDs, bookmarks and copy paths.
public struct ShelfLibraryArchive: Codable, Equatable, Sendable {
    public var state: FileShelfState
    public var metadata: [String: ShelfFileMetadata]
    public init(state: FileShelfState = .init(), metadata: [String: ShelfFileMetadata] = [:]) {
        self.state = state
        self.metadata = metadata
    }
    private enum CodingKeys: String, CodingKey { case items, autoSave, retention, metadata }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = FileShelfState(
            items: try values.decode([FileShelfItem].self, forKey: .items),
            autoSave: try values.decode(Bool.self, forKey: .autoSave),
            retention: try values.decode(ShelfRetention.self, forKey: .retention)
        )
        metadata = try values.decodeIfPresent([String: ShelfFileMetadata].self, forKey: .metadata) ?? [:]
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state.items, forKey: .items)
        try values.encode(state.autoSave, forKey: .autoSave)
        try values.encode(state.retention, forKey: .retention)
        try values.encode(metadata, forKey: .metadata)
    }
}

public enum ShelfLibrarySearch {
    public static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func filter(_ items: [FileShelfItem], metadata: [String: ShelfFileMetadata],
                              query: String, favouritesOnly: Bool = false) -> [FileShelfItem] {
        let terms = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            let info = metadata[item.id.uuidString] ?? .init()
            guard !favouritesOnly || info.favourite else { return false }
            let searchable = fold(item.originalURL.lastPathComponent + " " + info.tags.joined(separator: " "))
            return terms.allSatisfy { searchable.contains($0) }
        }
    }
}
