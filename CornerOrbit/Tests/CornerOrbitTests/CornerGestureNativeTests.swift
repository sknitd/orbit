import AppKit
import XCTest
import CornerCore
@testable import CornerOrbit

@MainActor
private final class NativeCornerInput: CornerMouseEventSource {
    var time = 0.0
    var modifierState: CornerModifiers = []
    var sessionActive = true
    var screens = [CornerScreen(id: "primary", frame: .init(x: 0, y: 0, width: 800, height: 600))]
    var receiver: CornerMonitorDependencies.Receiver?
    var stops = 0
    var installations = 0
    var permissionRequests = 0
    var dependencies: CornerMonitorDependencies {
        .init(preflightAccess: { true }, requestAccess: { self.permissionRequests += 1; return true },
              screens: { self.screens }, installMouseEvents: { callback in
                  self.installations += 1; self.receiver = callback; return self
              }, now: { self.time }, modifiers: { self.modifierState }, sessionActive: { self.sessionActive })
    }
    func stop() { stops += 1; receiver = nil }
    func send(_ kind: CornerMouseSample.Kind, at time: Double, point: CornerPoint, modifiers: CornerModifiers = []) {
        self.time = time; modifierState = modifiers
        receiver?(.init(kind: kind, timestamp: time, point: point, modifiers: modifiers))
    }
    func click(_ point: CornerPoint, at time: Double, modifiers: CornerModifiers = []) {
        send(.down, at: time, point: point, modifiers: modifiers)
        send(.up, at: time + 0.01, point: point, modifiers: modifiers)
    }
}

