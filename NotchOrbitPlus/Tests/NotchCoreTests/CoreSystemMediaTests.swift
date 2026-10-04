import Foundation
import XCTest
@testable import NotchCore

final class CoreSystemMediaTests: XCTestCase {
    func testRealTimestampRatePositionAndPauseClamp() throws {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let fields = CoreSystemMediaFields(title: " Track ", artist: "Artist", album: "Album",
            duration: 120, elapsed: 30, playbackRate: 1.5, timestamp: timestamp, artwork: Data([1, 2]))
        let playing = try XCTUnwrap(CoreSystemMediaReading(fields: fields, playing: true, now: timestamp.addingTimeInterval(4)))
        XCTAssertEqual(playing.title, "Track"); XCTAssertEqual(playing.position, 36)
        XCTAssertTrue(playing.playing); XCTAssertEqual(playing.artwork, Data([1, 2]))
        let paused = try XCTUnwrap(CoreSystemMediaReading(fields: fields, playing: false, now: timestamp.addingTimeInterval(4)))
        XCTAssertEqual(paused.position, 30); XCTAssertFalse(paused.playing)
        XCTAssertEqual(CoreSystemMediaReading(fields: fields, playing: true, now: timestamp.addingTimeInterval(300))?.position, 120)
        XCTAssertEqual(CoreSystemMediaReading(fields: fields, playing: true, now: timestamp.addingTimeInterval(-10))?.position, 30)
    }
    func testAbsentAndMalformedMetadataCannotInventTrackOrProgress() throws {
        XCTAssertNil(CoreSystemMediaReading(fields: CoreSystemMediaFields(), playing: true, now: Date()))
        XCTAssertNil(CoreSystemMediaReading(fields: CoreSystemMediaFields(title: " \n "), playing: false, now: Date()))
        let fields = CoreSystemMediaFields(title: "Actual title", duration: .nan, elapsed: .infinity,
            playbackRate: -.infinity, artwork: Data(repeating: 1, count: 4_194_305))
        let value = try XCTUnwrap(CoreSystemMediaReading(fields: fields, playing: nil, now: Date()))
        XCTAssertEqual(value.duration, 0); XCTAssertEqual(value.position, 0)
        XCTAssertFalse(value.playing); XCTAssertFalse(value.playbackStateKnown)
        XCTAssertFalse(value.positionAvailable); XCTAssertNil(value.artwork)
        let fallback = CoreSystemMediaFields(title: "Actual title", elapsed: 5, playbackRate: 1)
        XCTAssertEqual(CoreSystemMediaReading(fields: fallback, playing: nil, now: Date())?.position, 5)
        XCTAssertEqual(CoreSystemMediaReading(fields: fallback, playing: nil, now: Date())?.playing, true)
    }
}
