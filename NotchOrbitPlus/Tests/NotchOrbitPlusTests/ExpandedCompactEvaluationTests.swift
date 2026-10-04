import AppKit
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
        let cases: [(LiveNotchStatus, String)] = [
            (.init(id: "verification:8472", kind: .verificationCode, title: "847291", detail: "Fixture only · 42s",
                   toolID: "verificationCodes", action: .copyVerificationCode), "Copy one-time code"),
            (.init(id: "download:fixture-complete", kind: .downloads, title: "Archive.zip", detail: "Fixture completed file",
                   toolID: "downloads", action: .revealFile), "Reveal completed download")
        ]
        for (status, label) in cases {
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
            let button = try XCTUnwrap(accessibleElement(labeled: label, below: host), "The actual native compact action must expose its accessible control")
            XCTAssertTrue(button.accessibilityPerformPress())
            try await NativeFeatureEvaluation.waitUntil("The owned native action routes its displayed fixture", condition: { routed.count == 1 })
            XCTAssertEqual(routed, [status], "Copy/Reveal must route the displayed record, not an unrelated current item")
            XCTAssertEqual(opens, 0, "The action button must not also expand or change the selected tool")
        }
    }

    @MainActor
    private func accessibleElement(labeled label: String, below object: Any, depth: Int = 0) -> (any NSAccessibilityProtocol)? {
        guard depth < 20, let element = object as? any NSAccessibilityProtocol else { return nil }
        if element.accessibilityLabel() == label { return element }
        for child in element.accessibilityChildren() ?? [] {
            if let found = accessibleElement(labeled: label, below: child, depth: depth + 1) { return found }
        }
        return nil
    }
}
