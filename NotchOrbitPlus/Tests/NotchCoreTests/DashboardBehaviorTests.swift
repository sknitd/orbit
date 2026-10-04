import XCTest
@testable import NotchCore

final class DashboardBehaviorTests: XCTestCase {
    func testDisplayRulesRejectNonfiniteWidthsAndInvalidDisplayIdentities() throws {
        try DashboardBehavior.validate(["7": .init(width: 560), "19": .init(enabled: false, width: 800)])
        for width in [Double.nan, .infinity, 559, 801] {
            XCTAssertThrowsError(try DashboardDisplayRule(width: width).validated())
        }
        for id in ["", "07", "-1", "4294967296", "external"] {
            XCTAssertThrowsError(try DashboardBehavior.validate([id: .init()]))
        }
    }
    func testFullscreenPolicyRequiresPermissionAndTheSameDisplay() {
        XCTAssertTrue(DashboardBehavior.shouldHideFullscreen(enabled: true, accessibilityAvailable: true,
            isFullscreen: true, windowDisplayID: 7, panelDisplayID: 7))
        for (enabled, allowed, fullscreen, window, panel) in [
            (false, true, true, UInt32(7), UInt32(7)), (true, false, true, 7, 7),
            (true, true, false, 7, 7), (true, true, true, 8, 7)
        ] {
            XCTAssertFalse(DashboardBehavior.shouldHideFullscreen(enabled: enabled, accessibilityAvailable: allowed,
                isFullscreen: fullscreen, windowDisplayID: window, panelDisplayID: panel))
        }
        XCTAssertFalse(DashboardBehavior.shouldHideFullscreen(enabled: true, accessibilityAvailable: true,
            isFullscreen: true, windowDisplayID: nil, panelDisplayID: nil))
    }
    func testKeyboardNavigationWrapsOnlyThroughVisibleTools() {
        let visible = ["capture", "worldClock", "timers"]
        XCTAssertEqual(DashboardBehavior.neighboringTool(current: "capture", orderedVisibleIDs: visible, offset: -1), "timers")
        XCTAssertEqual(DashboardBehavior.neighboringTool(current: "timers", orderedVisibleIDs: visible, offset: 1), "capture")
        XCTAssertNil(DashboardBehavior.neighboringTool(current: "timers", orderedVisibleIDs: [], offset: 1))
        XCTAssertNil(DashboardBehavior.neighboringTool(current: "timers", orderedVisibleIDs: visible, offset: Int.min))
    }
}
