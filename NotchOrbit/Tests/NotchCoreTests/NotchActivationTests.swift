import XCTest
@testable import NotchCore

final class NotchActivationTests: XCTestCase {
    private func zone(id: UInt32 = 1, x: Double = 0, width: Double = 1920) -> NotchActivationZone {
        let frame = NotchRect(x: x, y: 0, width: width, height: 1080)
        let layout = NotchLayout(metrics: .init(frame: frame, visibleFrame: .init(x: x, y: 24, width: width, height: 1032)), screenID: id)
        return .init(screenID: id, screenFrame: frame, layout: layout)
    }
    private func target(_ zone: NotchActivationZone) -> NotchPoint {
        .init(x: zone.layout.activationRegion.midX, y: zone.layout.activationRegion.minY + 10)
    }
    private func activate(_ tracker: inout NotchActivationTracker, zone: NotchActivationZone) throws -> NotchActivation {
        tracker.begin(pasteboardCount: 10)
        let transition = tracker.dragged(at: target(zone), pasteboardCount: 11, hasFileURLs: true, zones: [zone])
        guard case .activate(let activation) = transition else {
            XCTFail("A fresh file drag at the target must activate")
            throw NSError(domain: "NotchActivationTests", code: 1)
        }
        return activation
    }

    func testHoverWithoutMouseDownAndStaleDragPasteboardCannotActivate() {
        let zone = zone()
        var tracker = NotchActivationTracker()
        XCTAssertEqual(tracker.dragged(at: target(zone), pasteboardCount: 11, hasFileURLs: true, zones: [zone]), .none)
        tracker.begin(pasteboardCount: 10)
        XCTAssertEqual(tracker.dragged(at: target(zone), pasteboardCount: 10, hasFileURLs: true, zones: [zone]), .none)
        XCTAssertNil(tracker.current)
    }

    func testFreshTextDragCannotActivateFileActions() {
        let zone = zone()
        var tracker = NotchActivationTracker()
        tracker.begin(pasteboardCount: 10)
        XCTAssertEqual(tracker.dragged(at: target(zone), pasteboardCount: 11, hasFileURLs: false, zones: [zone]), .none)
        XCTAssertNil(tracker.current)
    }

    func testFreshFileDragNeedsNoModifierAndActivatesOnlyOnce() throws {
        let zone = zone()
        var tracker = NotchActivationTracker()
        let activation = try activate(&tracker, zone: zone)
        XCTAssertTrue(tracker.isCurrent(activation.generation))
        XCTAssertEqual(tracker.dragged(at: target(zone), pasteboardCount: 11, hasFileURLs: true, zones: [zone]), .none)
        XCTAssertEqual(tracker.current, activation)
    }

    func testTransportTowardLowerOptionsDoesNotCancelPresentation() throws {
        let zone = zone()
        var tracker = NotchActivationTracker()
        let activation = try activate(&tracker, zone: zone)
        let option = NotchPoint(x: zone.layout.anchor.x, y: zone.layout.anchor.y - 230)
        XCTAssertFalse(zone.layout.activationRegion.contains(option))
        XCTAssertEqual(tracker.dragged(at: option, pasteboardCount: 11, hasFileURLs: true, zones: [zone]), .none)
        XCTAssertTrue(tracker.isCurrent(activation.generation))
    }

    func testLeavingAndReenteringRequiresNewPresentationGeneration() throws {
        let zone = zone()
        var tracker = NotchActivationTracker()
        let first = try activate(&tracker, zone: zone)
        XCTAssertEqual(tracker.dragged(at: .init(x: 30, y: 30), pasteboardCount: 11, hasFileURLs: true, zones: [zone]), .cancel)
        XCTAssertFalse(tracker.isCurrent(first.generation))
        XCTAssertTrue(tracker.mouseIsDown)
        let transition = tracker.dragged(at: target(zone), pasteboardCount: 11, hasFileURLs: true, zones: [zone])
        guard case .activate(let second) = transition else { return XCTFail("Reentry must create a fresh presentation") }
        XCTAssertNotEqual(second.generation, first.generation)
        XCTAssertTrue(tracker.isCurrent(second.generation))
    }

