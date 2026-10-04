import Foundation
import XCTest
@testable import NotchCore

final class CoreUpdateTests: XCTestCase {
    func testStableVersionsCompareNumericallyAndRejectAmbiguity() throws {
        XCTAssertLessThan(try CoreUpdateVersion("0.9.0"), try CoreUpdateVersion("0.10.0"))
        XCTAssertLessThan(try CoreUpdateVersion("0.2.9"), try CoreUpdateVersion("0.3.0"))
        for invalid in ["0.2", "01.2.3", "-1.2.3", "1.2.3-beta", "1.2.3.4", "1.2.３"] {
            XCTAssertThrowsError(try CoreUpdateVersion(invalid))
        }
    }
    func testValidPublishedFeedHasVersionAndPlatformBoundaries() throws {
        let feed = try CoreUpdateFeed.decode(fixture())
        XCTAssertTrue(try feed.isNewer(than: "0.1.0"))
        XCTAssertFalse(try feed.isNewer(than: "0.2.0"))
        XCTAssertFalse(try feed.isNewer(than: "0.3.0"))
        XCTAssertTrue(feed.supportsMacOS(major: 14, minor: 0))
        XCTAssertFalse(feed.supportsMacOS(major: 13, minor: 9))
        XCTAssertFalse(feed.signing.notarized)
    }
    func testFeedRejectsChangedOriginsPathsProductAndProvenance() throws {
        for (key, value) in [("archive_url", "http://raw.githubusercontent.com/sknitd/orbit/a.zip"),
                             ("archive_url", "https://evil.example/update.zip"),
                             ("archive_url", "https://raw.githubusercontent.com/other/orbit/update.zip"),
                             ("archive_url", "https://raw.githubusercontent.com/sknitd/orbit/codex/notch-plus-updates/packages/0.2.0/../NotchOrbitPlus.app.zip"),
                             ("product", "OtherApp"), ("bundle_identifier", "com.other.App"),
                             ("source_commit", "not-a-git-commit"), ("archive_sha256", "not-a-sha256"),
                             ("release_notes_url", "https://evil.example/notes"), ("published_at", "tomorrow")] {
            XCTAssertThrowsError(try CoreUpdateFeed.decode(fixture(changes: [key: value])), key)
        }
        XCTAssertThrowsError(try CoreUpdateFeed.decode(fixture(changes: ["archive_bytes": CoreUpdateFeed.maximumArchiveBytes + 1])))
        XCTAssertThrowsError(try CoreUpdateFeed.decode(fixture(changes: ["archive_bytes": 0])))
        for minimum in ["14..0", "-14.0", "14.0.0.1", "014.0", "14.０", "14."] {
            XCTAssertThrowsError(try CoreUpdateFeed.decode(fixture(changes: ["minimum_macos": minimum])))
        }
    }
    func testChecksumRejectsModifiedDataAndWrongLength() throws {
        let feed = try CoreUpdateFeed.decode(fixture())
        XCTAssertNoThrow(try feed.verifySHA256(String(repeating: "a", count: 64), bytes: 123))
        XCTAssertThrowsError(try feed.verifySHA256(String(repeating: "b", count: 64), bytes: 123))
        XCTAssertThrowsError(try feed.verifySHA256(String(repeating: "a", count: 64), bytes: 122))
    }
    func testAdhocCannotClaimNotarizationOrSigningTeam() throws {
        XCTAssertThrowsError(try CoreUpdateFeed.decode(fixture(changes: ["signing": ["kind": "adhoc", "notarized": true]])))
        XCTAssertThrowsError(try CoreUpdateFeed.decode(fixture(changes: ["signing": ["kind": "developer-id", "notarized": true, "team_identifier": "bad"]])))
        let signed = try CoreUpdateFeed.decode(fixture(changes: ["signing": ["kind": "developer-id", "notarized": true, "team_identifier": "ABCDE12345"]]))
        XCTAssertEqual(signed.signing.teamIdentifier, "ABCDE12345")
        XCTAssertTrue(signed.signing.notarized)
    }
    private func fixture(changes: [String: Any] = [:]) throws -> Data {
        let source = String(repeating: "a", count: 40)
        var object: [String: Any] = ["schema_version": 1, "product": "NotchOrbitPlus",
            "bundle_identifier": "com.sknitd.NotchOrbitPlus", "version": "0.2.0", "minimum_macos": "14.0",
            "source_commit": source, "archive_sha256": String(repeating: "a", count: 64), "archive_bytes": 123,
            "archive_url": "https://raw.githubusercontent.com/sknitd/orbit/codex/notch-plus-updates/packages/0.2.0/\(source)/NotchOrbitPlus.app.zip",
            "release_notes_url": "https://github.com/sknitd/orbit/tree/\(source)/NotchOrbitPlus",
            "published_at": "2026-10-04T12:00:00Z", "signing": ["kind": "adhoc", "notarized": false]]
        object.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
