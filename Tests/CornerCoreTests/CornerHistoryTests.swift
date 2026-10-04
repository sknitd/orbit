import Foundation
import XCTest
@testable import CornerCore

final class CornerHistoryTests: XCTestCase {
    private func entry(_ url: String, at seconds: Double, title: String = "Page", visits: Int = 1) -> CornerHistoryEntry {
        .init(url: URL(string: url)!, title: title, lastVisited: Date(timeIntervalSince1970: seconds), visitCount: visits, source: .chrome)
    }
    func testSanitizationKeepsOnlyCredentialFreeWebsitesWithValidMetadata() {
        let values = [entry("https://example.com/?q=kept", at: 1_000), entry("file:///tmp/private", at: 2_000), entry("https://secret:password@example.com", at: 3_000), entry("javascript:alert(1)", at: 4_000), entry("https://other.example", at: 5_000, title: "line\nbreak"), entry("https://invalid.example", at: 6_000, visits: -1)]
        let sanitized = CornerHistorySanitizer.sanitize(values)
        XCTAssertEqual(sanitized.count, 1); XCTAssertEqual(sanitized.first?.url.query, "q=kept")
        XCTAssertEqual(sanitized.first?.source, .chrome)
    }
    func testCanonicalDuplicatesPreserveMostRecentEntryAndDistinctQueries() {
        let values = [entry("https://EXAMPLE.com:443/#one", at: 1_000, title: "Old"), entry("https://example.com/#two", at: 2_000, title: "New"), entry("https://example.com/?q=one", at: 3_000), entry("https://example.com/?q=two", at: 4_000)]
        let result = CornerHistorySanitizer.sanitize(values)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map { $0.lastVisited.timeIntervalSince1970 }, [4_000, 3_000, 2_000])
        XCTAssertEqual(result.last?.title, "New"); XCTAssertEqual(result.last?.url.fragment, "two")
    }
    func testRecentListIsBoundedAndTiesAreDeterministic() {
        let many = (0..<300).map { entry("https://example.com/\($0)", at: Double($0 + 1_000)) }
        let result = CornerHistorySanitizer.sanitize(many, limit: 999)
        XCTAssertEqual(result.count, 200); XCTAssertEqual(result.first?.url.path, "/299"); XCTAssertEqual(result.last?.url.path, "/100")
        XCTAssertTrue(CornerHistorySanitizer.sanitize(many, limit: 0).isEmpty)
        let ties = [entry("https://example.com/#b", at: 1_000), entry("https://example.com/#a", at: 1_000)]
        XCTAssertEqual(CornerHistorySanitizer.sanitize(ties), CornerHistorySanitizer.sanitize(Array(ties.reversed())))
    }
    func testChromeTimestampConversionRejectsNegativeAndUnreasonableFutureDates() throws {
        let unixEpoch = try XCTUnwrap(CornerHistorySanitizer.chromeVisitDate(microsecondsSince1601: 11_644_473_600_000_000))
        XCTAssertEqual(unixEpoch.timeIntervalSince1970, 0, accuracy: 0.000001)
        XCTAssertNil(CornerHistorySanitizer.chromeVisitDate(microsecondsSince1601: -1))
        XCTAssertNil(CornerHistorySanitizer.chromeVisitDate(microsecondsSince1601: Int64.max))
        let microseconds = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        XCTAssertNotNil(CornerHistorySanitizer.chromeVisitDate(microsecondsSince1601: microseconds))
    }
    func testCodableRecentEntriesRetainActualSelectedURLAndTitle() throws {
        let source = entry("https://example.com/search?q=hello#selection", at: 1_000, title: "  Page title  ", visits: 4)
        let value = try source.validated()
        XCTAssertEqual(value.title, "Page title")
        XCTAssertEqual(try JSONDecoder().decode(CornerHistoryEntry.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(value.id, value.url.absoluteString)
    }
}
