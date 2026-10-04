import AppKit
import SwiftUI
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class AppearancePriorityEvaluationTests: XCTestCase {
    @MainActor
    func testSyncRollbackRestoresTypedPreferencesAndExactPriorStoredObjects() throws {
        let suite = "DashboardSyncRollback-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefix = "rollback-fixture."
        let unreadableHidden = Data([0x00, 0xFF, 0x18, 0x80])
        let priorOrder = ["workflows", "fileShelf"]
        let wrongTypeDelay = ["unexpected": "not a number"]
        defaults.set(unreadableHidden, forKey: prefix + "hidden")
        defaults.set(priorOrder, forKey: prefix + "order")
        defaults.set(wrongTypeDelay, forKey: prefix + "delay")
        defaults.set("local-display-fixture", forKey: prefix + "display")
        XCTAssertNil(defaults.object(forKey: prefix + "mode"))

        let preferences = DashboardPreferences(defaults: defaults, prefix: prefix)
        XCTAssertTrue(preferences.hiddenToolIDs.isEmpty)
        XCTAssertEqual(preferences.toolOrder, priorOrder)
        XCTAssertEqual(preferences.openMode, .hoverAndClick)
        XCTAssertEqual(preferences.hoverDelay, 0.2)
        let rollback = preferences.prepareSyncRollback()

        preferences.hiddenToolIDs = ["capture", "githubActions"]
        preferences.toolOrder = ["status", "capture", "workflows"]
        preferences.openMode = .clickOnly
        preferences.hoverDelay = 0.95
        XCTAssertEqual(defaults.string(forKey: prefix + "mode"), "clickOnly")
        XCTAssertEqual(defaults.stringArray(forKey: prefix + "hidden"), ["capture", "githubActions"])
        try rollback()

        XCTAssertTrue(preferences.hiddenToolIDs.isEmpty)
        XCTAssertEqual(preferences.toolOrder, priorOrder)
        XCTAssertEqual(preferences.openMode, .hoverAndClick)
        XCTAssertEqual(preferences.hoverDelay, 0.2)
        XCTAssertEqual(defaults.object(forKey: prefix + "hidden") as? Data, unreadableHidden)
        XCTAssertEqual(defaults.object(forKey: prefix + "order") as? [String], priorOrder)
        XCTAssertEqual(defaults.object(forKey: prefix + "delay") as? [String: String], wrongTypeDelay)
        XCTAssertNil(defaults.object(forKey: prefix + "mode"), "An absent key must stay absent, rather than storing its UI fallback")
        XCTAssertEqual(defaults.string(forKey: prefix + "display"), "local-display-fixture")
        let restored = DashboardPreferences(defaults: defaults, prefix: prefix)
        XCTAssertEqual(restored.hiddenToolIDs, preferences.hiddenToolIDs)
        XCTAssertEqual(restored.toolOrder, preferences.toolOrder)
        XCTAssertEqual(restored.openMode, preferences.openMode)
        XCTAssertEqual(restored.hoverDelay, preferences.hoverDelay)
    }

    @MainActor
    func testActualDashboardSettingsRenderLocalDisplayAndSpacePreferencesWithoutPermissionActions() async throws {
        let suite = "DashboardDisplaySpaceEvaluation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let displayID = try XCTUnwrap(NotchScreenLayout.screenID(for: screen))
        let preferences = DashboardPreferences(defaults: defaults)
        preferences.keyboardShortcutEnabled = false
        preferences.spaceBehavior = .currentSpace
        preferences.hideInFullscreen = false
        preferences.displaySelection = "id:\(displayID)"
        preferences.setDisplayRule(.init(enabled: true, width: 680), id: displayID)
        preferences.setVisible(false, toolID: "githubActions")
        let controller = NotchDashboardController(modules: NotchAppDelegate.dashboardModules(chooseFiles: {
            XCTFail("Settings rendering must not select or transform files")
        }), preferences: preferences)
        defer { controller.stop() }
        XCTAssertEqual(preferences.registeredTools.count, 31)
        XCTAssertNil(controller.frame)
        let rulesBefore = preferences.displayRules
        try await NativeFeatureEvaluation.render(AnyView(DashboardSettingsView(preferences: preferences)),
            named: "NotchOrbitPlus-DashboardSettings-fixture-display-spaces.png", size: NSSize(width: 560, height: 760))
        XCTAssertNil(controller.frame, "A settings preview does not open the dashboard")
        XCTAssertEqual(preferences.displayRules, rulesBefore)
        let restored = DashboardPreferences(defaults: defaults)
        XCTAssertEqual(restored.spaceBehavior, .currentSpace)
        XCTAssertFalse(restored.hideInFullscreen)
        XCTAssertEqual(restored.displaySelection, "id:\(displayID)")
        XCTAssertEqual(restored.displayRule(displayID), .init(enabled: true, width: 680))
        XCTAssertTrue(restored.hiddenToolIDs.contains("githubActions"))
    }

    @MainActor
    func testNativeAppearanceAndPriorityPersistAndRenderWithoutImplicitChanges() async throws {
        let suite = "AppearancePriorityEvaluation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var changes = 0
        let appearance = PlusAppearanceStore(defaults: defaults, onChange: { changes += 1 })
        let priority = PlusLivePriorityStore(defaults: defaults, onChange: { changes += 1 })
        XCTAssertNil(defaults.data(forKey: PlusAppearanceStore.defaultsKey))
        XCTAssertNil(defaults.data(forKey: PlusLivePriorityStore.defaultsKey))
        XCTAssertFalse(appearance.settings.dropSound)
        let chosen = CoreAppearancePreferences(theme: .dark, accent: .teal, dropSound: false)
        try appearance.applySynced(chosen)
        let order: [LiveNotchKind] = [.music, .hud, .processing, .meeting, .focus, .devices, .status]
        try priority.applySynced(.init(order: order))
        XCTAssertEqual(appearance.preferredColorScheme, .dark)
        XCTAssertEqual(appearance.panelAppearance?.name, .darkAqua)
        let savedAppearance = defaults.data(forKey: PlusAppearanceStore.defaultsKey)
        let savedPriority = defaults.data(forKey: PlusLivePriorityStore.defaultsKey)
        try await NativeFeatureEvaluation.render(AnyView(AppearanceSettingsView(store: appearance)),
            named: "NotchOrbitPlus-Appearance-fixture-dark.png", size: NSSize(width: 560, height: 560),
            appearance: appearance.panelAppearance)
        try await NativeFeatureEvaluation.render(AnyView(LivePrioritySettingsView(store: priority)),
            named: "NotchOrbitPlus-Priority-fixture-custom.png", size: NSSize(width: 560, height: 560))
        XCTAssertEqual(changes, 0, "Rendering or applying incoming settings does not announce a user edit")
        XCTAssertEqual(defaults.data(forKey: PlusAppearanceStore.defaultsKey), savedAppearance)
        XCTAssertEqual(defaults.data(forKey: PlusLivePriorityStore.defaultsKey), savedPriority)
        XCTAssertEqual(PlusAppearanceStore(defaults: defaults, onChange: {}).settings, chosen)
        XCTAssertEqual(PlusLivePriorityStore(defaults: defaults, onChange: {}).priorityOrder, order)
        let statuses = [LiveNotchStatus(id: "job", kind: .processing, title: "Processing fixture", toolID: "workflows", progress: 0.5),
                        LiveNotchStatus(id: "song", kind: .music, title: "Priority fixture song", detail: "Fixture artist", toolID: "nowPlaying")]
        XCTAssertEqual(LiveNotchSelection.ordered(statuses, priorityOrder: priority.priorityOrder).map(\.id), ["song", "job"])
        try await NativeFeatureEvaluation.render(AnyView(LiveCompactContent(statuses: statuses, priorityOrder: priority.priorityOrder)
            .padding(.horizontal, 12).frame(width: 260, height: 38).background(.black).foregroundStyle(.white)),
            named: "NotchOrbitPlus-Compact-fixture-custom-priority.png", size: NSSize(width: 260, height: 38))
    }

    @MainActor
    func testUnreadablePreferenceBytesAreRetainedUntilExplicitBackupReset() throws {
        let suite = "AppearancePriorityMalformed-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let malformedAppearance = Data(#"{"theme":"unknown","accent":"teal","dropSound":false}"#.utf8)
        let malformedPriority = Data(#"{"order":["music","music"]}"#.utf8)
        defaults.set(malformedAppearance, forKey: PlusAppearanceStore.defaultsKey)
        defaults.set(malformedPriority, forKey: PlusLivePriorityStore.defaultsKey)
        var changes = 0
        let appearance = PlusAppearanceStore(defaults: defaults, onChange: { changes += 1 })
        let priority = PlusLivePriorityStore(defaults: defaults, onChange: { changes += 1 })
        XCTAssertNotNil(appearance.error)
        XCTAssertNotNil(priority.error)
        XCTAssertThrowsError(try appearance.exportSyncSettings())
        XCTAssertThrowsError(try priority.exportSyncSettings())
        appearance.update(theme: .light)
        priority.move(.music, by: -1)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(defaults.data(forKey: PlusAppearanceStore.defaultsKey), malformedAppearance)
        XCTAssertEqual(defaults.data(forKey: PlusLivePriorityStore.defaultsKey), malformedPriority)
        appearance.resetKeepingBackup()
        priority.resetKeepingBackup()
        XCTAssertEqual(changes, 2)
        let stored = defaults.dictionaryRepresentation()
        let appearanceBackups = stored.filter { $0.key.hasPrefix(PlusAppearanceStore.defaultsKey + ".backup.") }
        let priorityBackups = stored.filter { $0.key.hasPrefix(PlusLivePriorityStore.defaultsKey + ".backup.") }
        XCTAssertEqual(appearanceBackups.count, 1)
        XCTAssertEqual(priorityBackups.count, 1)
        XCTAssertEqual(appearanceBackups.values.first as? Data, malformedAppearance)
        XCTAssertEqual(priorityBackups.values.first as? Data, malformedPriority)
        XCTAssertEqual(PlusAppearanceStore(defaults: defaults, onChange: {}).settings, CoreAppearancePreferences())
        XCTAssertEqual(PlusLivePriorityStore(defaults: defaults, onChange: {}).priorityOrder, LiveNotchKind.defaultOrder)
    }
}
