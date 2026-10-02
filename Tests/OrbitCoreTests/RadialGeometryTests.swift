import XCTest
@testable import OrbitCore

final class RadialGeometryTests: XCTestCase {
    func testEveryWedgeCenterForFourSixEightAndTenActions() {
        for count in [4, 6, 8, 10] {
            let geometry = RadialGeometry(slotCount: count)
            for index in 0..<count {
                let angle = Double(index) * 2 * .pi / Double(count)
                let point = RadialPoint(x: sin(angle) * 85, y: cos(angle) * 85)
                XCTAssertEqual(geometry.primarySlot(at: point), index,
                               "Wrong clockwise wedge for \(count) actions at \(index)")
            }
        }
    }

    func testCardinalDirectionsUseAppKitCoordinates() {
        let geometry = RadialGeometry(slotCount: 8)
        XCTAssertEqual(geometry.primarySlot(at: .init(x: 0, y: 85)), 0)
        XCTAssertEqual(geometry.primarySlot(at: .init(x: 85, y: 0)), 2)
        XCTAssertEqual(geometry.primarySlot(at: .init(x: 0, y: -85)), 4)
        XCTAssertEqual(geometry.primarySlot(at: .init(x: -85, y: 0)), 6)
    }

    func testAngularBoundaryChoosesAdjacentWedge() {
        let geometry = RadialGeometry(slotCount: 8)
        let boundary = Double.pi / 8
        XCTAssertEqual(geometry.primarySlot(at: RadialGeometry.point(radius: 85, angle: boundary - 0.0001)), 0)
        XCTAssertEqual(geometry.primarySlot(at: RadialGeometry.point(radius: 85, angle: boundary + 0.0001)), 1)
        XCTAssertEqual(geometry.primarySlot(at: RadialGeometry.point(radius: 85, angle: -boundary - 0.0001)), 7)
        XCTAssertEqual(geometry.primarySlot(at: RadialGeometry.point(radius: 85, angle: -boundary + 0.0001)), 0)
    }

    func testAnnulusBoundariesAndInactiveGap() {
        let geometry = RadialGeometry()
        XCTAssertNil(geometry.primarySlot(at: .init(x: 0, y: 0)))
        XCTAssertNil(geometry.primarySlot(at: .init(x: 0, y: 61.99)))
        XCTAssertEqual(geometry.primarySlot(at: .init(x: 0, y: 62)), 0)
        XCTAssertEqual(geometry.primarySlot(at: .init(x: 0, y: 113)), 0)
        XCTAssertNil(geometry.primarySlot(at: .init(x: 0, y: 118)))
        XCTAssertNil(geometry.optionIndex(at: .init(x: 0, y: 118), count: 4, anchorSlot: 0))
        XCTAssertEqual(geometry.optionIndex(at: .init(x: 0, y: 123), count: 4, anchorSlot: 0), 0)
        XCTAssertEqual(geometry.optionIndex(at: .init(x: 0, y: 187), count: 4, anchorSlot: 0), 0)
        XCTAssertNil(geometry.optionIndex(at: .init(x: 0, y: 188), count: 4, anchorSlot: 0))
    }

    func testOuterRingIsAnchoredToChosenPrimaryWedge() {
        let geometry = RadialGeometry(slotCount: 8)
        for anchor in 0..<8 {
            for option in 0..<4 {
                let angle = Double(anchor) * .pi / 4 + Double(option) * .pi / 2
                let point = RadialPoint(x: sin(angle) * 155, y: cos(angle) * 155)
                XCTAssertEqual(geometry.optionIndex(at: point, count: 4, anchorSlot: anchor), option)
            }
        }
    }

    func testInvalidAndNonfiniteCoordinatesNeverSelect() {
        let geometry = RadialGeometry()
        XCTAssertNil(geometry.primarySlot(at: .init(x: .nan, y: 85)))
        XCTAssertNil(geometry.primarySlot(at: .init(x: 0, y: .infinity)))
        XCTAssertNil(RadialGeometry.sectorIndex(at: .init(x: 0, y: 0), count: 8))
        XCTAssertNil(RadialGeometry.sectorIndex(at: .init(x: 1, y: 0), count: 0))
        XCTAssertNil(geometry.optionIndex(at: .init(x: 0, y: 150), count: 4, anchorSlot: 8))
    }

    func testRetinaPhysicalCoordinatesMapToSameLogicalSelection() {
        let geometry = RadialGeometry()
        for scale in [1.0, 2.0, 3.0] {
            let physical = RadialPoint(x: 85 * scale, y: 0)
            let logical = RadialPoint(x: physical.x / scale, y: physical.y / scale)
            XCTAssertEqual(geometry.primarySlot(at: logical), 2)
        }
    }

    func testCenterAndCornersStayWithinEachDisplay() {
        for screen in [RadialRect(x: 0, y: 24, width: 1440, height: 850),
                       RadialRect(x: -1920, y: -100, width: 1920, height: 1080),
                       RadialRect(x: 1440, y: 800, width: 1200, height: 900)] {
            let centers = [RadialPoint(x: screen.x, y: screen.y),
                           RadialPoint(x: screen.x + screen.width, y: screen.y),
                           RadialPoint(x: screen.x, y: screen.y + screen.height),
                           RadialPoint(x: screen.x + screen.width, y: screen.y + screen.height),
                           RadialPoint(x: screen.x + screen.width / 2, y: screen.y + screen.height / 2)]
            for center in centers {
                let frame = RadialGeometry.clampedFrame(center: center, size: .init(width: 460, height: 460),
                                                        visibleFrame: screen)
                XCTAssertGreaterThanOrEqual(frame.x, screen.x + 12)
                XCTAssertGreaterThanOrEqual(frame.y, screen.y + 12)
                XCTAssertLessThanOrEqual(frame.x + frame.width, screen.x + screen.width - 12)
                XCTAssertLessThanOrEqual(frame.y + frame.height, screen.y + screen.height - 12)
                XCTAssertEqual(frame.width, 460)
                XCTAssertEqual(frame.height, 460)
            }
        }
    }

    func testOversizedWheelShrinksToFitSmallVisibleScreen() {
        let frame = RadialGeometry.clampedFrame(center: .init(x: 50, y: 50),
                                                size: .init(width: 460, height: 460),
                                                visibleFrame: .init(x: 10, y: 20, width: 200, height: 150))
        XCTAssertEqual(frame, RadialRect(x: 22, y: 32, width: 176, height: 126))
    }
}
