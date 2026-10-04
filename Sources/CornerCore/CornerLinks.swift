import Foundation

public struct CornerFavorite: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public init(id: UUID = UUID(), title: String, url: URL) { self.id = id; self.title = title; self.url = url }
    public func validated() throws -> Self {
        guard Self.validName(title) else { throw CornerActionError.invalid("Use a favorite title of 1–160 characters without control characters.") }
        return .init(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines), url: try CornerURLValidation.webURL(url.absoluteString))
    }
    static func validName(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 160 && value.utf8.count <= 640 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
}
public struct CornerLinkGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var urls: [URL]
    public init(id: UUID = UUID(), name: String, urls: [URL]) { self.id = id; self.name = name; self.urls = urls }
    public func validated() throws -> Self {
        guard CornerFavorite.validName(name), (1...10).contains(urls.count) else { throw CornerActionError.invalid("Name the group and choose 1–10 HTTP(S) websites.") }
        let clean = try urls.map { try CornerURLValidation.webURL($0.absoluteString) }
        guard Set(clean.map(\.absoluteString)).count == clean.count else { throw CornerActionError.invalid("A URL launch group cannot contain duplicate websites.") }
        return .init(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), urls: clean)
    }
}
public struct CornerLinkLibrary: Codable, Equatable, Sendable {
    public static let maximumBytes = 2_097_152
    public var schemaVersion = 1
    public var favorites: [CornerFavorite]
    public var groups: [CornerLinkGroup]
    public init(favorites: [CornerFavorite] = [], groups: [CornerLinkGroup] = []) { self.favorites = favorites; self.groups = groups }
    public func validated() throws -> Self {
        guard schemaVersion == 1, favorites.count <= 200, groups.count <= 40,
              Set(favorites.map(\.id)).count == favorites.count, Set(groups.map(\.id)).count == groups.count else { throw CornerActionError.invalid("Use at most 200 favorites and 40 unique URL groups.") }
        return try .init(favorites: favorites.map { try $0.validated() }, groups: groups.map { try $0.validated() })
    }
    public func encoded() throws -> Data {
        let bytes = try JSONEncoder().encode(validated())
        guard bytes.count <= Self.maximumBytes else { throw CornerActionError.invalid("The link library exceeds 2 MB.") }; return bytes
    }
    public static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumBytes else { throw CornerActionError.invalid("The link library exceeds 2 MB.") }
        return try JSONDecoder().decode(Self.self, from: bytes).validated()
    }
    public func searchFavorites(_ query: String) -> [CornerFavorite] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return favorites.filter { favorite in
            let value = favorite.title + " " + favorite.url.absoluteString
            return terms.allSatisfy { value.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
