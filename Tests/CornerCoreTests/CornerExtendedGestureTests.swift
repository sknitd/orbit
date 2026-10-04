import Foundation
import XCTest
@testable import CornerCore

final class CornerExtendedGestureTests: XCTestCase {
    private func settings(_ gestures: [CornerGesture], cooldown: Double = 0) -> CornerSettings {
        var value = CornerSettings(enabled: true, clickInterval: 0.2, cooldown: cooldown, hoverDelay: 0.5, holdDelay: 0.5)
        for corner in Corner.allCases {
            for gesture in gestures { value.corners[corner]?.bindings[gesture] = .init(kind: .finder) }
        }
        return value
    }
    private func event(_ kind: CornerPointerEventKind, _ time: Double, corner: Corner? = .topLeft,
                       modifiers: CornerModifiers = [], point: CornerPoint = .init(x: 2, y: 598), screen: String = "A") -> CornerPointerEvent {
        .init(kind: kind, screenID: screen, corner: corner, point: point, timestamp: time, modifiers: modifiers)
    }
    private func click(_ recognizer: inout CornerGestureRecognizer, at time: Double, right: Bool = false, corner: Corner = .topLeft) -> [CornerTrigger] {
        recognizer.handle(event(right ? .rightDown : .down, time, corner: corner)) + recognizer.handle(event(right ? .rightUp : .up, time + 0.02, corner: corner))
    }
    func testRightSingleDoubleTripleDisambiguationAtEveryCorner() throws {
        for corner in Corner.allCases {
            var recognizer = try CornerGestureRecognizer(configuration: settings([.rightClick, .rightDoubleClick, .rightTripleClick]))
            XCTAssertTrue(click(&recognizer, at: 1, right: true, corner: corner).isEmpty)
            XCTAssertEqual(recognizer.flush(at: 1.23).map(\.gesture), [.rightClick])
            XCTAssertTrue(click(&recognizer, at: 2, right: true, corner: corner).isEmpty)
            XCTAssertTrue(click(&recognizer, at: 2.1, right: true, corner: corner).isEmpty)
            XCTAssertEqual(recognizer.flush(at: 2.33).map(\.gesture), [.rightDoubleClick])
            XCTAssertTrue(click(&recognizer, at: 3, right: true, corner: corner).isEmpty)
            XCTAssertTrue(click(&recognizer, at: 3.1, right: true, corner: corner).isEmpty)
            XCTAssertEqual(click(&recognizer, at: 3.2, right: true, corner: corner).map(\.gesture), [.rightTripleClick])
            XCTAssertTrue(click(&recognizer, at: 3.3, right: true, corner: corner).isEmpty)
            XCTAssertTrue(recognizer.flush(at: 3.6).isEmpty)
        }
    }
    func testInterleavedRightAndLeftClicksRemainSeparateFamilies() throws {
        var recognizer = try CornerGestureRecognizer(configuration: settings([.singleClick, .doubleClick, .rightClick, .rightDoubleClick]))
        XCTAssertTrue(click(&recognizer, at: 1).isEmpty)
        XCTAssertTrue(click(&recognizer, at: 1.05, right: true).isEmpty)
        XCTAssertTrue(click(&recognizer, at: 1.1).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 1.34).map(\.gesture), [.rightClick, .doubleClick])
    }
    func testRightHeldSecondPressSuspendsItsOwnDeadlineOnly() throws {
        var recognizer = try CornerGestureRecognizer(configuration: settings([.singleClick, .rightClick, .rightDoubleClick]))
        XCTAssertTrue(click(&recognizer, at: 1, right: true).isEmpty)
        XCTAssertTrue(click(&recognizer, at: 1.05).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.rightDown, 1.1)).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 1.3).map(\.gesture), [.singleClick])
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.handle(event(.rightUp, 1.5)).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 1.71).map(\.gesture), [.rightDoubleClick])
    }
    func testMiddleClickRequiresItsOwnReleaseAndCannotMakeLeftDrag() throws {
        var recognizer = try CornerGestureRecognizer(configuration: settings([.middleClick, .dragOutOfCorner, .dragIntoCorner]))
        XCTAssertTrue(recognizer.handle(event(.middleDown, 1)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 1.1)).isEmpty)
        XCTAssertEqual(recognizer.handle(event(.middleUp, 1.2)).map(\.gesture), [.middleClick])
        XCTAssertTrue(recognizer.handle(event(.middleDown, 2)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.middleDragged, 2.1, corner: nil, point: .init(x: 200, y: 300))).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.middleUp, 2.2, corner: nil, point: .init(x: 200, y: 300))).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.rightDown, 3)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.rightDragged, 3.1, corner: nil, point: .init(x: 200, y: 300))).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.rightUp, 3.2, corner: nil, point: .init(x: 200, y: 300))).isEmpty)
    }
    func testHoverRunsOncePerEntryAndDoesNotPollWhenUnbound() throws {
        var recognizer = try CornerGestureRecognizer(configuration: settings([.hover]))
        XCTAssertTrue(recognizer.handle(event(.moved, 1)).isEmpty)
        XCTAssertEqual(recognizer.nextDeadline, 1.5)
        XCTAssertTrue(recognizer.flush(at: 1.49).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 1.5).map(\.gesture), [.hover])
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.handle(event(.moved, 2)).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 2.6).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.moved, 3, corner: nil)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.moved, 3.1)).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 3.61).map(\.gesture), [.hover])
        var unbound = try CornerGestureRecognizer(configuration: CornerSettings(enabled: true))
        XCTAssertTrue(unbound.handle(event(.moved, 1)).isEmpty); XCTAssertNil(unbound.nextDeadline)
    }
    func testLeavingAtHoverDeadlineAndClickingCancelDwell() throws {
        var recognizer = try CornerGestureRecognizer(configuration: settings([.hover, .singleClick]))
        XCTAssertTrue(recognizer.handle(event(.moved, 1)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.moved, 1.5, corner: nil)).isEmpty)
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.handle(event(.moved, 2)).isEmpty)
        XCTAssertTrue(click(&recognizer, at: 2.1).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 2.33).map(\.gesture), [.singleClick])
        XCTAssertTrue(recognizer.flush(at: 3).isEmpty)
    }
    func testHoldFiresWhilePressedThenSuppressesReleaseAndDrag() throws {
        var recognizer = try CornerGestureRecognizer(configuration: settings([.longPress, .singleClick, .dragOutOfCorner]))
        XCTAssertTrue(recognizer.handle(event(.down, 1)).isEmpty)
        XCTAssertEqual(recognizer.nextDeadline, 1.5)
        XCTAssertEqual(recognizer.flush(at: 1.5).map(\.gesture), [.longPress])
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.handle(event(.dragged, 1.6, corner: nil, point: .init(x: 200, y: 300))).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 1.7, corner: nil, point: .init(x: 200, y: 300))).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 2).isEmpty)
        XCTAssertFalse(recognizer.isTrackingPress)
    }
    func testShortHoldRemainsClickAndMovementBeforeDeadlineCancelsHold() throws {
        var recognizer = try CornerGestureRecognizer(configuration: settings([.longPress, .singleClick, .dragOutOfCorner]))
        XCTAssertTrue(click(&recognizer, at: 1).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 1.23).map(\.gesture), [.singleClick])
        XCTAssertTrue(recognizer.handle(event(.down, 2)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 2.5, corner: nil, point: .init(x: 200, y: 300))).isEmpty)
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertEqual(recognizer.handle(event(.up, 2.6, corner: nil, point: .init(x: 200, y: 300))).map(\.gesture), [.dragOutOfCorner])
    }
    func testStaleHoverAndHoldDeadlinesNeverRunLaterActions() throws {
        var recognizer = try CornerGestureRecognizer(configuration: settings([.hover, .longPress, .singleClick]))
        XCTAssertTrue(recognizer.handle(event(.moved, 1)).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 3).isEmpty); XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.handle(event(.down, 4)).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 6).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 6.1)).isEmpty)
        XCTAssertTrue(recognizer.flush(at: 6.4).isEmpty)
    }
    func testScrollUsesChosenDirectionAndCooldownWithoutTimer() throws {
        var recognizer = try CornerGestureRecognizer(configuration: settings([.scrollUp, .scrollDown], cooldown: 0.5))
        XCTAssertEqual(recognizer.handle(event(.scrollUp, 1)).map(\.gesture), [.scrollUp])
        XCTAssertTrue(recognizer.handle(event(.scrollDown, 1.1)).isEmpty)
        XCTAssertEqual(recognizer.handle(event(.scrollDown, 1.5)).map(\.gesture), [.scrollDown])
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.handle(event(.scrollUp, 2, corner: nil)).isEmpty)
    }
    func testCornerModifierOverrideCanRequireNoneAndCancelsOnlyIneligibleWork() throws {
        var value = settings([.singleClick, .hover]); value.modifierRequirement = .shift
        value.corners[.topLeft]?.modifierRequirement = []
        value.corners[.topRight]?.modifierRequirement = .option
        var recognizer = try CornerGestureRecognizer(configuration: value)
        XCTAssertTrue(click(&recognizer, at: 1).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.down, 1.1, corner: .topRight, modifiers: .option)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 1.12, corner: .topRight, modifiers: .option)).isEmpty)
        let results = recognizer.handle(event(.modifiersChanged, 1.3, modifiers: []))
        XCTAssertEqual(results.map(\.gesture), [.singleClick]); XCTAssertEqual(results.first?.corner, .topLeft)
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.handle(event(.moved, 2, corner: .topRight, modifiers: .option)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.modifiersChanged, 2.1, modifiers: [])).isEmpty)
        XCTAssertNil(recognizer.nextDeadline)
    }
    func testHoverModifierLossCannotRearmTheSamePhysicalEntry() throws {
        var value = settings([.hover]); value.modifierRequirement = .shift
        var recognizer = try CornerGestureRecognizer(configuration: value)
        XCTAssertTrue(recognizer.handle(event(.moved, 1, modifiers: .shift)).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 1.5).map(\.gesture), [.hover])
        XCTAssertTrue(recognizer.handle(event(.moved, 1.6, modifiers: [])).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.moved, 1.7, modifiers: .shift)).isEmpty)
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.flush(at: 2.2).isEmpty, "Restoring modifiers does not reenter the corner")
        XCTAssertTrue(recognizer.handle(event(.moved, 3, corner: nil, modifiers: .shift)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.moved, 3.1, modifiers: .shift)).isEmpty)
        XCTAssertEqual(recognizer.flush(at: 3.61).map(\.gesture), [.hover])
        XCTAssertTrue(recognizer.handle(event(.moved, 4, corner: nil, modifiers: .shift)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.moved, 4.1, modifiers: .shift)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.modifiersChanged, 4.2, modifiers: [])).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.moved, 4.3, modifiers: .shift)).isEmpty)
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.flush(at: 5).isEmpty, "A canceled pending dwell requires a fresh entry")
    }
    func testOutsideDragRequiresDestinationModifiersContinuouslyAcrossMixedOverrides() throws {
        var value = settings([.dragIntoCorner]); value.modifierRequirement = .shift
        value.corners[.bottomRight]?.modifierRequirement = []
        var recognizer = try CornerGestureRecognizer(configuration: value)
        let outside = CornerPoint(x: 400, y: 300), travel = CornerPoint(x: 300, y: 400)
        XCTAssertTrue(recognizer.handle(event(.down, 1, corner: nil, modifiers: .shift, point: outside)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 1.1, corner: nil, modifiers: [], point: travel)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 1.2, modifiers: .shift)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.up, 1.3, modifiers: .shift)).isEmpty,
                      "An unrelated zero-key corner must not authorize a destination whose key was released")
        XCTAssertTrue(recognizer.handle(event(.down, 2, corner: nil, modifiers: .shift, point: outside)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 2.1, corner: nil, modifiers: [], point: travel)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 2.2, corner: .bottomRight, modifiers: [])).isEmpty)
        let noKeys = recognizer.handle(event(.up, 2.3, corner: .bottomRight, modifiers: []))
        XCTAssertEqual(noKeys.map(\.gesture), [.dragIntoCorner]); XCTAssertEqual(noKeys.first?.corner, .bottomRight)
        XCTAssertTrue(recognizer.handle(event(.down, 3, corner: nil, modifiers: [.shift, .option], point: outside)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 3.1, corner: nil, modifiers: .shift, point: travel)).isEmpty)
        XCTAssertTrue(recognizer.handle(event(.dragged, 3.2, modifiers: .shift)).isEmpty)
        let held = recognizer.handle(event(.up, 3.3, modifiers: .shift))
        XCTAssertEqual(held.map(\.gesture), [.dragIntoCorner]); XCTAssertEqual(held.first?.corner, .topLeft)
    }

    func testDisabledSettingsResetCancelsEveryNewGestureDeadline() throws {
        var value = settings([.hover, .longPress, .rightClick])
        var recognizer = try CornerGestureRecognizer(configuration: value)
        XCTAssertTrue(recognizer.handle(event(.moved, 1)).isEmpty)
        recognizer.reset(); XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.handle(event(.down, 2)).isEmpty)
        value.enabled = false; try recognizer.update(configuration: value)
        XCTAssertNil(recognizer.nextDeadline); XCTAssertTrue(recognizer.flush(at: 3).isEmpty)
    }
    func testPracticeRuntimePolicyRecognizesUnassignedWithoutChangingBindings() throws {
        let value = CornerSettings(enabled: true, cooldown: 0)
        var recognizer = try CornerGestureRecognizer(configuration: value, recognizeUnassigned: true)
        XCTAssertEqual(recognizer.handle(event(.scrollUp, 1)).map(\.gesture), [.scrollUp])
        XCTAssertTrue(recognizer.handle(event(.middleDown, 2)).isEmpty)
        XCTAssertEqual(recognizer.handle(event(.middleUp, 2.1)).map(\.gesture), [.middleClick])
        XCTAssertEqual(recognizer.configuration, value)
        XCTAssertTrue(recognizer.configuration.corners.values.allSatisfy { $0.bindings.values.allSatisfy { $0 == .none } })
        var normal = try CornerGestureRecognizer(configuration: value)
        XCTAssertTrue(normal.handle(event(.scrollUp, 1)).isEmpty)
        XCTAssertTrue(click(&normal, at: 2).isEmpty)
        XCTAssertNil(normal.nextDeadline, "An unbound click family needs no one-shot timer")
        XCTAssertTrue(normal.handle(event(.down, 3, corner: nil, point: .init(x: 400, y: 300))).isEmpty)
        XCTAssertTrue(normal.handle(event(.dragged, 3.1)).isEmpty)
        XCTAssertTrue(normal.handle(event(.up, 3.2)).isEmpty)
    }
    func testPerCornerHotZonesRespectIndependentSizeAndNegativeDisplays() {
        let frame = CornerRect(x: -800, y: -100, width: 800, height: 600)
        var value = CornerSettings(cornerSize: 24)
        value.corners[.topLeft]?.cornerSize = 80; value.corners[.bottomLeft]?.cornerSize = 8
        XCTAssertEqual(CornerGeometry.corner(at: .init(x: -750, y: 450), in: frame, configuration: value), .topLeft)
        XCTAssertNil(CornerGeometry.corner(at: .init(x: -750, y: -50), in: frame, configuration: value))
        XCTAssertEqual(CornerGeometry.corner(at: .init(x: -796, y: -96), in: frame, configuration: value), .bottomLeft)
        XCTAssertNil(CornerGeometry.corner(at: .init(x: -790, y: -90), in: frame, configuration: value))
        XCTAssertEqual(CornerGeometry.corner(at: .init(x: -2, y: 498), in: frame, configuration: value), .topRight)
    }
    func testVersionOneDecodeDefaultsNewGesturesAndPreservesOldBindings() throws {
        var original = CornerSettings.samplePreset
        original.enabled = true; original.enabledDisplayIDs = ["stable-screen"]
        let data = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "hoverDelay"); json.removeValue(forKey: "holdDelay")
        var corners = try XCTUnwrap(json["corners"] as? [String: [String: Any]])
        let legacy: Set<String> = ["singleClick", "doubleClick", "tripleClick", "dragIntoCorner", "dragOutOfCorner"]
        for corner in Corner.allCases {
            var configuration = try XCTUnwrap(corners[corner.rawValue])
            let bindings = try XCTUnwrap(configuration["bindings"] as? [String: Any])
            configuration["bindings"] = bindings.filter { legacy.contains($0.key) }
            configuration.removeValue(forKey: "cornerSize"); configuration.removeValue(forKey: "modifierRequirement")
            corners[corner.rawValue] = configuration
        }
        json["corners"] = corners
        let decoded = try JSONDecoder().decode(CornerSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, original); XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.hoverDelay, 1.2); XCTAssertEqual(decoded.holdDelay, 0.7)
        XCTAssertEqual(decoded.corners.values.reduce(0) { $0 + $1.bindings.count }, 52)
    }
    func testNewBoundsAndOverridesValidateAndRoundTrip() throws {
        var value = CornerSettings(hoverDelay: 0.3, holdDelay: 0.3)
        value.corners[.topLeft]?.cornerSize = 128; value.corners[.topLeft]?.modifierRequirement = []
        XCTAssertEqual(try JSONDecoder().decode(CornerSettings.self, from: JSONEncoder().encode(value)), value)
        for invalid in [0.29, 5.01, Double.nan] { var bad = value; bad.hoverDelay = invalid; XCTAssertThrowsError(try bad.validated()) }
        for invalid in [0.29, 3.01, Double.infinity] { var bad = value; bad.holdDelay = invalid; XCTAssertThrowsError(try bad.validated()) }
        value.corners[.topLeft]?.cornerSize = 129; XCTAssertThrowsError(try value.validated())
        value.corners[.topLeft]?.cornerSize = nil; value.corners[.topLeft]?.modifierRequirement = .init(rawValue: 128)
        XCTAssertThrowsError(try value.validated())
    }
}
