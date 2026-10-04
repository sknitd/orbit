import Foundation

public struct CoreShelfCollection: Codable, Equatable, Sendable, Identifiable {
    public static let inboxID = UUID(uuidString: "5552C0E4-C1B0-4828-8D94-2AE21DB93DDD")!
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}
public enum CoreShelfRuleKind: String, Codable, CaseIterable, Sendable { case captures, watchFolder, expireOwnedCopies }
public struct CoreShelfRule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: CoreShelfRuleKind
    public var shelfID: UUID
    public var tags: [String]
    public var fileExtensions: [String]
    public var days: Int
    public init(id: UUID = UUID(), name: String, kind: CoreShelfRuleKind, shelfID: UUID = CoreShelfCollection.inboxID,
                tags: [String] = [], fileExtensions: [String] = [], days: Int = 7) {
        self.id = id; self.name = name; self.kind = kind; self.shelfID = shelfID; self.tags = tags; self.fileExtensions = fileExtensions; self.days = days
    }
}
/// Portable rule descriptions contain no paths, bookmarks, local enablement or shelf file contents.
public struct CoreShelfConfiguration: Codable, Equatable, Sendable {
    public static let maximumBytes = 131_072
    public var schemaVersion = 1
    public var shelves: [CoreShelfCollection]
    public var rules: [CoreShelfRule]
    public init(shelves: [CoreShelfCollection] = [.init(id: CoreShelfCollection.inboxID, name: "Inbox")], rules: [CoreShelfRule] = []) { self.shelves = shelves; self.rules = rules }
    public func validate() throws {
        guard schemaVersion == 1, (1...20).contains(shelves.count), rules.count <= 40,
              Set(shelves.map(\.id)).count == shelves.count, Set(rules.map(\.id)).count == rules.count,
              shelves.contains(where: { $0.id == CoreShelfCollection.inboxID }), shelves.allSatisfy({ Self.validName($0.name) }) else {
            throw SyncFailure.invalid("Use up to twenty named shelves and forty unique rules; keep the Inbox shelf.")
        }
        for rule in rules {
            guard Self.validName(rule.name), shelves.contains(where: { $0.id == rule.shelfID }), (1...365).contains(rule.days),
                  rule.tags.count <= 20, rule.tags == ShelfFileMetadata.normalizedTags(rule.tags), rule.fileExtensions.count <= 20,
                  Set(rule.fileExtensions).count == rule.fileExtensions.count,
                  rule.fileExtensions.allSatisfy({ !$0.isEmpty && $0.count <= 16 && $0.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) }) else {
                throw SyncFailure.invalid("Invalid shelf rule. Tags, extensions and expiry days must be bounded; folders are chosen separately on each Mac.")
            }
        }
    }
    private static func validName(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 80 && value.rangeOfCharacter(from: .controlCharacters) == nil }
    public func encoded() throws -> Data { try validate(); let data = try JSONEncoder().encode(self); guard data.count <= Self.maximumBytes else { throw SyncFailure.invalid("Shelf configuration exceeds 128 KB.") }; return data }
    public static func decode(_ data: Data) throws -> Self { guard data.count <= maximumBytes else { throw SyncFailure.invalid("Shelf configuration exceeds 128 KB.") }; let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value }
}

public struct CoreShelfCleanupPlan: Equatable, Sendable {
    public let itemIDs: [UUID]
    public let excludedReferences: Int
    public let generatedAt: Date
    public init(itemIDs: [UUID], excludedReferences: Int, generatedAt: Date) { self.itemIDs = itemIDs; self.excludedReferences = excludedReferences; self.generatedAt = generatedAt }
    public static func preview(items: [FileShelfItem], managedRoot: URL, olderThan date: Date, now: Date = Date()) -> Self {
        var eligible: [UUID] = [], references = 0
        for item in items where item.addedAt <= date {
            guard let managed = item.managedURL else { references += 1; continue }
            let expected = managedRoot.standardizedFileURL.appendingPathComponent(item.id.uuidString, isDirectory: true)
            guard managed.standardizedFileURL.deletingLastPathComponent().path == expected.path,
                  managed.standardizedFileURL.path != item.originalURL.standardizedFileURL.path else { continue }
            eligible.append(item.id)
        }
        return Self(itemIDs: eligible, excludedReferences: references, generatedAt: now)
    }
}
