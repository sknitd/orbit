import XCTest
@testable import NotchCore

final class NotchGeometryTests: XCTestCase {
    func testFourSixEightAndTenWedgeCentersRunFromLeftToRightBelowAnchor() {
        for count in [4, 6, 8, 10] {
            let geometry = NotchGeometry(slotCount: count)
            for index in 0..<count {
                let angle = (Double(index) + 0.5) * .pi / Double(count)
                let point = NotchPoint(x: -cos(angle) * 140, y: -sin(angle) * 140)
                XCTAssertEqual(geometry.primarySlot(at: point), index)
                XCTAssertLessThan(point.y, 0)
            }
        }
    }

    func testAboveAnchorEndpointsCenterAndInterRingGapAreNotActions() {
        let geometry = NotchGeometry()
        for point in [NotchPoint(x: 0, y: 0), .init(x: 0, y: 140),
                      .init(x: -140, y: 0), .init(x: 140, y: 0),
                      .init(x: 0, y: -100), .init(x: 0, y: -176), .init(x: 0, y: -281)] {
            XCTAssertNil(geometry.primarySlot(at: point))
            XCTAssertNil(geometry.optionIndex(at: point, count: 3))
        }
    }

    func testPrimaryRadialBoundsAreInclusiveAndTheirNeighborsAreInactive() {
        let geometry = NotchGeometry(slotCount: 3)
        XCTAssertNil(geometry.primarySlot(at: .init(x: 0, y: -107.99)))
        XCTAssertEqual(geometry.primarySlot(at: .init(x: 0, y: -108)), 1)
        XCTAssertEqual(geometry.primarySlot(at: .init(x: 0, y: -170)), 1)
        XCTAssertNil(geometry.primarySlot(at: .init(x: 0, y: -170.01)))
    }

    func testAngularSeparatorsCannotAccidentallyChooseAnAdjacentAction() {
        let geometry = NotchGeometry()
        let boundary = Double.pi / 8
        for delta in [-0.0109, 0, 0.0109] {
            let angle = boundary + delta
            XCTAssertNil(geometry.primarySlot(at: .init(x: -cos(angle) * 140, y: -sin(angle) * 140)))
        }
        let before = boundary - 0.0111
        let after = boundary + 0.0111
        XCTAssertEqual(geometry.primarySlot(at: .init(x: -cos(before) * 140, y: -sin(before) * 140)), 0)
        XCTAssertEqual(geometry.primarySlot(at: .init(x: -cos(after) * 140, y: -sin(after) * 140)), 1)
    }

    func testOuterRingUsesItsActualOptionCount() {
        let geometry = NotchGeometry()
        for count in [1, 2, 3, 5, 10] {
            for option in 0..<count {
                let angle = (Double(option) + 0.5) * .pi / Double(count)
                let point = NotchPoint(x: -cos(angle) * 230, y: -sin(angle) * 230)
                XCTAssertEqual(geometry.optionIndex(at: point, count: count), option)
                XCTAssertNil(geometry.primarySlot(at: point))
            }
        }
    }

    func testNonfinitePointsAndInvalidBandsNeverSelect() {
        let geometry = NotchGeometry()
        for point in [NotchPoint(x: .nan, y: -140), .init(x: 0, y: -.infinity)] {
            XCTAssertNil(geometry.primarySlot(at: point))
            XCTAssertNil(geometry.optionIndex(at: point, count: 3))
        }
        XCTAssertNil(NotchGeometry(primaryInnerRadius: 0).primarySlot(at: .init(x: 0, y: -140)))
        XCTAssertNil(NotchGeometry(primaryInnerRadius: 170, primaryOuterRadius: 108).primarySlot(at: .init(x: 0, y: -140)))
        XCTAssertNil(NotchGeometry.sectorIndex(at: .init(x: 0, y: -140), count: 0))
    }
}