@MainActor
final class CornerGestureNativeTests: XCTestCase {
    func testQuartzConversionAndFullDisplayCornersPreserveNegativeAndUpperArrangements() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CornerScreen(id: "left", frame: .init(x: -1920, y: -180, width: 1920, height: 1080))
        let upper = CornerScreen(id: "upper", frame: .init(x: 0, y: 900, width: 1440, height: 1200))
        let leftBottom = CornerScreenGeometry.appKitPoint(fromQuartz: CGPoint(x: -1918, y: 1078), primaryFrame: primary)
        XCTAssertEqual(leftBottom, CornerPoint(x: -1918, y: -178))
        XCTAssertEqual(CornerScreenGeometry.screen(at: leftBottom, in: [left, upper])?.id, "left")
        XCTAssertEqual(CornerGeometry.corner(at: leftBottom, in: left.frame, size: 24), .bottomLeft)
        let upperRight = CornerScreenGeometry.appKitPoint(fromQuartz: CGPoint(x: 1438, y: -1198), primaryFrame: primary)
        XCTAssertEqual(upperRight, CornerPoint(x: 1438, y: 2098))
        XCTAssertEqual(CornerGeometry.corner(at: upperRight, in: upper.frame, size: 24), .topRight)
        // No backingScaleFactor multiplier or visibleFrame/menu/Dock inset.
        XCTAssertEqual(CornerScreenGeometry.appKitPoint(fromQuartz: .zero, primaryFrame: primary), .init(x: 0, y: 900))
    }

    func testScreenSelectionRejectsArrangementGapsAndUsesCoreBoundaryTieBreak() {
        let first = CornerScreen(id: "A", frame: .init(x: 0, y: 0, width: 100, height: 100))
        let adjacent = CornerScreen(id: "B", frame: .init(x: 100, y: 0, width: 100, height: 100))
        let distant = CornerScreen(id: "C", frame: .init(x: 400, y: 0, width: 100, height: 100))
        XCTAssertEqual(CornerScreenGeometry.screen(at: .init(x: 100, y: 50), in: [adjacent, first])?.id, "A")
        XCTAssertNil(CornerScreenGeometry.screen(at: .init(x: 300, y: 50), in: [first, adjacent, distant]))
        XCTAssertNil(CornerScreenGeometry.screen(at: .init(x: .nan, y: 1), in: [first]))
    }

    func testNativeAdapterDisambiguatesSingleDoubleTripleAndIndependentCorners() async throws {
        let input = NativeCornerInput(), settings = configured(gestures: [.singleClick, .doubleClick, .tripleClick])
        var received: [CornerTrigger] = []
        let monitor = CornerGestureMonitor(settings: settings, dependencies: input.dependencies) { received.append($0) }
        defer { monitor.disable() }
        XCTAssertTrue(monitor.enable())
        input.click(.init(x: 3, y: 597), at: 1)
        input.time = 1.1; monitor.flushPending(); XCTAssertTrue(received.isEmpty)
        input.time = 1.22; monitor.flushPending()
        try await wait { received.count == 1 }
        XCTAssertEqual(received[0].gesture, .singleClick); XCTAssertEqual(received[0].corner, .topLeft)
        input.click(.init(x: 3, y: 3), at: 1.5)
        input.click(.init(x: 3, y: 3), at: 1.6)
        input.time = 1.82; monitor.flushPending()
        try await wait { received.count == 2 }
        XCTAssertEqual(received[1].gesture, .doubleClick); XCTAssertEqual(received[1].corner, .bottomLeft)
        input.click(.init(x: 797, y: 597), at: 2)
        input.click(.init(x: 797, y: 597), at: 2.1)
        input.click(.init(x: 797, y: 597), at: 2.2)
        try await wait { received.count == 3 }
        XCTAssertEqual(received[2].gesture, .tripleClick); XCTAssertEqual(received[2].corner, .topRight)
        input.click(.init(x: 797, y: 3), at: 2.4)
        input.time = 2.62; monitor.flushPending()
        try await wait { received.count == 4 }
        XCTAssertEqual(received[3].gesture, .singleClick); XCTAssertEqual(received[3].corner, .bottomRight)
        XCTAssertEqual(Set(received.map(\.screenID)), ["primary"])
        XCTAssertEqual(input.permissionRequests, 0)
    }

    func testNativeDragDirectionRequiresDraggedEventsAndRelease() async throws {
        let input = NativeCornerInput()
        var received: [CornerTrigger] = []
        let monitor = CornerGestureMonitor(settings: configured(gestures: [.dragIntoCorner, .dragOutOfCorner]), dependencies: input.dependencies) { received.append($0) }
        defer { monitor.disable() }; XCTAssertTrue(monitor.enable())
        input.send(.down, at: 1, point: .init(x: 200, y: 300))
        input.send(.dragged, at: 1.1, point: .init(x: 3, y: 597))
        XCTAssertTrue(received.isEmpty, "Entering a corner while held must not execute")
        input.send(.up, at: 1.2, point: .init(x: 3, y: 597))
        try await wait { received.count == 1 }
        XCTAssertEqual(received[0].gesture, .dragIntoCorner); XCTAssertEqual(received[0].corner, .topLeft)
        input.send(.down, at: 2, point: .init(x: 797, y: 597))
        input.send(.dragged, at: 2.1, point: .init(x: 700, y: 500))
        XCTAssertEqual(received.count, 1)
        input.send(.up, at: 2.2, point: .init(x: 700, y: 500))
        try await wait { received.count == 2 }
        XCTAssertEqual(received[1].gesture, .dragOutOfCorner); XCTAssertEqual(received[1].corner, .topRight)
        input.send(.down, at: 3, point: .init(x: 3, y: 3))
        input.send(.moved, at: 3.1, point: .init(x: 200, y: 100))
        input.send(.up, at: 3.2, point: .init(x: 200, y: 100))
        input.time = 3.5; monitor.flushPending()
        await Task.yield()
        XCTAssertEqual(received.count, 2, "Pointer movement without an actual dragged event is not a drag")
    }

    func testSameDisplayIDLayoutChangeAndRemovalInvalidatePendingClicks() async throws {
        let input = NativeCornerInput()
        var received: [CornerTrigger] = []
        let monitor = CornerGestureMonitor(settings: configured(gestures: [.singleClick]), dependencies: input.dependencies) { received.append($0) }
        defer { monitor.disable() }; XCTAssertTrue(monitor.enable())
        input.click(.init(x: 797, y: 597), at: 1)
        input.screens = [.init(id: "primary", frame: .init(x: 0, y: 0, width: 1000, height: 600))]
        input.time = 1.3; monitor.flushPending(); await Task.yield()
        XCTAssertTrue(received.isEmpty, "A preserved display ID cannot preserve obsolete corner geometry")
        input.click(.init(x: 997, y: 597), at: 2)
        input.time = 2.22; monitor.flushPending()
        try await wait { received.count == 1 }
        XCTAssertEqual(received.first?.point, .init(x: 997, y: 597))
        input.click(.init(x: 3, y: 597), at: 3)
        input.screens = []; monitor.refreshScreens()
        input.time = 3.3; monitor.flushPending(); await Task.yield()
        XCTAssertEqual(received.count, 1); XCTAssertEqual(monitor.status, .noSelectedDisplays)
    }

    func testRequiredModifierReleaseAndSessionSuspendCancelDelayedActions() async throws {
        let input = NativeCornerInput()
        var settings = configured(gestures: [.singleClick]); settings.modifierRequirement = .shift
        var received: [CornerTrigger] = []
        let monitor = CornerGestureMonitor(settings: settings, dependencies: input.dependencies) { received.append($0) }
        defer { monitor.disable() }; XCTAssertTrue(monitor.enable())
        input.click(.init(x: 3, y: 597), at: 1, modifiers: .shift)
        input.modifierState = []; input.time = 1.3; monitor.flushPending(); await Task.yield()
        XCTAssertTrue(received.isEmpty, "Deadline state refresh cancels without capturing keyboard events")
        input.click(.init(x: 3, y: 597), at: 2, modifiers: .shift)
        monitor.sessionDidChange(active: false)
        input.time = 2.3; monitor.flushPending(); await Task.yield()
        XCTAssertTrue(received.isEmpty); XCTAssertEqual(monitor.status, .sessionInactive)
        monitor.sessionDidChange(active: true)
        input.click(.init(x: 3, y: 597), at: 3, modifiers: .shift)
        input.time = 3.22; monitor.flushPending()
        try await wait { received.count == 1 }
    }

    func testDisplaySelectionRejectsUnselectedDisplayAndRealDeadlineFiresOnce() async throws {
        let input = NativeCornerInput()
        input.screens.append(.init(id: "left", frame: .init(x: -800, y: 0, width: 800, height: 600)))
        var settings = configured(gestures: [.singleClick]); settings.enabledDisplayIDs = ["primary"]
        var dependencies = input.dependencies
        dependencies.now = { ProcessInfo.processInfo.systemUptime }
        var received: [CornerTrigger] = []
        let monitor = CornerGestureMonitor(settings: settings, dependencies: dependencies) { received.append($0) }
        defer { monitor.disable() }; XCTAssertTrue(monitor.enable())
        input.click(.init(x: -797, y: 597), at: ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(for: .milliseconds(240)); XCTAssertTrue(received.isEmpty)
        input.click(.init(x: 3, y: 597), at: ProcessInfo.processInfo.systemUptime)
        try await wait { received.count == 1 }
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(received.count, 1); XCTAssertEqual(received.first?.screenID, "primary")
    }

    private func configured(gestures: [CornerGesture]) -> CornerSettings {
        let bindings = Dictionary(uniqueKeysWithValues: gestures.map { ($0, CornerAction(kind: .finder)) })
        return CornerSettings(enabled: true,
            corners: Dictionary(uniqueKeysWithValues: Corner.allCases.map { ($0, CornerConfiguration(bindings: bindings)) }),
            cornerSize: 24, clickInterval: 0.2, dragThreshold: 12, cooldown: 0)
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), "Injected native callback did not arrive within two seconds")
    }
}
