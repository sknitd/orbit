import AppKit
import ObjectiveC
import SwiftUI
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class ExpandedCompactEvaluationTests: XCTestCase {
    @MainActor
    func testNewActivityFixturesRenderActualClosedNotchAndKeepFileProcessingPrimary() async throws {
        let fixtures: [(String, LiveNotchStatus)] = [
            ("downloads", .init(id: "fixture-download", kind: .downloads, title: "Archive.zip", detail: "Final file observed · 512 MB", toolID: "downloads", action: .revealFile)),
            ("command", .init(id: "fixture-command", kind: .command, title: "Build", detail: "Running · Result pending", toolID: "commands")),
            ("dictation", .init(id: "fixture-dictation", kind: .dictation, title: "Listening", detail: "On-device dictation", toolID: "dictation", waveform: [0.1, 0.3, 0.7, 0.4, 0.9, 0.5, 0.2])),
            ("verificationCode", .init(id: "fixture-code", kind: .verificationCode, title: "847291", detail: "Verification code · 42s", toolID: "verificationCodes", action: .copyVerificationCode)),
            ("package", .init(id: "fixture-package", kind: .package, title: "Sample parcel", detail: "Provider fixture · In transit", toolID: "packageTracker")),
            ("travel", .init(id: "fixture-travel", kind: .travel, title: "Flight AB123", detail: "Calendar fixture · Departure in 2h", toolID: "travelStatus")),
            ("sports", .init(id: "fixture-sports", kind: .sports, title: "Sample team 2–1", detail: "Provider fixture · 72 minutes", toolID: "sportsScores")),
            ("weather", .init(id: "fixture-weather", kind: .weather, title: "Heavy rain", detail: "Forecast fixture · 14:00–16:00", toolID: "weather")),
            ("focus", .init(id: "fixture-focus", kind: .focus, title: "24:30", detail: "Focus timer fixture", toolID: "timers")),
            ("devices", .init(id: "fixture-devices", kind: .devices, title: "Fixture headset", detail: "Fixture battery · 62%", toolID: "devices")),
            ("status", .init(id: "fixture-status", kind: .status, title: "Fixture Focus", detail: "Fixture authorized sharing · Active", toolID: "status"))
        ]
        let processing = LiveNotchStatus(id: "fixture-processing", kind: .processing,
            title: "Resizing images", detail: "2 of 3", toolID: "workflows", progress: 2.0 / 3.0)
        for (name, activity) in fixtures {
            XCTAssertTrue(PlusTool.allCases.contains { $0.rawValue == activity.toolID })
            XCTAssertEqual(LiveNotchSelection.ordered([activity, processing]).first?.id, processing.id)
            XCTAssertEqual(LiveNotchSelection.ordered([activity]).first?.toolID, activity.toolID)
            try await NativeFeatureEvaluation.render(AnyView(
                LiveCompactContent(statuses: [activity, processing], openDashboard: {}, onActivityAction: { _ in })
                    .padding(.horizontal, 12).background(.black).foregroundStyle(.white)),
                named: "NotchOrbitPlus-Compact-fixture-new-\(name).png", size: NSSize(width: 320, height: 48),
                appearance: NSAppearance(named: .darkAqua))
            // Render the new activity itself as primary; a processing fixture must not mask its UI.
            try await NativeFeatureEvaluation.render(AnyView(
                LiveCompactContent(statuses: [activity], openDashboard: {}, onActivityAction: { _ in })
                    .padding(.horizontal, 12).background(.black).foregroundStyle(.white)),
                named: "NotchOrbitPlus-Compact-fixture-primary-\(name).png", size: NSSize(width: 320, height: 48),
                appearance: NSAppearance(named: .darkAqua))
        }
    }

    @MainActor
    func testOwnedNativeCompactButtonsRouteTheDisplayedActivityWithoutOpeningOtherTools() async throws {
        let cases: [(LiveNotchStatus, String, String)] = [
            (.init(id: "verification:8472", kind: .verificationCode, title: "847291", detail: "Fixture only · 42s",
                   toolID: "verificationCodes", action: .copyVerificationCode), "Copy one-time code", "NotchOrbitPlus.compact.copyVerificationCode"),
            (.init(id: "download:fixture-complete", kind: .downloads, title: "Archive.zip", detail: "Fixture completed file",
                   toolID: "downloads", action: .revealFile), "Reveal completed download", "NotchOrbitPlus.compact.revealFile")
        ]
        for (status, label, identifier) in cases {
            var routed: [LiveNotchStatus] = [], opens = 0
            let size = NSSize(width: 320, height: 48)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: LiveCompactContent(statuses: [status], openDashboard: { opens += 1 },
                onActivityAction: { routed.append($0) }).frame(width: size.width, height: size.height))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let button = try XCTUnwrap(nativeActionButton(identifier: identifier, below: host), "The actual compact action must expose its native control")
            XCTAssertTrue(button.isAccessibilityElement())
            XCTAssertEqual(button.accessibilityRole(), .button)
            XCTAssertEqual(button.accessibilityLabel(), label)
            XCTAssertEqual(button.accessibilityIdentifier(), identifier)
            let semanticAction = try XCTUnwrap(CompactAccessibilityFixture.action(identifier: identifier, below: host)
                ?? CompactAccessibilityFixture.action(identifier: identifier, below: window),
                "The action must be reachable through the owned host/window accessibility tree: \(CompactAccessibilityFixture.tree(below: host)); \(CompactAccessibilityFixture.tree(below: window))")
            XCTAssertEqual(CompactAccessibilityFixture.role(of: semanticAction), "AXButton")
            XCTAssertEqual(CompactAccessibilityFixture.label(of: semanticAction), label)
            XCTAssertTrue(CompactAccessibilityFixture.press(semanticAction))
            try await NativeFeatureEvaluation.waitUntil("The semantic accessibility action routes its displayed fixture", condition: { routed.count == 1 })
            XCTAssertEqual(routed, [status])
            XCTAssertEqual(opens, 0)
            routed.removeAll()
            XCTAssertTrue(button.accessibilityPerformPress())
            try await NativeFeatureEvaluation.waitUntil("The owned native action routes its displayed fixture", condition: { routed.count == 1 })
            XCTAssertEqual(routed, [status], "Copy/Reveal must route the displayed record, not an unrelated current item")
            XCTAssertEqual(opens, 0, "The action button must not also expand or change the selected tool")
        }
    }

    @MainActor
    private func nativeActionButton(identifier: String, below view: NSView, depth: Int = 0) -> NSButton? {
        guard depth < 40 else { return nil }
        if let button = view as? NSButton, button.identifier?.rawValue == identifier { return button }
        // Hosting/bridge views need not formally adopt NSAccessibilityProtocol.
        // Traverse the actual owned native views, then verify the control's public
        // accessibility identity, role and real press behavior above.
        for child in view.subviews {
            if let found = nativeActionButton(identifier: identifier, below: child, depth: depth + 1) { return found }
        }
        return nil
    }

}

