import XCTest
@testable import NotchCore

final class NotchLayoutTests: XCTestCase {
    private func assertFits(_ layout: NotchLayout, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(layout.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(layout.frame.minX, layout.visibleFrame.minX + 12, file: file, line: line)
        XCTAssertLessThanOrEqual(layout.frame.maxX, layout.visibleFrame.maxX - 12, file: file, line: line)
        XCTAssertGreaterThanOrEqual(layout.frame.minY, layout.visibleFrame.minY + 12, file: file, line: line)
        XCTAssertLessThanOrEqual(layout.frame.maxY, layout.visibleFrame.maxY - 6, file: file, line: line)
    }

    func testPhysicalNotchAndMenuBarAreOutsideThePanel() throws {
        let metrics = NotchScreenMetrics(frame: .init(x: 0, y: 0, width: 1512, height: 982),
                                        visibleFrame: .init(x: 0, y: 38, width: 1512, height: 906),
                                        safeTopInset: 32,
                                        auxiliaryLeftFrame: .init(x: 0, y: 950, width: 680, height: 32),
                                        auxiliaryRightFrame: .init(x: 832, y: 950, width: 680, height: 32))
        let layout = NotchLayout(metrics: metrics, screenID: 1)
        let notch = try XCTUnwrap(layout.notchRect)
        XCTAssertEqual(notch, NotchRect(x: 680, y: 950, width: 152, height: 32))
        XCTAssertFalse(layout.frame.intersects(notch))
        XCTAssertFalse(layout.frame.intersects(.init(x: 0, y: 944, width: 1512, height: 38)))
        XCTAssertEqual(layout.anchor.x, 756)
        XCTAssertEqual(layout.anchor.y, 938)
        XCTAssertTrue(layout.activationRegion.contains(.init(x: 756, y: 940)))
        assertFits(layout)
    }

    func testNotchlessScreenHasTopCenterFallbackAndSafeMenuGap() {
        let layout = NotchLayout(metrics: .init(frame: .init(x: 1920, y: 0, width: 1920, height: 1080),
                                                visibleFrame: .init(x: 1920, y: 24, width: 1920, height: 1032)))
        XCTAssertNil(layout.notchRect)
        XCTAssertEqual(layout.anchor.x, 2880)
        XCTAssertEqual(layout.anchor.y, 1050)
        assertFits(layout)
    }

    func testNegativeOriginsAndVerticallyStackedDisplaysFitTheirOwnVisibleFrame() {
        for metrics in [
            NotchScreenMetrics(frame: .init(x: -1920, y: -300, width: 1920, height: 1080),
                               visibleFrame: .init(x: -1920, y: -274, width: 1920, height: 1000)),
            NotchScreenMetrics(frame: .init(x: 0, y: 1080, width: 1600, height: 900),
                               visibleFrame: .init(x: 0, y: 1100, width: 1600, height: 858))
        ] {
            let layout = NotchLayout(metrics: metrics)
            assertFits(layout)
            XCTAssertTrue(metrics.frame.contains(layout.anchor))
            XCTAssertEqual(layout.relativePoint(layout.anchor), .init(x: 0, y: 0))
        }
    }

    func testSmallVisibleScreenScalesBothRenderedAndHitTestBands() {
        let layout = NotchLayout(metrics: .init(frame: .init(x: 0, y: 0, width: 400, height: 250),
                                                visibleFrame: .init(x: 60, y: 20, width: 250, height: 200)))
        XCTAssertLessThan(layout.scale, 1)
        XCTAssertGreaterThan(layout.scale, 0)
        assertFits(layout)
        for index in 0..<8 {
            let angle = (Double(index) + 0.5) * .pi / 8
            let local = NotchPoint(x: -cos(angle) * 140 * layout.scale, y: -sin(angle) * 140 * layout.scale)
            let global = NotchPoint(x: layout.anchor.x + local.x, y: layout.anchor.y + local.y)
            XCTAssertTrue(layout.frame.contains(global))
            XCTAssertEqual(layout.geometry.primarySlot(at: layout.relativePoint(global)), index)
        }
    }

    func testEveryOptionCenterFitsPanelAndAvoidsPhysicalNotch() {
        let layout = NotchLayout(metrics: .init(frame: .init(x: 0, y: 0, width: 1512, height: 982),
                                                visibleFrame: .init(x: 0, y: 38, width: 1512, height: 906), safeTopInset: 32))
        for count in [1, 4, 6, 10] {
            for index in 0..<count {
                let angle = (Double(index) + 0.5) * .pi / Double(count)
                let point = NotchPoint(x: layout.anchor.x - cos(angle) * 230 * layout.scale,
                                       y: layout.anchor.y - sin(angle) * 230 * layout.scale)
                XCTAssertTrue(layout.frame.contains(point))
                XCTAssertFalse(layout.notchRect?.contains(point) ?? false)
                XCTAssertEqual(layout.geometry.optionIndex(at: layout.relativePoint(point), count: count), index)
            }
        }
    }

    func testTransportRegionConnectsActivationTargetToLowestVisibleOption() {
        let layout = NotchLayout(metrics: .init(frame: .init(x: 0, y: 0, width: 1920, height: 1080),
                                                visibleFrame: .init(x: 0, y: 24, width: 1920, height: 1032)))
        for offset in stride(from: 0.0, through: 270.0, by: 10) {
            XCTAssertTrue(layout.activeRegion.contains(.init(x: layout.anchor.x, y: layout.anchor.y - offset)))
        }
    }
}
