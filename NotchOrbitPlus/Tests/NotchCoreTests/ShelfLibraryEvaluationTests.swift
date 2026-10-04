import Foundation
import XCTest
@testable import NotchCore

final class ShelfLibraryEvaluationTests: XCTestCase {
    func testLegacyShelfIndexMigratesWithoutLosingIdentityBookmarkOrManagedLocation() throws {
        let item = FileShelfItem(originalURL: URL(fileURLWithPath: "/fixtures/original/Résumé.pdf"),
                                 managedURL: URL(fileURLWithPath: "/fixtures/owned/copy.pdf"),
                                 bookmark: Data([0, 1, 255, 42]), addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let old = FileShelfState(items: [item], autoSave: true, retention: .day)
        let migrated = try JSONDecoder().decode(ShelfLibraryArchive.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(migrated.state, old)
        XCTAssertEqual(migrated.state.items.first?.id, item.id)
        XCTAssertEqual(migrated.state.items.first?.bookmark, item.bookmark)
        XCTAssertEqual(migrated.state.items.first?.originalURL, item.originalURL)
        XCTAssertEqual(migrated.state.items.first?.managedURL, item.managedURL)
        XCTAssertTrue(migrated.metadata.isEmpty)
    }

    func testMetadataRoundTripKeepsTheLegacyStateReadable() throws {
        let item = FileShelfItem(originalURL: URL(fileURLWithPath: "/fixtures/notes.txt"))
        let state = FileShelfState(items: [item], autoSave: false, retention: .forever)
        let archive = ShelfLibraryArchive(state: state,
            metadata: [item.id.uuidString: .init(tags: ["Project", "Reference"], favourite: true)])
        let bytes = try JSONEncoder().encode(archive)
        XCTAssertEqual(try JSONDecoder().decode(ShelfLibraryArchive.self, from: bytes), archive)
        XCTAssertEqual(try JSONDecoder().decode(FileShelfState.self, from: bytes), state)
        XCTAssertTrue(archive.metadata[item.id.uuidString]?.favourite == true)
    }

    func testTagNormalizationPreservesReadableOrderAndBoundsDecodedInput() throws {
        let tags = [" travel ", "TRAVEL", "café", "CAFE", " "] + (0..<30).map { "tag-\($0)" }
        let normalized = ShelfFileMetadata(tags: tags)
        XCTAssertEqual(normalized.tags.count, 20)
        XCTAssertEqual(Array(normalized.tags.prefix(2)), ["travel", "café"])
        XCTAssertEqual(normalized.tags.last, "tag-17")
        let long = ShelfFileMetadata(tags: [String(repeating: "🌍", count: 60)])
        XCTAssertEqual(long.tags.first?.count, 40)
        let unbounded = try JSONSerialization.data(withJSONObject: ["tags": tags, "favourite": true])
        let decoded = try JSONDecoder().decode(ShelfFileMetadata.self, from: unbounded)
        XCTAssertEqual(decoded.tags, normalized.tags)
        XCTAssertTrue(decoded.favourite)
    }

    func testSearchUsesAllFilenameAndTagTokensWithFavouriteFilteringAndStableOrder() {
        let first = FileShelfItem(originalURL: URL(fileURLWithPath: "/fixtures/Résumé.pdf"))
        let middle = FileShelfItem(originalURL: URL(fileURLWithPath: "/fixtures/notes.txt"))
        let last = FileShelfItem(originalURL: URL(fileURLWithPath: "/fixtures/resume-2026.pdf"))
        let items = [first, middle, last]
        let metadata: [String: ShelfFileMetadata] = [
            first.id.uuidString: .init(tags: ["Clients"], favourite: true),
            middle.id.uuidString: .init(tags: ["Holiday planning"]),
            last.id.uuidString: .init(tags: ["CLIENTS"], favourite: true)
        ]
        XCTAssertEqual(ShelfLibrarySearch.filter(items, metadata: metadata, query: "RESUME client").map(\.id), [first.id, last.id])
        XCTAssertTrue(ShelfLibrarySearch.filter(items, metadata: metadata, query: "resume holiday").isEmpty)
        XCTAssertEqual(ShelfLibrarySearch.filter(items, metadata: metadata, query: "", favouritesOnly: true).map(\.id), [first.id, last.id])
        XCTAssertEqual(ShelfLibrarySearch.filter(items, metadata: metadata, query: " \n ").map(\.id), items.map(\.id))
        XCTAssertTrue(ShelfLibrarySearch.filter(items, metadata: [:], query: "", favouritesOnly: true).isEmpty)
    }
}