/// These fixtures read only the owned window's documented accessibility getters.
/// SwiftUI virtual elements may implement them without declaring formal protocol
/// conformance, so the public Objective-C signatures are checked before calling.
@MainActor
enum CompactAccessibilityFixture {
    static func role(of object: NSObject) -> String? {
        stringValue(object, getter: "accessibilityRole", attribute: "AXRole")
    }
    static func label(of object: NSObject) -> String? {
        stringValue(object, getter: "accessibilityLabel", attribute: "AXDescription")
            ?? stringValue(object, getter: "accessibilityLabel", attribute: "AXTitle")
    }
    static func identifier(of object: NSObject) -> String? {
        stringValue(object, getter: "accessibilityIdentifier", attribute: "AXIdentifier")
    }
    static func action(identifier: String, below root: Any) -> NSObject? {
        var pending: [(Any, Int)] = [(root, 0)], seen = Set<ObjectIdentifier>(), visited = 0
        while let (value, depth) = pending.popLast(), visited < 512 {
            guard depth < 40, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            visited += 1
            if self.identifier(of: object) == identifier, role(of: object) == "AXButton" { return object }
            pending.append(contentsOf: children(of: object).map { ($0, depth + 1) })
        }
        return nil
    }
    static func press(_ object: NSObject) -> Bool {
        if let view = object as? NSView { return view.accessibilityPerformPress() }
        if let element = object as? any NSAccessibilityProtocol { return element.accessibilityPerformPress() }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector),
           method_getNumberOfArguments(method) == 2, let encoding = method_getTypeEncoding(method),
           encoding.pointee == 66 || encoding.pointee == 99 { // BOOL: B or c.
            typealias PublicPress = @convention(c) (AnyObject, Selector) -> Bool
            let perform = unsafeBitCast(method_getImplementation(method), to: PublicPress.self)
            return perform(object, selector)
        }
        let legacySelector = NSSelectorFromString("accessibilityPerformAction:")
        guard let actions = objectValue(object, selector: "accessibilityActionNames") as? [String], actions.contains("AXPress"),
              object.responds(to: legacySelector), let method = class_getInstanceMethod(type(of: object), legacySelector),
              method_getNumberOfArguments(method) == 3, let encoding = method_getTypeEncoding(method), encoding.pointee == 118,
              let argument = method_copyArgumentType(method, 2) else { return false } // Void return only.
        defer { free(argument) }
        guard argument.pointee == 64 else { return false } // Object argument only.
        typealias PublicLegacyPress = @convention(c) (AnyObject, Selector, NSString) -> Void
        let perform = unsafeBitCast(method_getImplementation(method), to: PublicLegacyPress.self)
        perform(object, legacySelector, "AXPress")
        // Legacy API has no result. The caller must also prove the exact action
        // callback, rather than interpreting dispatch alone as success.
        return true
    }
    static func tree(below root: Any) -> [[String: Any]] {
        var pending: [(Any, Int)] = [(root, 0)], seen = Set<ObjectIdentifier>(), output: [[String: Any]] = []
        while let (value, depth) = pending.popLast(), output.count < 512 {
            guard depth < 40, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let childValues = children(of: object)
            output.append(["type": String(reflecting: type(of: object)), "depth": depth,
                "role": role(of: object) ?? "(nil)", "label": label(of: object) ?? "(nil)",
                "identifier": identifier(of: object) ?? "(nil)", "children": childValues.count,
                "formal_protocol": object is any NSAccessibilityProtocol,
                "modern_children_getter": object.responds(to: NSSelectorFromString("accessibilityChildren")),
                "legacy_attribute_getter": object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")),
                "modern_press": object.responds(to: NSSelectorFromString("accessibilityPerformPress")),
                "legacy_press": object.responds(to: NSSelectorFromString("accessibilityPerformAction:")),
                "declared_actions": objectValue(object, selector: "accessibilityActionNames") as? [String] ?? []])
            pending.append(contentsOf: childValues.map { ($0, depth + 1) })
        }
        return output
    }
    private static func children(of object: NSObject) -> [Any] {
        let modern = objectValue(object, selector: "accessibilityChildren") as? [Any] ?? []
        let legacy = objectValue(object, selector: "accessibilityAttributeValue:", argument: "AXChildren") as? [Any] ?? []
        return modern + legacy
    }
    private static func stringValue(_ object: NSObject, getter: String, attribute: String) -> String? {
        (objectValue(object, selector: getter) as? String)
            ?? (objectValue(object, selector: "accessibilityAttributeValue:", argument: attribute) as? String)
    }
    private static func objectValue(_ object: NSObject, selector name: String, argument: String? = nil) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector),
              let encoding = method_getTypeEncoding(method), encoding.pointee == 64,
              method_getNumberOfArguments(method) == (argument == nil ? 2 : 3) else { return nil } // Object return only.
        if let argument { return object.perform(selector, with: argument)?.takeUnretainedValue() }
        return object.perform(selector)?.takeUnretainedValue()
    }
}
