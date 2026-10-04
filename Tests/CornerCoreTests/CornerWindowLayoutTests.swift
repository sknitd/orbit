import XCTest
@testable import CornerCore

final class CornerWindowLayoutTests: XCTestCase {
    private let primary = CornerRect(x: 0, y: 0, width: 1440, height: 900)
    private var main: CornerWindowDisplay {
        .init(id: "main", frame: primary, visibleFrame: .init(x: 0, y: 48, width: 1440, height: 827))
    }
    func testAXConversionRoundTripsNegativeOriginsAndAbovePrimaryInPoints() throws {
        for global in [CornerRect(x: -1800, y: -120, width: 640, height: 480),
                       CornerRect(x: 300, y: 980, width: 500, height: 350)] {
            let ax = try CornerWindowLayout.accessibilityRect(fromGlobal: global, primary: primary)
            XCTAssertEqual(ax.width, global.width); XCTAssertEqual(ax.height, global.height)
            XCTAssertEqual(ax.y, primary.maxY - global.maxY)
            XCTAssertEqual(try CornerWindowLayout.globalRect(fromAccessibility: ax, primary: primary), global)
        }
        let offsetPrimary = CornerRect(x: 40, y: -80, width: 1440, height: 900)
        let global = CornerRect(x: 100, y: 100, width: 400, height: 300)
        let ax = try CornerWindowLayout.accessibilityRect(fromGlobal: global, primary: offsetPrimary)
        XCTAssertEqual(ax, .init(x: 60, y: 420, width: 400, height: 300))
        XCTAssertEqual(try CornerWindowLayout.globalRect(fromAccessibility: ax, primary: offsetPrimary), global)
    }
    func testHalfAndMaximizeExcludeActualDockAndMenuBarVisibleArea() throws {
        let window = CornerRect(x: 200, y: 200, width: 500, height: 400)
        XCTAssertEqual(try CornerWindowLayout.target(.left, window: window, displays: [main]), .init(x: 0, y: 48, width: 720, height: 827))
        XCTAssertEqual(try CornerWindowLayout.target(.right, window: window, displays: [main]), .init(x: 720, y: 48, width: 720, height: 827))
        XCTAssertEqual(try CornerWindowLayout.target(.maximize, window: window, displays: [main]), main.visibleFrame)
    }
    func testCenterRetainsSizeIncludingOversizedWindows() throws {
        let window = CornerRect(x: 100, y: 100, width: 1600, height: 1000)
        let target = try CornerWindowLayout.target(.center, window: window, displays: [main])
        XCTAssertEqual(target.width, window.width); XCTAssertEqual(target.height, window.height)
        XCTAssertEqual(target.x, -80); XCTAssertEqual(target.y, -38.5)
    }
    func testNextDisplayPreservesNormalizedCenterAndCyclesConnectedOrder() throws {
        let first = CornerWindowDisplay(id: "first", frame: .init(x: 0, y: 0, width: 1000, height: 800), visibleFrame: .init(x: 0, y: 0, width: 1000, height: 800))
        let second = CornerWindowDisplay(id: "second", frame: .init(x: -2000, y: 100, width: 2000, height: 1200), visibleFrame: .init(x: -2000, y: 100, width: 2000, height: 1200))
        let original = CornerRect(x: 650, y: 100, width: 200, height: 200)
        let moved = try CornerWindowLayout.target(.nextDisplay, window: original, displays: [first, second])
        XCTAssertEqual(moved, .init(x: -600, y: 300, width: 200, height: 200))
        XCTAssertEqual(try CornerWindowLayout.target(.nextDisplay, window: moved, displays: [first, second]), original)
        let oversized = CornerRect(x: 0, y: 0, width: 2200, height: 1400)
        let next = try CornerWindowLayout.target(.nextDisplay, window: oversized, displays: [first, second])
        // The next display centers oversized dimensions without resizing them.
        XCTAssertEqual(next, .init(x: -2100, y: 0, width: 2200, height: 1400))
    }
    func testLargestIntersectionDeterminesCurrentDisplayAndSmallDestinationClamps() throws {
        let left = CornerWindowDisplay(id: "left", frame: .init(x: -1000, y: 0, width: 1000, height: 800), visibleFrame: .init(x: -1000, y: 0, width: 1000, height: 800))
        let right = CornerWindowDisplay(id: "right", frame: .init(x: 0, y: 0, width: 500, height: 400), visibleFrame: .init(x: 0, y: 0, width: 500, height: 400))
        let spanning = CornerRect(x: -600, y: 150, width: 800, height: 250)
        XCTAssertEqual(try CornerWindowLayout.display(for: spanning, among: [right, left]).id, "left")
        let moved = try CornerWindowLayout.target(.nextDisplay, window: spanning, displays: [left, right])
        XCTAssertEqual(moved.width, 800); XCTAssertEqual(moved.x, -150)
        XCTAssertGreaterThanOrEqual(moved.y, right.visibleFrame.minY)
        XCTAssertLessThanOrEqual(moved.maxY, right.visibleFrame.maxY)
    }
    func testInvalidOrMissingDisplayGeometryFailsBeforeProducingTargets() {
        let window = CornerRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertThrowsError(try CornerWindowLayout.target(.left, window: window, displays: []))
        XCTAssertThrowsError(try CornerWindowLayout.target(.nextDisplay, window: window, displays: [main]))
        XCTAssertThrowsError(try CornerWindowLayout.target(.left, window: window, displays: [main, main]))
        XCTAssertThrowsError(try CornerWindowLayout.accessibilityRect(fromGlobal: .init(x: .nan, y: 0, width: 10, height: 10), primary: primary))
        XCTAssertFalse(CornerWindowLayout.approximatelyEqual(window, window, tolerance: .infinity))
    }
}
