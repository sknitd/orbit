import AppKit
import CoreGraphics
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

    func testProductionMouseDecoderUsesActualButtonAndScrollFieldsWithoutKeyboardTypes() throws {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: .zero, mouseButton: .right))
        XCTAssertEqual(CornerMouseEventDecoder.kind(for: .rightMouseDown, event: event), .rightDown)
        XCTAssertEqual(CornerMouseEventDecoder.kind(for: .rightMouseUp, event: event), .rightUp)
        event.type = .otherMouseDown
        event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        XCTAssertEqual(CornerMouseEventDecoder.kind(for: .otherMouseDown, event: event), .middleDown)
        XCTAssertEqual(CornerMouseEventDecoder.kind(for: .otherMouseUp, event: event), .middleUp)
        event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        XCTAssertNil(CornerMouseEventDecoder.kind(for: .otherMouseDown, event: event))
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0))
        scroll.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 12)
        scroll.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        XCTAssertEqual(CornerMouseEventDecoder.kind(for: .scrollWheel, event: scroll), .scrollUp)
        scroll.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -12)
        XCTAssertEqual(CornerMouseEventDecoder.kind(for: .scrollWheel, event: scroll), .scrollDown)
        scroll.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        XCTAssertNil(CornerMouseEventDecoder.kind(for: .scrollWheel, event: scroll))
        scroll.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        scroll.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        scroll.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        scroll.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 10)
        XCTAssertNil(CornerMouseEventDecoder.kind(for: .scrollWheel, event: scroll), "Horizontal-only scrolling is not a vertical corner gesture")
        for keyType in [CGEventType.keyDown, .keyUp, .flagsChanged] {
            XCTAssertFalse(CornerMouseEventDecoder.observedTypes.contains(keyType))
            XCTAssertNil(CornerMouseEventDecoder.kind(for: keyType, event: event))
        }
    }

    func testNativeRightFamiliesMiddleAndScrollRouteAtEveryCorner() async throws {
        let input = NativeCornerInput()
        var received: [CornerTrigger] = []
        let monitor = CornerGestureMonitor(settings: configured(gestures: [.rightClick, .rightDoubleClick, .rightTripleClick, .middleClick, .scrollUp, .scrollDown]), dependencies: input.dependencies) { received.append($0) }
        defer { monitor.disable() }; XCTAssertTrue(monitor.enable())
        let points: [(Corner, CornerPoint)] = [(.topLeft, .init(x: 3, y: 597)), (.topRight, .init(x: 797, y: 597)), (.bottomLeft, .init(x: 3, y: 3)), (.bottomRight, .init(x: 797, y: 3))]
        for (index, entry) in points.enumerated() {
            let start = 1 + Double(index) * 5, initialCount = received.count
            input.send(.rightDown, at: start, point: entry.1); input.send(.rightUp, at: start + 0.01, point: entry.1)
            input.time = start + 0.22; monitor.flushPending()
            try await wait { received.count == initialCount + 1 }
            for offset in [0.5, 0.6] {
                input.send(.rightDown, at: start + offset, point: entry.1); input.send(.rightUp, at: start + offset + 0.01, point: entry.1)
            }
            input.time = start + 0.82; monitor.flushPending()
            try await wait { received.count == initialCount + 2 }
            for offset in [1.0, 1.1, 1.2] {
                input.send(.rightDown, at: start + offset, point: entry.1); input.send(.rightUp, at: start + offset + 0.01, point: entry.1)
            }
            try await wait { received.count == initialCount + 3 }
            input.time = start + 1.5; monitor.flushPending()
            input.send(.middleDown, at: start + 2, point: entry.1); input.send(.middleUp, at: start + 2.01, point: entry.1)
            try await wait { received.count == initialCount + 4 }
            input.send(.scrollUp, at: start + 2.5, point: entry.1)
            try await wait { received.count == initialCount + 5 }
            input.send(.scrollDown, at: start + 3, point: entry.1)
            try await wait { received.count == initialCount + 6 }
            XCTAssertEqual(Array(received.suffix(6)).map(\.gesture), [.rightClick, .rightDoubleClick, .rightTripleClick, .middleClick, .scrollUp, .scrollDown])
            XCTAssertTrue(received.suffix(6).allSatisfy { $0.corner == entry.0 })
        }
        XCTAssertEqual(input.permissionRequests, 0)
    }

    func testNativeDwellAndHoldUseOverridesAndSuppressReleaseActions() async throws {
        let input = NativeCornerInput()
        var settings = configured(gestures: [.hover, .longPress, .singleClick, .dragOutOfCorner])
        settings.hoverDelay = 0.3; settings.holdDelay = 0.3; settings.modifierRequirement = .shift
        settings.corners[.topLeft]?.modifierRequirement = []; settings.corners[.topLeft]?.cornerSize = 80
        var received: [CornerTrigger] = []
        let monitor = CornerGestureMonitor(settings: settings, dependencies: input.dependencies) { received.append($0) }
        defer { monitor.disable() }; XCTAssertTrue(monitor.enable())
        let expanded = CornerPoint(x: 60, y: 550)
        input.send(.moved, at: 1, point: expanded)
        input.time = 1.31; monitor.flushPending()
        try await wait { received.count == 1 }
        XCTAssertEqual(received.first?.gesture, .hover)
        input.send(.moved, at: 2, point: expanded)
        input.time = 2.5; monitor.flushPending(); await Task.yield(); XCTAssertEqual(received.count, 1)
        input.send(.down, at: 3, point: expanded)
        input.time = 3.31; monitor.flushPending()
        try await wait { received.count == 2 }
        XCTAssertEqual(received.last?.gesture, .longPress)
        input.send(.dragged, at: 3.4, point: .init(x: 200, y: 300)); input.send(.up, at: 3.5, point: .init(x: 200, y: 300))
        input.time = 3.8; monitor.flushPending(); await Task.yield()
        XCTAssertEqual(received.count, 2, "Recognized hold suppresses drag and click on release")
        input.send(.moved, at: 4, point: .init(x: 797, y: 597), modifiers: .shift)
        input.modifierState = []; input.time = 4.31; monitor.flushPending(); await Task.yield()
        XCTAssertEqual(received.count, 2, "A per-corner inherited modifier is checked at its dwell deadline")
    }

    func testPracticeUnassignedRoutingAndModeSwitchInvalidateDeferredDelivery() async throws {
        let input = NativeCornerInput()
        var normal: [CornerTrigger] = [], practiced: [CornerTrigger] = []
        let monitor = CornerGestureMonitor(settings: CornerSettings(enabled: true, cooldown: 0), dependencies: input.dependencies,
            onPractice: { practiced.append($0) }, onRecognized: { normal.append($0) })
        defer { monitor.disable() }; XCTAssertTrue(monitor.enable())
        let point = CornerPoint(x: 3, y: 597)
        monitor.setPractice(true)
        input.send(.scrollUp, at: 1, point: point)
        monitor.setPractice(false)
        await Task.yield()
        XCTAssertTrue(normal.isEmpty); XCTAssertTrue(practiced.isEmpty); XCTAssertNil(monitor.lastPractice)
        monitor.setPractice(true)
        input.send(.middleDown, at: 2, point: point); input.send(.middleUp, at: 2.01, point: point)
        try await wait { practiced.count == 1 }
        XCTAssertTrue(normal.isEmpty); XCTAssertEqual(practiced.first?.gesture, .middleClick)
        XCTAssertEqual(monitor.lastPractice, "Top Left: Middle Click")
        input.click(point, at: 3)
        monitor.setPractice(false)
        input.time = 3.5; monitor.flushPending(); await Task.yield()
        XCTAssertEqual(practiced.count, 1); XCTAssertTrue(normal.isEmpty)
        try monitor.update(settings: configured(gestures: [.scrollDown]))
        input.send(.scrollDown, at: 4, point: point)
        try await wait { normal.count == 1 }
        XCTAssertEqual(normal.first?.gesture, .scrollDown); XCTAssertEqual(practiced.count, 1)
        XCTAssertEqual(input.permissionRequests, 0)
    }

    func testPermissionRevocationAndDisplayChangesCancelDwellAndHold() async throws {
        let input = NativeCornerInput()
        var granted = true, received: [CornerTrigger] = []
        var dependencies = input.dependencies; dependencies.preflightAccess = { granted }
        var settings = configured(gestures: [.hover, .longPress]); settings.hoverDelay = 0.3; settings.holdDelay = 0.3
        let monitor = CornerGestureMonitor(settings: settings, dependencies: dependencies) { received.append($0) }
        defer { monitor.disable() }; XCTAssertTrue(monitor.enable())
        let point = CornerPoint(x: 3, y: 597)
        input.send(.moved, at: 1, point: point); granted = false
        input.time = 1.31; monitor.flushPending(); await Task.yield()
        XCTAssertTrue(received.isEmpty); XCTAssertFalse(monitor.isEnabled); XCTAssertEqual(monitor.status, .inputMonitoringRequired)
        granted = true; XCTAssertTrue(monitor.enable(requestPermission: false))
        input.send(.down, at: 2, point: point)
        input.screens = [.init(id: "primary", frame: .init(x: 0, y: 0, width: 1000, height: 600))]
        input.time = 2.31; monitor.flushPending(); await Task.yield()
        XCTAssertTrue(received.isEmpty)
        input.send(.down, at: 3, point: point); monitor.sessionDidChange(active: false)
        input.time = 3.31; monitor.flushPending(); await Task.yield()
        XCTAssertTrue(received.isEmpty); XCTAssertEqual(monitor.status, .sessionInactive)
        XCTAssertEqual(input.permissionRequests, 0)
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
