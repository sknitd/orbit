import Foundation
import XCTest
@testable import NotchCore

final class CoreLRCLyricsTests: XCTestCase {
    private let query = CoreLyricsQuery(title: "Fixture Song", artist: "Fixture Artist", album: "Fixture Album", duration: 180)

    func testQueryUsesFixedEndpointAndEscapesMetadataWithoutAdditionalParameters() throws {
        let query = CoreLyricsQuery(title: " A+B & Café? ", artist: "Artist/#%", album: "Album=Extra", duration: 180.25)
        let url = try query.requestURL()
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "lrclib.net")
        XCTAssertEqual(url.path, "/api/get")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "track_name", value: "A+B & Café?"),
            URLQueryItem(name: "artist_name", value: "Artist/#%"), URLQueryItem(name: "album_name", value: "Album=Extra"),
            URLQueryItem(name: "duration", value: "180.25")])
        XCTAssertTrue(url.absoluteString.contains("%2B"))
        XCTAssertNil(url.user)
        for duration in [0, 3_601, Double.infinity, .nan] {
            XCTAssertThrowsError(try CoreLyricsQuery(title: "Song", artist: "Artist", album: "", duration: duration).requestURL())
        }
        XCTAssertThrowsError(try CoreLyricsQuery(title: "", artist: "Artist", album: "", duration: 180).requestURL())
    }

    func testSynchronizedResultPreservesActualTimestampsAndRequiresMatchingMetadata() throws {
        let result = try CoreLyricsResult.decode(fixture(["trackName": " fixture song ", "artistName": "FIXTURE ARTIST",
            "duration": 182, "syncedLyrics": "[00:01.25]First line\n[00:03.50]Second line"]), for: query)
        XCTAssertEqual(result.kind, .synced)
        XCTAssertEqual(result.lines.map(\.time), [1.25, 3.5])
        XCTAssertEqual(result.lines.map(\.text), ["First line", "Second line"])
        for changes: [String: Any] in [["trackName": "Different Song"], ["artistName": "Other Artist"], ["duration": 182.01]] {
            XCTAssertThrowsError(try CoreLyricsResult.decode(fixture(changes), for: query)) {
                XCTAssertEqual($0 as? CoreLyricsError, .mismatchedTrack)
            }
        }
    }

    func testPlainInstrumentalAndMissingLyricsNeverInventSynchronization() throws {
        let plain = try CoreLyricsResult.decode(fixture(["syncedLyrics": NSNull(), "plainLyrics": "Words without time tags"]), for: query)
        XCTAssertEqual(plain.kind, .plain)
        XCTAssertEqual(plain.plainLyrics, "Words without time tags")
        XCTAssertTrue(plain.lines.isEmpty)
        let instrumental = try CoreLyricsResult.decode(fixture(["instrumental": true]), for: query)
        XCTAssertEqual(instrumental.kind, .instrumental)
        XCTAssertNil(instrumental.plainLyrics)
        XCTAssertTrue(instrumental.lines.isEmpty)
        XCTAssertThrowsError(try CoreLyricsResult.decode(fixture(["syncedLyrics": NSNull(), "plainLyrics": NSNull()]), for: query)) {
            XCTAssertEqual($0 as? CoreLyricsError, .noLyrics)
        }
        for synced in ["Malformed synchronized lyrics", "[99:59]Outside this song"] {
            XCTAssertThrowsError(try CoreLyricsResult.decode(fixture(["syncedLyrics": synced]), for: query)) {
                XCTAssertEqual($0 as? CoreLyricsError, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try CoreLyricsResult.decode(Data(repeating: 32, count: CoreLyricsResult.maximumResponseBytes + 1), for: query)) {
            XCTAssertEqual($0 as? CoreLyricsError, .oversized)
        }
    }

    private func fixture(_ changes: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["id": 123, "trackName": "Fixture Song", "artistName": "Fixture Artist",
            "albumName": "Fixture Album", "duration": 180, "instrumental": false,
            "plainLyrics": "First line", "syncedLyrics": "[00:01.00]First line"]
        object.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
