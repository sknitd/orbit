import AppKit
import Foundation
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class DashboardEvaluationTests: XCTestCase {
    private let advertisedIDs = [
        "assistant", "aiUsage", "sales", "clipboard", "teleprompter", "timers", "fileShelf", "mirror",
        "calendar", "reminders", "todos", "weather", "stocks", "emoji", "converter", "system",
        "quickNote", "nowPlaying", "shortcuts", "fileActions"
    ]

    @MainActor
    func testActualAppRegistersEveryToolOnceAndMakesEveryTabSelectable() throws {
        let suite = "DashboardRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DashboardPreferences(defaults: defaults)
        let modules = NotchAppDelegate.dashboardModules(chooseFiles: {
            XCTFail("Registering or selecting a tab must not choose or transform files")
        })
        XCTAssertEqual(modules.count, 20)
        XCTAssertEqual(Set(modules.map(\.id)).count, modules.count)
        XCTAssertEqual(Set(modules.map(\.id)), Set(advertisedIDs))
        let controller = NotchDashboardController(modules: modules, preferences: preferences)
        defer { controller.stop() }
        XCTAssertEqual(preferences.registeredTools.count, 20)
        for id in advertisedIDs {
            XCTAssertTrue(controller.selectTool(id: id), id)
            XCTAssertEqual(controller.selectedToolID, id)
            XCTAssertFalse(try XCTUnwrap(controller.selectedToolTitle).isEmpty)
        }
        XCTAssertFalse(controller.selectTool(id: "unknown-tool"))
        XCTAssertNil(controller.frame, "Tab selection alone must not open a destination")
    }

    @MainActor
    func testHiddenToolsAndReorderedPreferencesSurviveARealReload() throws {
        let suite = "DashboardPreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DashboardPreferences(defaults: defaults)
        preferences.toolOrder = ["quickNote", "converter", "quickNote", "retired-tool"]
        preferences.setVisible(false, toolID: "emoji")
        preferences.setVisible(false, toolID: "weather")
        preferences.openMode = .clickOnly
        preferences.hoverDelay = 0.35
        preferences.width = 720
        preferences.displaySelection = "pointer"
        preferences.keyboardShortcutEnabled = false
        let modules = NotchAppDelegate.dashboardModules(chooseFiles: {})
        let controller = NotchDashboardController(modules: modules, preferences: preferences)
        defer { controller.stop() }
        XCTAssertEqual(Array(preferences.toolOrder.prefix(2)), ["quickNote", "converter"])
        XCTAssertEqual(preferences.toolOrder.count, 20)
        XCTAssertEqual(Set(preferences.toolOrder).count, 20)
        XCTAssertFalse(preferences.toolOrder.contains("retired-tool"))
        preferences.move("converter", by: -1)
        XCTAssertEqual(Array(preferences.toolOrder.prefix(2)), ["converter", "quickNote"])
        XCTAssertFalse(controller.selectTool(id: "emoji"))
        XCTAssertNil(controller.evaluationPNG(toolID: "weather"))
        XCTAssertNil(controller.frame)

        let reloaded = DashboardPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let restored = NotchDashboardController(modules: modules, preferences: reloaded)
        defer { restored.stop() }
        XCTAssertEqual(reloaded.toolOrder, preferences.toolOrder)
        XCTAssertEqual(reloaded.hiddenToolIDs, ["emoji", "weather"])
        XCTAssertEqual(reloaded.openMode, .clickOnly)
        XCTAssertEqual(reloaded.hoverDelay, 0.35, accuracy: 0.000_001)
        XCTAssertEqual(reloaded.width, 720)
        XCTAssertEqual(reloaded.displaySelection, "pointer")
        XCTAssertFalse(reloaded.keyboardShortcutEnabled)
        XCTAssertEqual(restored.selectedToolID, "converter")
        XCTAssertTrue(restored.selectTool(id: "quickNote"))
        XCTAssertFalse(restored.selectTool(id: "emoji"))
    }

    @MainActor
    func testAllActualToolsRenderAtMinimumWidthAndFitTheDisplay() async throws {
        let suite = "DashboardRenderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DashboardPreferences(defaults: defaults)
        preferences.toolOrder = ["converter", "todos", "quickNote", "emoji", "system"]
        preferences.width = 420 // An old narrow setting must migrate to a usable width.
        XCTAssertEqual(preferences.width, 560)
        preferences.keyboardShortcutEnabled = false
        let controller = NotchDashboardController(
            modules: NotchAppDelegate.dashboardModules(chooseFiles: {
                XCTFail("Rendering a dashboard must not execute file actions")
            }), preferences: preferences)
        defer { controller.stop() }
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        controller.show(on: screen, expanded: true)
        let output = evaluationDirectory()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for id in advertisedIDs {
            XCTAssertNotNil(controller.evaluationPNG(toolID: id), id)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(controller.selectedToolID, id)
            XCTAssertTrue(controller.isExpanded)
            let frame = try XCTUnwrap(controller.frame)
            assertSafeFrame(frame, on: screen)
            let data = try XCTUnwrap(controller.evaluationPNG(), id)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), id)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(frame.width.rounded(.down)))
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(frame.height.rounded(.down)))
            XCTAssertGreaterThan(data.count, 1_000)
            try data.write(to: output.appendingPathComponent("NotchOrbitPlus-Dashboard-\(id).png"), options: .atomic)
        }
    }

    @MainActor
    func testSuspensionRemovesTheDashboardUntilFileActionsReleaseIt() throws {
        let suite = "DashboardSuspensionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DashboardPreferences(defaults: defaults)
        preferences.toolOrder = ["converter"]
        let controller = NotchDashboardController(
            modules: NotchAppDelegate.dashboardModules(chooseFiles: {}), preferences: preferences)
        defer { controller.stop() }
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        controller.show(on: screen, expanded: true)
        XCTAssertTrue(controller.isExpanded)
        assertSafeFrame(try XCTUnwrap(controller.frame), on: screen)
        controller.setSuspended(true)
        XCTAssertNil(controller.frame)
        XCTAssertFalse(controller.isExpanded)
        XCTAssertNil(controller.evaluationPNG(toolID: "converter"))
        controller.show(on: screen, expanded: true)
        XCTAssertNil(controller.frame, "A suspended dashboard must not overlap the actual drop destination")
        controller.setSuspended(false)
        XCTAssertNotNil(controller.frame)
        XCTAssertFalse(controller.isExpanded, "Resuming returns to the compact notch")
        controller.dismiss()
        XCTAssertNil(controller.frame)
        controller.setSuspended(true)
        controller.setSuspended(false)
        XCTAssertNil(controller.frame, "An explicitly dismissed dashboard must remain dismissed")
    }

    @MainActor
    func testBundledUnicodeCatalogContainsCompleteSequencesAndSearchableNames() throws {
        let entries = try EmojiCatalog.load()
        XCTAssertEqual(entries.count, 3_944)
        XCTAssertEqual(Set(entries.map(\.emoji)).count, entries.count)
        XCTAssertTrue(entries.allSatisfy { !$0.name.isEmpty && !$0.group.isEmpty })
        for sequence in ["❤️", "🇺🇸", "👩🏽‍⚕️", "👩‍👩‍👧‍👦"] {
            XCTAssertTrue(entries.contains { $0.emoji == sequence }, sequence)
        }
        XCTAssertEqual(EmojiCatalog.search(entries, query: "🇺🇸").map(\.emoji), ["🇺🇸"])
        XCTAssertEqual(EmojiCatalog.search(entries, query: "united STATES", group: "Flags").map(\.emoji), ["🇺🇸"])
        XCTAssertTrue(EmojiCatalog.search(entries, query: "woman HEALTH medium").contains { $0.emoji == "👩🏽‍⚕️" })
        XCTAssertEqual(EmojiCatalog.search(entries, query: " ").count, 3_944)
        XCTAssertTrue(EmojiCatalog.search(entries, query: "united states", group: "Food & Drink").isEmpty)

        let provenanceURL = try XCTUnwrap(
            Bundle.main.url(forResource: "Unicode-PROVENANCE", withExtension: "json", subdirectory: "ThirdParty")
                ?? Bundle.main.url(forResource: "Unicode-PROVENANCE", withExtension: "json"))
        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: provenanceURL)) as? [String: Any])
        XCTAssertEqual(provenance["unicode_version"] as? String, "17.0")
        XCTAssertEqual(provenance["entries"] as? Int, 3_944)
        XCTAssertEqual(provenance["source_repository"] as? String, "unicode-org/unicodetools")
        XCTAssertEqual(provenance["source_commit"] as? String, "6661370193d31b1cfb28a5b854ee8a894a95edbf")
        XCTAssertEqual(provenance["source_sha256"] as? String, "1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda")
        let licenseURL = try XCTUnwrap(
            Bundle.main.url(forResource: "Unicode-LICENSE", withExtension: "txt", subdirectory: "ThirdParty")
                ?? Bundle.main.url(forResource: "Unicode-LICENSE", withExtension: "txt"))
        XCTAssertTrue(try String(contentsOf: licenseURL, encoding: .utf8).contains("SPDX-License-Identifier: Unicode-3.0"))
    }

    @MainActor
    private func assertSafeFrame(_ frame: NSRect, on screen: NSScreen,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let layout = NotchScreenLayout.layout(for: screen)
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, screen.visibleFrame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, screen.visibleFrame.maxX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.visibleFrame.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, layout.anchor.y + 0.5, file: file, line: line)
        if let notch = layout.notchRect {
            XCTAssertFalse(NotchRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height).intersects(notch),
                           file: file, line: line)
        }
    }

    private func evaluationDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["NOTCHORBITPLUS_EVAL_DIR"] ?? environment["TEST_RUNNER_NOTCHORBITPLUS_EVAL_DIR"],
           path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build", isDirectory: true).appendingPathComponent("evaluation", isDirectory: true)
    }
}
