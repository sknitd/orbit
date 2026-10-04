import XCTest
@testable import CornerCore

final class CornerGeometryTests: XCTestCase {
    func testAllFourCornersUseAppKitCoordinatesAndHaveCentralDeadRegion() {
        let frame = CornerRect(x: 0, y: 0, width: 1440, height: 900)
        let values: [(CornerPoint, Corner)] = [(.init(x: 0, y: 900), .topLeft), (.init(x: 1440, y: 900), .topRight), (.init(x: 0, y: 0), .bottomLeft), (.init(x: 1440, y: 0), .bottomRight)]
        for (point, corner) in values { XCTAssertEqual(CornerGeometry.corner(at: point, in: frame, size: 24), corner) }
        XCTAssertNil(CornerGeometry.corner(at: .init(x: 720, y: 450), in: frame, size: 24))
        XCTAssertNil(CornerGeometry.corner(at: .init(x: -0.01, y: 0), in: frame, size: 24))
    }
    func testPointBoundariesAreInclusiveAndRetinaIsMeasuredInPoints() {
        let frame = CornerRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(CornerGeometry.corner(at: .init(x: 24, y: 876), in: frame, size: 24), .topLeft)
        XCTAssertNil(CornerGeometry.corner(at: .init(x: 24.01, y: 876), in: frame, size: 24))
        XCTAssertNil(CornerGeometry.corner(at: .init(x: 48, y: 876), in: frame, size: 24))
    }
    func testNegativeOriginAndMultipleDisplaysAreIndependent() {
        let left = CornerScreen(id: "left", frame: .init(x: -1920, y: -200, width: 1920, height: 1080))
        let right = CornerScreen(id: "right", frame: .init(x: 0, y: 0, width: 1440, height: 900))
        let point = CornerPoint(x: -1915, y: 875)
        XCTAssertEqual(CornerGeometry.screen(at: point, among: [right, left])?.id, "left")
        XCTAssertEqual(CornerGeometry.corner(at: point, in: left.frame, size: 24), .topLeft)
        XCTAssertNil(CornerGeometry.corner(at: point, in: right.frame, size: 24))
    }
    func testTinyScreensClampRegionsAndResolveSharedBoundaryOnce() {
        let frame = CornerRect(x: 0, y: 0, width: 8, height: 8)
        XCTAssertEqual(CornerGeometry.region(for: .topLeft, in: frame, size: 24)?.width, 4)
        XCTAssertEqual(CornerGeometry.corner(at: .init(x: 4, y: 4), in: frame, size: 24), .topLeft)
    }
    func testInvalidCoordinatesSizesAndFramesHaveNoHit() {
        let frame = CornerRect(x: 0, y: 0, width: 100, height: 100)
        for size in [0, -1, Double.nan, .infinity] { XCTAssertNil(CornerGeometry.corner(at: .init(x: 0, y: 0), in: frame, size: size)) }
        XCTAssertNil(CornerGeometry.corner(at: .init(x: .nan, y: 0), in: frame, size: 24))
        XCTAssertNil(CornerGeometry.region(for: .topLeft, in: .init(x: 0, y: 0, width: 0, height: 100), size: 24))
        XCTAssertNil(CornerGeometry.region(for: .topLeft, in: .init(x: .infinity, y: 0, width: 100, height: 100), size: 24))
    }
}
