import AppKit
import SwiftUI
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class FocusAppHidingEvaluationTests: XCTestCase {
    @MainActor
    func testExplicitFocusHideRestoresOnPauseAndCompletionAndRendersItsPreview() async throws {
        let suite = "FocusHideLifecycle-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let launchDate = Date(timeIntervalSince1970: 1_999_000)
        var running = [FocusAppSnapshot(processID: 4101, bundleID: "com.example.Editor", hidden: false, launchDate: launchDate)]
        var hides: [Int32] = [], unhides: [Int32] = []
        var allowRestore = true
        let store = FocusAppHidingStore(defaults: defaults, ownProcessID: 9999, snapshots: { running },
            hide: { pid in
                hides.append(pid)
                running = running.map { .init(processID: $0.processID, bundleID: $0.bundleID, hidden: $0.processID == pid || $0.hidden, launchDate: $0.launchDate) }
                return true
            }, unhide: { pid in
                unhides.append(pid)
                guard allowRestore else { return false }
                running = running.map { .init(processID: $0.processID, bundleID: $0.bundleID, hidden: $0.processID == pid ? false : $0.hidden, launchDate: $0.launchDate) }
                return true
            })
        defer { store.shutdown() }
        XCTAssertTrue(hides.isEmpty); XCTAssertTrue(unhides.isEmpty)
        store.setConfiguration(.init(enabled: true, bundleIDs: ["com.example.Editor"]))
        store.refreshPreview()
        XCTAssertEqual(store.preview.map(\.processID), [4101])
        XCTAssertTrue(hides.isEmpty, "Choosing or previewing apps must never hide one")
        try await NativeFeatureEvaluation.render(AnyView(FocusAppHidingSettingsView(store: store)),
            named: "NotchOrbitPlus-FocusAppHiding-fixture-preview.png", size: NSSize(width: 560, height: 560))
        let start = Date(timeIntervalSince1970: 2_000_000)
        var timer = FocusTimer(); timer.start(minutes: 1, at: start)
        store.update(timer: timer, at: start)
        XCTAssertEqual(hides, [4101]); XCTAssertEqual(store.hiddenCount, 1)
        store.update(timer: timer, at: start.addingTimeInterval(5))
        XCTAssertEqual(hides, [4101], "Repeated timer updates must not acquire an app twice")
        timer.pause(at: start.addingTimeInterval(10)); store.update(timer: timer, at: start.addingTimeInterval(10))
        XCTAssertEqual(unhides, [4101]); XCTAssertEqual(store.hiddenCount, 0)
        timer.resume(at: start.addingTimeInterval(20)); store.update(timer: timer, at: start.addingTimeInterval(20))
        XCTAssertEqual(hides, [4101, 4101]); XCTAssertEqual(store.hiddenCount, 1)
        XCTAssertEqual(timer.finishIfDue(at: start.addingTimeInterval(71)), .focus)
        store.update(timer: timer, at: start.addingTimeInterval(71))
        XCTAssertEqual(unhides, [4101, 4101]); XCTAssertEqual(store.hiddenCount, 0)
        XCTAssertFalse(running[0].hidden)
        timer.start(minutes: 1, at: start.addingTimeInterval(100))
        store.update(timer: timer, at: start.addingTimeInterval(100))
        XCTAssertEqual(store.hiddenCount, 1)
        store.setConfiguration(.init(enabled: false, bundleIDs: ["com.example.Editor"]))
        XCTAssertEqual(unhides, [4101, 4101, 4101], "Disabling through configuration must restore immediately")
        XCTAssertEqual(store.hiddenCount, 0)
        store.setConfiguration(.init(enabled: true, bundleIDs: ["com.example.Editor"]))
        store.update(timer: timer, at: start.addingTimeInterval(101))
        let recovery = try XCTUnwrap(defaults.data(forKey: FocusAppHidingStore.recoveryKey))
        allowRestore = false
        store.resetKeepingBackup()
        XCTAssertEqual(store.hiddenCount, 1)
        XCTAssertNotNil(store.error, "Reset must retain a failed restore warning")
        XCTAssertEqual(defaults.data(forKey: FocusAppHidingStore.recoveryKey), recovery,
            "An app macOS refused to restore must retain its persisted recovery ownership")
        allowRestore = true; store.restore()
        XCTAssertEqual(store.hiddenCount, 0)
        XCTAssertNil(defaults.object(forKey: FocusAppHidingStore.recoveryKey))
    }

    @MainActor
    func testAlreadyHiddenSelfAndReusedPIDAreNeverRestoredAsOwnedApps() throws {
        let suite = "FocusHideOwnership-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldLaunch = Date(timeIntervalSince1970: 2_999_000)
        var running: [FocusAppSnapshot] = [
            .init(processID: 4201, bundleID: "com.example.Editor", hidden: false, launchDate: oldLaunch),
            .init(processID: 4202, bundleID: "com.example.Chat", hidden: true, launchDate: oldLaunch),
            .init(processID: 4203, bundleID: "com.example.Viewer", hidden: false, launchDate: oldLaunch),
            .init(processID: 4204, bundleID: "com.example.UnknownIdentity", hidden: false),
            .init(processID: 9999, bundleID: "com.sknitd.NotchOrbitPlus", hidden: false, launchDate: oldLaunch)
        ]
        var hides: [Int32] = [], unhides: [Int32] = []
        let store = FocusAppHidingStore(defaults: defaults, ownProcessID: 9999, snapshots: { running },
            hide: { hides.append($0); return true }, unhide: { unhides.append($0); return true })
        defer { store.shutdown() }
        store.setConfiguration(.init(enabled: true, bundleIDs: ["com.example.Editor", "com.example.Chat", "com.example.Viewer", "com.example.UnknownIdentity", "com.sknitd.NotchOrbitPlus"]))
        let now = Date(timeIntervalSince1970: 3_000_000)
        var timer = FocusTimer(); timer.start(minutes: 10, at: now)
        store.update(timer: timer, at: now)
        XCTAssertEqual(hides, [4201, 4203]); XCTAssertEqual(store.hiddenCount, 2)
        // Both original processes exited: one PID was reused by the same bundle, the other by a different app.
        running = [.init(processID: 4201, bundleID: "com.example.Editor", hidden: true, launchDate: oldLaunch.addingTimeInterval(500)),
                   .init(processID: 4203, bundleID: "com.example.Replacement", hidden: true, launchDate: oldLaunch),
                   .init(processID: 4202, bundleID: "com.example.Chat", hidden: true, launchDate: oldLaunch)]
        timer.cancel(); store.update(timer: timer, at: now.addingTimeInterval(1))
        XCTAssertTrue(unhides.isEmpty)
        XCTAssertEqual(store.hiddenCount, 0)
        XCTAssertTrue(running.allSatisfy(\.hidden))
    }
}