    func testSecondPasteboardWriterInvalidatesWholeMouseDown() throws {
        let zone = zone()
        var tracker = NotchActivationTracker()
        let activation = try activate(&tracker, zone: zone)
        XCTAssertEqual(tracker.dragged(at: target(zone), pasteboardCount: 12, hasFileURLs: true, zones: [zone]), .cancel)
        XCTAssertFalse(tracker.mouseIsDown)
        XCTAssertFalse(tracker.isCurrent(activation.generation))
        XCTAssertEqual(tracker.dragged(at: target(zone), pasteboardCount: 13, hasFileURLs: true, zones: [zone]), .none)
    }

    func testMouseUpOnlyKeepsExistingDestinationPendingAndCannotAuthorizeLateInspection() throws {
        let zone = zone()
        var tracker = NotchActivationTracker()
        let activation = try activate(&tracker, zone: zone)
        XCTAssertEqual(tracker.release(), .releasePending(activation))
        XCTAssertFalse(tracker.mouseIsDown)
        XCTAssertTrue(tracker.awaitingDrop)
        XCTAssertFalse(tracker.isCurrent(activation.generation))
        XCTAssertEqual(tracker.current, activation)
        XCTAssertEqual(tracker.dragged(at: target(zone), pasteboardCount: 11, hasFileURLs: true, zones: [zone]), .none)
        XCTAssertEqual(tracker.release(), .none)
    }

    func testEscapeOrFullCancellationCannotReactivateWithoutAnotherMouseDown() throws {
        let zone = zone()
        var tracker = NotchActivationTracker()
        let activation = try activate(&tracker, zone: zone)
        XCTAssertEqual(tracker.cancel(), .cancel)
        XCTAssertFalse(tracker.isCurrent(activation.generation))
        XCTAssertEqual(tracker.dragged(at: target(zone), pasteboardCount: 11, hasFileURLs: true, zones: [zone]), .none)
    }

    func testNegativeOriginScreenIsChosenFromPointerRatherThanPrimaryScreen() {
        let primary = zone()
        let secondary = zone(id: 2, x: -1920)
        var tracker = NotchActivationTracker()
        tracker.begin(pasteboardCount: 10)
        let transition = tracker.dragged(at: target(secondary), pasteboardCount: 11, hasFileURLs: true, zones: [primary, secondary])
        guard case .activate(let activation) = transition else { return XCTFail("Secondary display must activate") }
        XCTAssertEqual(activation.zone.screenID, 2)
        XCTAssertLessThan(activation.zone.layout.anchor.x, 0)
    }

    func testScreenRemovalAndScreenLayoutChangeInvalidateOldGeneration() throws {
        let original = zone()
        for changedZones in [[], [zone(width: 1280)]] {
            var tracker = NotchActivationTracker()
            let activation = try activate(&tracker, zone: original)
            XCTAssertEqual(tracker.dragged(at: target(original), pasteboardCount: 11, hasFileURLs: true, zones: changedZones), .cancel)
            XCTAssertFalse(tracker.isCurrent(activation.generation))
        }
    }

    func testOutsideEveryScreenAndZeroSizePanelCannotActivate() {
        let normal = zone()
        let tinyFrame = NotchRect(x: 0, y: 0, width: 10, height: 10)
        let tiny = NotchActivationZone(screenID: 3, screenFrame: tinyFrame,
                                      layout: .init(metrics: .init(frame: tinyFrame, visibleFrame: tinyFrame)))
        var tracker = NotchActivationTracker()
        tracker.begin(pasteboardCount: 10)
        XCTAssertEqual(tracker.dragged(at: .init(x: 3000, y: 4000), pasteboardCount: 11, hasFileURLs: true, zones: [normal]), .none)
        XCTAssertEqual(tracker.dragged(at: .init(x: 5, y: 5), pasteboardCount: 11, hasFileURLs: true, zones: [tiny]), .none)
    }
}
