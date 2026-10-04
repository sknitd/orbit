import Foundation
import XCTest
@testable import CornerCore

final class CornerLinksTests: XCTestCase {
    func testBoundedLibraryRoundTripNormalizesWebsitesAndPreservesOrderAndQueries() throws {
        let favorite = CornerFavorite(title: " Café reference ", url: try XCTUnwrap(URL(string: "HTTPS://Example.com/?q=keep#anchor")))
        let group = CornerLinkGroup(name: "Daily", urls: [try XCTUnwrap(URL(string: "https://example.org")), favorite.url])
        let library = try CornerLinkLibrary(favorites: [favorite], groups: [group]).validated()
        XCTAssertEqual(try CornerLinkLibrary.decode(library.encoded()), library)
        XCTAssertEqual(library.favorites[0].title, "Café reference"); XCTAssertEqual(library.favorites[0].url.absoluteString, "https://example.com/?q=keep#anchor")
        XCTAssertEqual(library.groups[0].urls.map(\.host), ["example.org", "example.com"])
    }
    func testFavoriteSearchMatchesMultipleAccentInsensitiveTitleAndURLTerms() throws {
        let favorite = CornerFavorite(title: "Café notes", url: try XCTUnwrap(URL(string: "https://example.com/reference")))
        let library = CornerLinkLibrary(favorites: [favorite])
        XCTAssertEqual(library.searchFavorites("CAFE example reference"), [favorite]); XCTAssertTrue(library.searchFavorites("café absent").isEmpty)
    }
    func testGroupsRejectEmptyOversizeDuplicateAndCredentialOrExecutableURLs() throws {
        let good = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertThrowsError(try CornerLinkGroup(name: "Empty", urls: []).validated())
        XCTAssertThrowsError(try CornerLinkGroup(name: "Large", urls: (0..<11).map { URL(string: "https://example.com/\($0)")! }).validated())
        XCTAssertThrowsError(try CornerLinkGroup(name: "Duplicates", urls: [good, good]).validated())
        for invalid in ["file:///tmp/private", "javascript:alert(1)", "https://user:secret@example.com"] {
            XCTAssertThrowsError(try CornerLinkGroup(name: "Unsafe", urls: [try XCTUnwrap(URL(string: invalid))]).validated())
        }
    }
    func testLibraryRejectsDuplicateIdentityInvalidNamesUnknownVersionAndOversizedBytes() throws {
        let favorite = CornerFavorite(title: "Valid", url: try XCTUnwrap(URL(string: "https://example.com")))
        XCTAssertThrowsError(try CornerLinkLibrary(favorites: [favorite, favorite]).encoded())
        XCTAssertThrowsError(try CornerFavorite(title: "Bad\nname", url: favorite.url).validated())
        var unknown = CornerLinkLibrary(); unknown.schemaVersion = 99; XCTAssertThrowsError(try unknown.encoded())
        XCTAssertThrowsError(try CornerLinkLibrary.decode(Data(repeating: 0, count: CornerLinkLibrary.maximumBytes + 1)))
        XCTAssertThrowsError(try CornerLinkLibrary.decode(Data("{bad".utf8)))
    }
}
