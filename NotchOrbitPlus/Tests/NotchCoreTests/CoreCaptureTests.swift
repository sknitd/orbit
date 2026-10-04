import Foundation
import XCTest
@testable import NotchCore

final class CoreCaptureTests: XCTestCase {
    func testReversedRetinaAreaUsesTopLeftDisplayCoordinates() throws {
        let first = try CaptureGeometry.area(startX: 210, startY: 180, endX: 10, endY: 20,
                                             displayWidth: 400, displayHeight: 300)
        let reverse = try CaptureGeometry.area(startX: 10, startY: 20, endX: 210, endY: 180,
                                               displayWidth: 400, displayHeight: 300)
        XCTAssertEqual(first, reverse)
        XCTAssertEqual(first, CaptureArea(x: 10, y: 120, width: 200, height: 160))
        let pixels = try CaptureGeometry.pixels(width: first.width, height: first.height, scale: 2, recording: false)
        XCTAssertEqual(pixels.width, 400); XCTAssertEqual(pixels.height, 320)
    }
    func testAreaClipsToOneDisplayAndRejectsSmallNonfiniteSelections() throws {
        XCTAssertEqual(try CaptureGeometry.area(startX: -20, startY: -10, endX: 500, endY: 400,
                                                displayWidth: 400, displayHeight: 300),
                       CaptureArea(x: 0, y: 0, width: 400, height: 300))
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try CaptureGeometry.area(startX: value, startY: 0, endX: 20, endY: 20,
                                                          displayWidth: 400, displayHeight: 300))
        }
        XCTAssertThrowsError(try CaptureGeometry.area(startX: 0, startY: 0, endX: 7, endY: 20,
                                                      displayWidth: 400, displayHeight: 300))
    }
    func testRecordingFitsH264EvenDimensionsAndKeepsAspect() throws {
        let size = try CaptureGeometry.pixels(width: 3_001, height: 2_001, scale: 2, recording: true)
        XCTAssertEqual(size.width % 2, 0); XCTAssertEqual(size.height % 2, 0)
        XCTAssertLessThanOrEqual(size.width, 3_840); XCTAssertLessThanOrEqual(size.height, 2_160)
        XCTAssertEqual(Double(size.width) / Double(size.height), 3_001.0 / 2_001.0, accuracy: 0.002)
        let screenshot = try CaptureGeometry.pixels(width: 8_000, height: 6_000, scale: 2, recording: false)
        XCTAssertLessThanOrEqual(screenshot.width * screenshot.height, 32_000_000)
        XCTAssertThrowsError(try CaptureGeometry.pixels(width: 100, height: 100, scale: .nan, recording: false))
    }
    func testDurationLimitsAndCaptureIndexRejectTamperedRecords() throws {
        XCTAssertEqual(try CaptureGeometry.duration(1), 1); XCTAssertEqual(try CaptureGeometry.duration(60), 60)
        for duration in [0, 61, Double.nan, .infinity] { XCTAssertThrowsError(try CaptureGeometry.duration(duration)) }
        let record = CaptureShelfRecord(fileURL: URL(fileURLWithPath: "/tmp/record.png"), selection: .area,
                                        width: 16, height: 16, byteCount: 100)
        let encoded = try JSONEncoder().encode(CaptureShelfArchive(records: [record]))
        XCTAssertEqual(try JSONDecoder().decode(CaptureShelfArchive.self, from: encoded).validated().records, [record])
        XCTAssertThrowsError(try CaptureShelfArchive(records: [record, record]).validated())
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureShelfArchive.self,
            from: JSONEncoder().encode(CaptureShelfArchive(records: [record, record]))))
        XCTAssertThrowsError(try CaptureShelfRecord(fileURL: URL(string: "https://example.invalid/record.png")!,
                                                   selection: .display, width: 16, height: 16, byteCount: 100).validated())
    }
}
