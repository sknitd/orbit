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
    /// A whole owned folder is moved, so every original inside it must be protected,
    /// including originals belonging to another shelf or to a retained Undo entry.
    /// An indexed original directory also protects all of its descendants.
    public static func folderContainsOriginal(_ folder: URL, originalURLs: [URL]) -> Bool {
        guard folder.isFileURL else { return true }
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = path == "/" ? "/" : path + "/"
        return originalURLs.contains { original in
            guard original.isFileURL else { return true }
            let canonicalOriginal = original.resolvingSymlinksInPath().standardizedFileURL
            let originalPath = canonicalOriginal.path
            if originalPath == path || originalPath.hasPrefix(prefix) { return true }
            if original.hasDirectoryPath || (try? canonicalOriginal.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return path.hasPrefix(originalPath == "/" ? "/" : originalPath + "/")
            }
            return false
        }
    }
    /// There is no recursive ownership inventory. Only an otherwise empty UUID
    /// folder containing its single managed regular file is safe to move/remove.
    public static func validateOwnedFileFolder(_ folder: URL, managedFileName: String) throws {
        let folderInfo = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folderInfo.isDirectory == true, folderInfo.isSymbolicLink != true else { throw SyncFailure.invalid("The managed folder is not a private regular directory.") }
        var enumerationFailed = false
        guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in enumerationFailed = true; return false }),
              let child = iterator.nextObject() as? URL, iterator.nextObject() == nil, !enumerationFailed,
              child.lastPathComponent == managedFileName else {
            throw SyncFailure.invalid("The managed folder contains unexpected entries; all contents were retained.")
        }
        let childInfo = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard childInfo.isRegularFile == true, childInfo.isSymbolicLink != true else {
            throw SyncFailure.invalid("Directory copies and links have no complete ownership inventory; all contents were retained.")
        }
    }
    public static func preview(items: [FileShelfItem], managedRoot: URL, olderThan date: Date, now: Date = Date(), protectedOriginalURLs: [URL] = []) -> Self {
        var eligible: [UUID] = [], references = 0
        let originals = items.map(\.originalURL) + protectedOriginalURLs
        for item in items where item.addedAt <= date {
            guard let managed = item.managedURL else { references += 1; continue }
            let expected = managedRoot.standardizedFileURL.appendingPathComponent(item.id.uuidString, isDirectory: true)
            guard managed.standardizedFileURL.deletingLastPathComponent().path == expected.path,
                  !folderContainsOriginal(expected, originalURLs: originals),
                  expected.resolvingSymlinksInPath().deletingLastPathComponent().path == managedRoot.resolvingSymlinksInPath().standardizedFileURL.path,
                  (try? expected.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            if (try? expected.checkResourceIsReachable()) == true {
                guard (try? validateOwnedFileFolder(expected, managedFileName: managed.lastPathComponent)) != nil else { continue }
            }
            eligible.append(item.id)
        }
        return Self(itemIDs: eligible, excludedReferences: references, generatedAt: now)
    }
}
