import XCTest
@testable import CornerCore

final class CornerGestureRecognizerTests: XCTestCase {
    private func configured() -> CornerSettings {
        var value = CornerSettings(enabled: true, cooldown: 0)
        for corner in Corner.allCases {
            for gesture in [CornerGesture.singleClick, .doubleClick, .tripleClick, .dragIntoCorner, .dragOutOfCorner] { value.corners[corner]?.bindings[gesture] = .init(kind: .finder) }
        }
        return value
    }
    private func point(_ corner: Corner?) -> CornerPoint {
        switch corner {
        case .topLeft: .init(x: 2, y: 998)
        case .topRight: .init(x: 998, y: 998)
        case .bottomLeft: .init(x: 2, y: 2)
        case .bottomRight: .init(x: 998, y: 2)
        case nil: .init(x: 500, y: 500)
        }
    }
    private func event(_ kind: CornerPointerEventKind, _ time: Double, corner: Corner? = .topLeft, screen: String = "A", modifiers: CornerModifiers = [], point custom: CornerPoint? = nil) -> CornerPointerEvent {
        .init(kind: kind, screenID: screen, corner: corner, point: custom ?? point(corner), timestamp: time, modifiers: modifiers)
    }
    private func click(_ recognizer: inout CornerGestureRecognizer, at time: Double, corner: Corner = .topLeft, screen: String = "A", modifiers: CornerModifiers = []) -> [CornerTrigger] {
        recognizer.handle(event(.down, time, corner: corner, screen: screen, modifiers: modifiers)) + recognizer.handle(event(.up, time + 0.04, corner: corner, screen: screen, modifiers: modifiers))
    }
    func testSingleClickWaitsForDoubleAndTripleWindow() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        XCTAssertTrue(click(&recognizer, at: 1).isEmpty)
        XCTAssertEqual(try XCTUnwrap(recognizer.nextDeadline), 1.36, accuracy: 0.00001)
        XCTAssertTrue(recognizer.flush(at: 1.35).isEmpty)
        let result = recognizer.flush(at: 1.37)
        XCTAssertEqual(result.map(\.gesture), [.singleClick]); XCTAssertEqual(result.first?.corner, .topLeft)
        XCTAssertNil(recognizer.nextDeadline); XCTAssertTrue(recognizer.flush(at: 2).isEmpty)
    }
    func testDoubleClickNeverRunsSingleAndWaitsForPossibleThird() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        XCTAssertTrue(click(&recognizer, at: 1).isEmpty)
        XCTAssertTrue(click(&recognizer, at: 1.2).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 1.5).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 1.57).map(\.gesture), [.doubleClick])
        XCTAssertTrue(recognizer.flush(at: 2).isEmpty)
    }
    func testTripleClickRunsOnceAndFourthClickIsSuppressedUntilQuiet() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        XCTAssertTrue(click(&recognizer, at: 1).isEmpty)
        XCTAssertTrue(click(&recognizer, at: 1.1).isEmpty)
        XCTAssertEqual(click(&recognizer, at: 1.2).map(\.gesture), [.tripleClick])
        XCTAssertTrue(click(&recognizer, at: 1.3).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 1.67).isEmpty)
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(click(&recognizer, at: 2).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 2.37).map(\.gesture), [.singleClick])
    }
    func testUnboundTripleCannotFallBackToDoubleOrSingle() throws {
        var settings = configured(); settings.corners[.topLeft]?.bindings[.tripleClick] = CornerAction.none
        var recognizer = try CornerGestureRecognizer(configuration: settings)
        XCTAssertTrue(click(&recognizer, at: 1).isEmpty); XCTAssertTrue(click(&recognizer, at: 1.1).isEmpty)
        XCTAssertTrue(click(&recognizer, at: 1.2).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 1.6).isEmpty)
    }
    func testTripleTailDuringCooldownCannotMakeFifthClickANewSingle() throws {
        var settings = configured(); settings.cooldown = 0.6
        var recognizer = try CornerGestureRecognizer(configuration: settings)
        XCTAssertTrue(click(&recognizer, at: 1).isEmpty)
        XCTAssertTrue(click(&recognizer, at: 1.1).isEmpty)
        XCTAssertEqual(click(&recognizer, at: 1.2).map(\.gesture), [.tripleClick])
        XCTAssertTrue(recognizer.handle(event(.down, 1.5)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 1.6)).isEmpty)
        XCTAssertTrue(click(&recognizer, at: 1.85).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 2.22).isEmpty)
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(click(&recognizer, at: 3).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 3.37).map(\.gesture), [.singleClick])
    }
    func testSecondHeldPressSuspendsDeadlineUntilItsRelease() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        XCTAssertTrue(click(&recognizer, at: 1).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.down, 1.2)).isEmpty)
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.flush(at: 1.9).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 1.91)).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 2.24).map(\.gesture), [.doubleClick])
    }
    func testDifferentCornersAndDisplaysKeepSeparateSequences() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        XCTAssertTrue(click(&recognizer, at: 1, screen: "A").isEmpty)
        XCTAssertTrue(click(&recognizer, at: 1.1, screen: "B").isEmpty)
        XCTAssertTrue(click(&recognizer, at: 1.2, corner: .bottomRight, screen: "A").isEmpty)
        let results = recognizer.flush(at: 1.57)
        XCTAssertEqual(results.map(\.gesture), [.singleClick, .singleClick, .singleClick])
        XCTAssertEqual(results.map(\.screenID), ["A", "B", "A"])
        XCTAssertEqual(results.map(\.corner), [.topLeft, .topLeft, .bottomRight])
    }
    func testDragIntoRequiresRealDragMovementAndRelease() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        XCTAssertTrue(recognizer.handle(event(.down, 1, corner: nil)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 1.1)).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 1.2).isEmpty)
        let result = recognizer.handle(event(.up, 1.3))
        XCTAssertEqual(result.map(\.gesture), [.dragIntoCorner]); XCTAssertEqual(result.first?.point, point(.topLeft))
        XCTAssertTrue(recognizer.handle(event(.up, 1.4)).isEmpty)
    }
    func testDragOutOriginTakesPriorityWhenReleaseEntersAnotherCorner() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        XCTAssertTrue(recognizer.handle(event(.down, 1)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 1.1, corner: .bottomRight, screen: "B")).isEmpty)
        let result = recognizer.handle(event(.up, 1.2, corner: .bottomRight, screen: "B"))
        XCTAssertEqual(result.map(\.gesture), [.dragOutOfCorner]); XCTAssertEqual(result.first?.corner, .topLeft)
        XCTAssertEqual(result.first?.screenID, "A"); XCTAssertTrue(recognizer.flush(at: 2).isEmpty)
    }
    func testDragReturningToItsOriginDoesNotExecuteOrBecomeAClick() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        XCTAssertTrue(recognizer.handle(event(.down, 1)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 1.1, corner: nil)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 1.2)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 1.3)).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 2).isEmpty)
    }
    func testMovementWithoutDragEventsCannotProduceDragAction() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        XCTAssertTrue(recognizer.handle(event(.down, 1, corner: nil)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.moved, 1.1)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 1.2)).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 2).isEmpty)
    }
    func testExactDragThresholdWorksAndSmallMovementRemainsAClick() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        let start = CornerPoint(x: 21, y: 990), end = CornerPoint(x: 33, y: 990)
        XCTAssertTrue(recognizer.handle(event(.down, 1, point: start)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 1.1, corner: nil, point: end)).isEmpty)
        XCTAssertEqual(recognizer.handle(event(.up, 1.2, corner: nil, point: end)).map(\.gesture), [.dragOutOfCorner])
        XCTAssertTrue(recognizer.handle(event(.down, 2, point: start)).isEmpty)
        let small = CornerPoint(x: 22, y: 990)
        XCTAssertTrue(recognizer.handle(event(.dragged, 2.1, point: small)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 2.2, point: small)).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 2.53).map(\.gesture), [.singleClick])
    }
    func testCooldownPreventsRepeatedPressWithoutADeferredSurprise() throws {
        var settings = configured(); settings.cooldown = 0.6
        var recognizer = try CornerGestureRecognizer(configuration: settings)
        XCTAssertTrue(click(&recognizer, at: 1).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 1.37).count, 1)
        XCTAssertTrue(click(&recognizer, at: 1.5).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 1.9).isEmpty)
        XCTAssertTrue(click(&recognizer, at: 2).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 2.37).map(\.gesture), [.singleClick])
    }
    func testRequiredModifiersLossCancelsPendingClickAndDrag() throws {
        var settings = configured(); settings.modifierRequirement = [.control, .option]
        var recognizer = try CornerGestureRecognizer(configuration: settings)
        XCTAssertTrue(click(&recognizer, at: 1, modifiers: [.control, .option]).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.modifiersChanged, 1.1, modifiers: .control)).isEmpty)
        XCTAssertNil(recognizer.nextDeadline); XCTAssertTrue(recognizer.flush(at: 2).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.down, 3, corner: nil, modifiers: [.control, .option])).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 3.1, modifiers: .control)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 3.2, modifiers: [.control, .option])).isEmpty)
        XCTAssertFalse(recognizer.isTrackingPress)
    }
    func testUnselectedDisplayDisabledCornerAndDefaultsCannotTrigger() throws {
        var settings = configured(); settings.enabledDisplayIDs = ["A"]; settings.corners[.bottomRight]?.enabled = false
        var recognizer = try CornerGestureRecognizer(configuration: settings)
        XCTAssertTrue(click(&recognizer, at: 1, screen: "B").isEmpty)
        XCTAssertTrue(click(&recognizer, at: 1.2, corner: .bottomRight).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 2).isEmpty)
        var defaults = try CornerGestureRecognizer()
        XCTAssertTrue(click(&defaults, at: 1).isEmpty); XCTAssertTrue(defaults.flush(at: 2).isEmpty)
    }
    func testResetAndConfigurationUpdateInvalidateOldTimers() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        XCTAssertTrue(click(&recognizer, at: 1).isEmpty)
        recognizer.reset(); XCTAssertNil(recognizer.nextDeadline); XCTAssertTrue(recognizer.flush(at: 2).isEmpty)
        XCTAssertTrue(click(&recognizer, at: 3).isEmpty)
        var disabled = configured(); disabled.enabled = false
        try recognizer.update(configuration: disabled)
        XCTAssertTrue(recognizer.flush(at: 4).isEmpty); XCTAssertNil(recognizer.nextDeadline)
    }
    func testStaleAndInvalidEventsAndVeryLateTimersDoNotExecuteActions() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        XCTAssertTrue(click(&recognizer, at: 10).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.down, 9)).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 10.4).map(\.gesture), [.singleClick])
        XCTAssertTrue(click(&recognizer, at: 20).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 30).isEmpty); XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(click(&recognizer, at: 31).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, .nan)).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 32).isEmpty)
    }
    func testDuplicateDownAndUpEventsDoNotIncreaseClickCount() throws {
        var recognizer = try CornerGestureRecognizer(configuration: configured())
        XCTAssertTrue(recognizer.handle(event(.down, 1)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.down, 1.01)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 1.04)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 1.05)).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 1.37).map(\.gesture), [.singleClick])
    }
}
