import Foundation
import XCTest
@testable import OrbitCore

final class DropPayloadValidatorTests: XCTestCase {
    func testMatchingBatchPreservesActualDroppedOrder() {
        let a = URL(fileURLWithPath: "/fixtures/a.jpg")
        let b = URL(fileURLWithPath: "/fixtures/b.jpg")
        XCTAssertEqual(DropPayloadValidator.matchingDroppedURLs([b, a], expected: [a, b], requireExistingFiles: false), [b, a])
    }

    func testChangedMissingExtraDuplicateOrEmptyPayloadCannotExecutePreview() {
        let a = URL(fileURLWithPath: "/fixtures/a.jpg")
        let b = URL(fileURLWithPath: "/fixtures/b.jpg")
        let c = URL(fileURLWithPath: "/fixtures/c.jpg")
        for dropped in [[a], [a, c], [a, b, c], [a, a], []] {
            XCTAssertNil(DropPayloadValidator.matchingDroppedURLs(dropped, expected: [a, b], requireExistingFiles: false))
        }
        XCTAssertNil(DropPayloadValidator.matchingDroppedURLs([], expected: [], requireExistingFiles: false))
    }

    func testRemoteAndForeignHostedFileURLsAreRejected() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.com/a.jpg"))
        let foreign = try XCTUnwrap(URL(string: "file://other-host/fixtures/a.jpg"))
        for url in [remote, foreign] {
            XCTAssertNil(DropPayloadValidator.matchingDroppedURLs([url], expected: [url], requireExistingFiles: false))
        }
    }

    func testMissingFilesAreRejectedAndExistingFilesAccepted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Orbit-Drop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(DropPayloadValidator.matchingDroppedURLs([url], expected: [url]))
        try Data([1]).write(to: url)
        XCTAssertEqual(DropPayloadValidator.matchingDroppedURLs([url], expected: [url]), [url])
    }

    func testStandardizedPathsMatchAndCanonicalDuplicatesAreRejected() {
        let original = URL(fileURLWithPath: "/fixtures/a.jpg")
        let alias = URL(fileURLWithPath: "/fixtures/../fixtures/a.jpg")
        XCTAssertEqual(DropPayloadValidator.matchingDroppedURLs([alias], expected: [original], requireExistingFiles: false), [alias])
        XCTAssertNil(DropPayloadValidator.matchingDroppedURLs([original, alias], expected: [original, alias], requireExistingFiles: false))
    }
}
