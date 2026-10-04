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
        XCTAssertEqual(try JSONDecoder().decode([FocusAppSnapshot].self, from: recovery),
            [.init(processID: 4101, bundleID: "com.example.Editor", hidden: false, launchDate: launchDate)])
        store.restore()
        XCTAssertEqual(defaults.data(forKey: FocusAppHidingStore.recoveryKey), recovery,
            "A failed retry must preserve the original ownership record byte-for-byte")
        allowRestore = true; store.restore()
        XCTAssertEqual(store.hiddenCount, 0)
        XCTAssertNil(defaults.object(forKey: FocusAppHidingStore.recoveryKey))
        XCTAssertNil(store.error, "A successful explicit restore clears its resolved failure")
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

        // A bundle can have more running instances than the selected-bundle limit.
        // Failed restores must also leave room accounting intact on a later session.
        let capacitySuite = "FocusHideCapacity-\(UUID())"
        let capacityDefaults = try XCTUnwrap(UserDefaults(suiteName: capacitySuite))
        defer { capacityDefaults.removePersistentDomain(forName: capacitySuite) }
        var capacityRunning: [FocusAppSnapshot] = []
        for offset in 0..<33 {
            capacityRunning.append(.init(processID: Int32(5000 + offset), bundleID: "com.example.Editor", hidden: false, launchDate: oldLaunch))
        }
        var capacityHides: [Int32] = [], capacityUnhides: [Int32] = []
        var allowCapacityRestore = false
        let boundedStore = FocusAppHidingStore(defaults: capacityDefaults, ownProcessID: 9999, snapshots: { capacityRunning },
            hide: { pid in
                capacityHides.append(pid)
                capacityRunning = capacityRunning.map { .init(processID: $0.processID, bundleID: $0.bundleID,
                    hidden: $0.processID == pid || $0.hidden, launchDate: $0.launchDate) }
                return true
            }, unhide: { pid in
                capacityUnhides.append(pid)
                guard allowCapacityRestore else { return false }
                capacityRunning = capacityRunning.map { .init(processID: $0.processID, bundleID: $0.bundleID,
                    hidden: $0.processID == pid ? false : $0.hidden, launchDate: $0.launchDate) }
                return true
            })
        defer { boundedStore.shutdown() }
        boundedStore.setConfiguration(.init(enabled: true, bundleIDs: ["com.example.Editor"]))
        var capacityTimer = FocusTimer(); capacityTimer.start(minutes: 10, at: now)
        boundedStore.update(timer: capacityTimer, at: now)
        let acquiredIDs = (0..<32).map { Int32(5000 + $0) }
        XCTAssertEqual(capacityHides, acquiredIDs)
        XCTAssertEqual(boundedStore.hiddenCount, 32)
        XCTAssertFalse(capacityRunning[32].hidden, "The thirty-third process must remain visible and unowned")
        XCTAssertTrue(boundedStore.error?.contains("Restore Apps") == true)
        let boundedRecovery = try XCTUnwrap(capacityDefaults.data(forKey: FocusAppHidingStore.recoveryKey))
        let acquired = try JSONDecoder().decode([FocusAppSnapshot].self, from: boundedRecovery)
        XCTAssertEqual(acquired.map(\.processID), acquiredIDs)
        XCTAssertTrue(acquired.allSatisfy { !$0.hidden }, "Recovery retains each original pre-hide state")
        capacityTimer.pause(at: now.addingTimeInterval(1))
        boundedStore.update(timer: capacityTimer, at: now.addingTimeInterval(1))
        XCTAssertEqual(capacityUnhides, acquiredIDs)
        XCTAssertEqual(boundedStore.hiddenCount, 32)
        XCTAssertEqual(capacityDefaults.data(forKey: FocusAppHidingStore.recoveryKey), boundedRecovery)
        capacityRunning.append(.init(processID: 6000, bundleID: "com.example.Additional", hidden: false, launchDate: oldLaunch))
        boundedStore.setConfiguration(.init(enabled: true, bundleIDs: ["com.example.Editor", "com.example.Additional"]))
        capacityTimer.resume(at: now.addingTimeInterval(2))
        boundedStore.update(timer: capacityTimer, at: now.addingTimeInterval(2))
        XCTAssertEqual(capacityHides, acquiredIDs, "Pending restores prohibit all additional hides")
        XCTAssertFalse(try XCTUnwrap(capacityRunning.first { $0.processID == 6000 }).hidden)
        XCTAssertTrue(boundedStore.error?.contains("Restore Apps") == true)
        XCTAssertEqual(capacityDefaults.data(forKey: FocusAppHidingStore.recoveryKey), boundedRecovery,
                       "Refusing a new acquisition must leave all existing recovery bytes intact")
        let relaunched = FocusAppHidingStore(defaults: capacityDefaults, ownProcessID: 9999,
            snapshots: { capacityRunning }, hide: { _ in XCTFail("Recovery must never hide an app"); return false },
            unhide: { pid in
                capacityUnhides.append(pid)
                capacityRunning = capacityRunning.map { .init(processID: $0.processID, bundleID: $0.bundleID,
                    hidden: $0.processID == pid ? false : $0.hidden, launchDate: $0.launchDate) }
                return true
            })
        XCTAssertNil(relaunched.error, "The store must be able to read every recovery record it publishes")
        XCTAssertEqual(relaunched.hiddenCount, 32)
        relaunched.restore()
        XCTAssertEqual(Array(capacityUnhides.suffix(32)), acquiredIDs)
        XCTAssertEqual(relaunched.hiddenCount, 0)
        XCTAssertNil(capacityDefaults.object(forKey: FocusAppHidingStore.recoveryKey))
        XCTAssertTrue(capacityRunning.allSatisfy { !$0.hidden })
        // An externally visible process can still have a pending failed-restore
        // record. Its same identity must not be acquired a second time.
        let oneRecord = try JSONEncoder().encode([acquired[0]])
        capacityDefaults.set(oneRecord, forKey: FocusAppHidingStore.recoveryKey)
        let duplicateGuard = FocusAppHidingStore(defaults: capacityDefaults, ownProcessID: 9999,
            snapshots: { [capacityRunning[0]] },
            hide: { _ in XCTFail("An already-owned identity must not be hidden or acquired twice"); return false },
            unhide: { _ in XCTFail("An already visible app must not be restored"); return false })
        duplicateGuard.update(timer: capacityTimer, at: now.addingTimeInterval(3))
        XCTAssertEqual(duplicateGuard.hiddenCount, 1)
        XCTAssertEqual(capacityDefaults.data(forKey: FocusAppHidingStore.recoveryKey), oneRecord)
        duplicateGuard.restore()
        XCTAssertEqual(duplicateGuard.hiddenCount, 0)
        XCTAssertNil(capacityDefaults.object(forKey: FocusAppHidingStore.recoveryKey))
        allowCapacityRestore = true
    }
}
