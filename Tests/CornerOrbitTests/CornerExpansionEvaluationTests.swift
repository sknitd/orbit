import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
import CornerCore
@testable import CornerOrbit

final class CornerExpansionEvaluationTests: XCTestCase {
    @MainActor
    func testVersionOnePreferencesRetainTheirBindingsWithoutStartingNewServices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CornerExpansionMigration-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldGestures = ["singleClick", "doubleClick", "tripleClick", "dragIntoCorner", "dragOutOfCorner"]
        var corners: [String: Any] = [:]
        for corner in ["topLeft", "topRight", "bottomLeft", "bottomRight"] {
            var bindings: [String: Any] = [:]
            for gesture in oldGestures {
                bindings[gesture] = ["kind": "openURL", "url": "https://example.com/v1/\(corner)/\(gesture)"]
            }
            corners[corner] = ["enabled": true, "bindings": bindings]
        }
        let oldSettings: [String: Any] = ["schemaVersion": 1, "enabled": false, "corners": corners,
            "cornerSize": 24, "clickInterval": 0.32, "dragThreshold": 12, "cooldown": 0.6,
            "modifierRequirement": 0, "enabledDisplayIDs": []]
        let original = try JSONSerialization.data(withJSONObject: ["settings": oldSettings, "automationEnabled": true, "showHints": true])
        let persistence = CornerPreferencesPersistence(directory: directory)
        try original.write(to: persistence.file)
        let loaded = try persistence.load()
        XCTAssertTrue(loaded.automationEnabled); XCTAssertTrue(loaded.showHints)
        XCTAssertFalse(loaded.settings.enabled)
        XCTAssertEqual(CornerGesture.allCases.count, 13)
        for corner in Corner.allCases {
            let configuration = try XCTUnwrap(loaded.settings.corners[corner])
            for gesture in CornerGesture.allCases {
                if oldGestures.contains(gesture.rawValue) {
                    XCTAssertEqual(configuration.action(for: gesture).url, "https://example.com/v1/\(corner.rawValue)/\(gesture.rawValue)")
                } else {
                    XCTAssertEqual(configuration.action(for: gesture), .none, "Migration must not arm a new gesture")
                }
            }
        }
        let fixture = makeFixture(preferences: loaded)
        defer { fixture.store.shutdown() }
        fixture.store.resume()
        XCTAssertEqual(fixture.input.requests, 0); XCTAssertEqual(fixture.input.installs, 0)
        XCTAssertTrue(fixture.workspace.opened.isEmpty)
        XCTAssertEqual(try Data(contentsOf: persistence.file), original, "Loading alone must preserve v1 bytes")
    }

    @MainActor
    func testBindingUndoRedoKeepsPermissionAndMonitoringChoicesAndNeverRunsActions() throws {
        let fixture = makeFixture()
        defer { fixture.store.shutdown() }
        let chosen = CornerAction(kind: .windowLeft)
        try fixture.store.assign(chosen, to: .topRight, gesture: .rightDoubleClick)
        fixture.store.setAutomation(true)
        fixture.input.authorized = true
        fixture.store.setMonitoring(true)
        XCTAssertTrue(fixture.store.monitor.isEnabled)
        XCTAssertTrue(fixture.store.canUndoBinding)
        fixture.store.undoBinding()
        XCTAssertEqual(fixture.store.action(corner: .topRight, gesture: .rightDoubleClick), .none)
        XCTAssertTrue(fixture.store.preferences.automationEnabled)
        XCTAssertTrue(fixture.store.preferences.settings.enabled)
        XCTAssertTrue(fixture.store.monitor.isEnabled)
        XCTAssertTrue(fixture.store.canRedoBinding)
        fixture.store.redoBinding()
        XCTAssertEqual(fixture.store.action(corner: .topRight, gesture: .rightDoubleClick), chosen)
        XCTAssertTrue(fixture.store.preferences.automationEnabled)
        XCTAssertTrue(fixture.store.preferences.settings.enabled)
        XCTAssertEqual(fixture.input.requests, 0)
        XCTAssertEqual(fixture.input.installs, 1, "Undo/redo reconfigures the existing listener")
        XCTAssertTrue(fixture.workspace.opened.isEmpty)
    }

    @MainActor
    func testTimedPauseAndProfileChangesNeverEnableAnOriginallyDisabledMonitorOrPromptOnResume() throws {
        let context = ExpansionProfileContext()
        let profiles = CornerProfilesStore(persistence: nil, contextSource: context,
            initialArchive: .init(excludedAppIDs: ["com.example.BlockedApp"]))
        let fixture = makeFixture(profiles: profiles)
        defer { fixture.store.shutdown() }
        fixture.store.pause(minutes: 5)
        XCTAssertTrue(fixture.store.timedPause.isPaused)
        try fixture.store.applyProfileSettings(.samplePreset)
        fixture.store.resumePausedGestures()
        XCTAssertFalse(fixture.store.monitor.isEnabled)
        XCTAssertFalse(fixture.store.preferences.settings.enabled)
        XCTAssertEqual(fixture.input.preflights, 0); XCTAssertEqual(fixture.input.requests, 0)
        fixture.input.authorized = true
        fixture.store.setMonitoring(true)
        XCTAssertTrue(fixture.store.monitor.isEnabled)
        fixture.store.pause(minutes: 15)
        XCTAssertFalse(fixture.store.monitor.isEnabled)
        try fixture.store.applyProfileSettings(.defaults)
        XCTAssertTrue(fixture.store.preferences.settings.enabled, "Profiles preserve the user's monitoring choice")
        fixture.store.resumePausedGestures()
        XCTAssertTrue(fixture.store.monitor.isEnabled)
        XCTAssertEqual(fixture.input.requests, 0, "Timed resume uses preflight only")
        fixture.store.resume()
        context.emit("com.example.BlockedApp")
        XCTAssertTrue(fixture.store.isExcluded)
        XCTAssertFalse(fixture.store.monitor.isEnabled)
        fixture.store.pause(minutes: 5); fixture.store.resumePausedGestures()
        XCTAssertFalse(fixture.store.monitor.isEnabled, "Timed resume cannot override an excluded app")
        context.emit("com.example.OrdinaryApp")
        XCTAssertFalse(fixture.store.isExcluded)
        XCTAssertTrue(fixture.store.monitor.isEnabled)
        fixture.store.pause(minutes: 60)
        fixture.store.setMonitoring(false)
        fixture.store.resumePausedGestures()
        XCTAssertFalse(fixture.store.monitor.isEnabled)
        XCTAssertFalse(fixture.store.preferences.settings.enabled)
        XCTAssertTrue(fixture.workspace.opened.isEmpty)
    }

    @MainActor
    func testPracticeUsesNativeAdapterWithoutExecutingBindingsThenFreshNormalGestureRoutesOnce() async throws {
        let fixture = makeFixture()
        defer { fixture.store.shutdown() }
        let address = "https://example.com/explicit-practice-exit"
        try fixture.store.assign(.init(kind: .openURL, url: address), to: .topLeft, gesture: .singleClick)
        fixture.input.authorized = true; fixture.store.setMonitoring(true)
        var recognized: [CornerTrigger] = []
        fixture.store.monitor.onPractice = { recognized.append($0) }
        fixture.store.perform(.init(kind: .openURL, url: "https://example.com/queued-before-practice"))
        fixture.store.setPractice(true)
        try await waitUntil { !fixture.store.isRunningAction }
        XCTAssertTrue(fixture.workspace.opened.isEmpty, "Entering practice cancels queued normal actions")
        let receive = try XCTUnwrap(fixture.input.receiver)
        receive(.init(kind: .down, timestamp: 0, point: .init(x: 1, y: 799)))
        receive(.init(kind: .up, timestamp: 0.01, point: .init(x: 1, y: 799)))
        fixture.input.now = 0.6; fixture.store.monitor.flushPending()
        try await waitUntil { recognized.count == 1 }
        XCTAssertEqual(recognized.first?.gesture, .singleClick)
        XCTAssertTrue(fixture.workspace.opened.isEmpty)
        XCTAssertTrue(fixture.store.monitor.lastPractice?.contains(CornerGesture.singleClick.title) == true)
        XCTAssertEqual(fixture.store.action(corner: .topLeft, gesture: .singleClick).url, address)
        fixture.store.page = .gestures
        try await CornerNativeEvaluation.render(AnyView(CornerSettingsView(store: fixture.store)),
            named: "CornerOrbit-v02-Gestures-practice-fixture.png", size: NSSize(width: 1000, height: 900))
        fixture.store.setPractice(false)
        receive(.init(kind: .down, timestamp: 1, point: .init(x: 1, y: 799)))
        receive(.init(kind: .up, timestamp: 1.01, point: .init(x: 1, y: 799)))
        fixture.input.now = 1.6; fixture.store.monitor.flushPending()
        try await waitUntil { fixture.workspace.opened.count == 1 && !fixture.store.isRunningAction }
        XCTAssertEqual(fixture.workspace.opened.map(\.absoluteString), [address])
        XCTAssertEqual(recognized.count, 1)
        XCTAssertEqual(fixture.input.requests, 0)
    }

    @MainActor
    func testActualExpandedPagesAndSearchableWindowEditorRenderOnlySyntheticState() async throws {
        let profile = CornerProfile(name: "Synthetic Writing", settings: .samplePreset)
        var secondSettings = CornerSettings.defaults
        secondSettings.corners[.bottomLeft, default: .init()].bindings[.hover] = .init(kind: .favoriteWebsites)
        let second = CornerProfile(name: "Synthetic Research", settings: secondSettings)
        let archive = CornerProfilesArchive(profiles: [profile, second], activeProfileID: profile.id,
            rules: [.init(bundleID: "com.apple.TextEdit", profileID: profile.id)], excludedAppIDs: ["com.apple.Terminal"])
        let profiles = CornerProfilesStore(preview: true, initialArchive: archive)
        let favorites = [CornerFavorite(title: "Synthetic Documentation", url: try XCTUnwrap(URL(string: "https://example.com/docs"))),
            CornerFavorite(title: "Synthetic Reference", url: try XCTUnwrap(URL(string: "https://example.org/reference")))]
        let group = CornerLinkGroup(name: "Synthetic Research Tabs", urls: favorites.map(\.url))
        let links = CornerLinkStore(preview: true, previewFavorites: favorites, previewGroups: [group])
        let clipboard = CornerClipboardStore(preview: true, previewText: "{\"count\":9007199254740993,\"labels\":[\"alpha\",\"beta\"]}")
        clipboard.mode = .jsonPretty; try clipboard.preview()
        let store = CornerAppStore(preferences: .init(settings: .samplePreset), history: ChromeHistoryStore(previewEntries: []),
            recent: RecentlyOpenedStore(previewEntries: []), isPreview: true, profiles: profiles, links: links, clipboard: clipboard)
        defer { store.shutdown() }
        for (page, name) in [(CornerSettingsPage.profiles, "Profiles"), (.gestures, "GestureOptions"), (.clipboard, "Clipboard-JSON"), (.links, "Favorites-and-Groups")] {
            store.page = page
            try await CornerNativeEvaluation.render(AnyView(CornerSettingsView(store: store)),
                named: "CornerOrbit-v02-\(name)-fixture.png", size: NSSize(width: 1000, height: 900))
        }
        try await CornerNativeEvaluation.render(AnyView(CornerFavoriteEditorView(links: links, favorite: favorites[0])),
            named: "CornerOrbit-v02-Favorite-editor-fixture.png", size: NSSize(width: 640, height: 420))
        try await CornerNativeEvaluation.render(AnyView(CornerURLGroupEditorView(links: links, group: group)),
            named: "CornerOrbit-v02-URL-group-editor-fixture.png", size: NSSize(width: 640, height: 520))
        try profiles.previewImport(data: CornerProfileDocument(profiles: [second]).encoded())
        let importPreview = try XCTUnwrap(profiles.importPreview)
        XCTAssertEqual(profiles.profiles.count, 2)
        XCTAssertEqual(profiles.activeProfileID, profile.id)
        XCTAssertEqual(importPreview.count, 1)
        XCTAssertFalse(importPreview.renamedProfiles.isEmpty)
        try await CornerNativeEvaluation.render(AnyView(CornerProfileImportReview(profiles: profiles, preview: importPreview)),
            named: "CornerOrbit-v02-Profile-import-review-fixture.png", size: NSSize(width: 760, height: 620))
        profiles.cancelImport()
        try store.assign(.init(kind: .windowLeft), to: .topRight, gesture: .rightDoubleClick)
        try await CornerNativeEvaluation.render(AnyView(CornerBindingEditorView(store: store, corner: .topRight,
            gesture: .rightDoubleClick, initialSearch: "window")), named: "CornerOrbit-v02-Window-editor-search-fixture.png",
            size: NSSize(width: 660, height: 700))
        XCTAssertFalse(store.monitor.isEnabled); XCTAssertFalse(store.preferences.automationEnabled)
    }

    @MainActor
    func testActualAppClipboardRoutingPreservesJSONNumbersAndRefusesUndoAfterAnotherWriter() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("CornerExpansionClipboard-\(UUID())"))
        defer { board.clearContents() }
        let original = "{\"count\":9007199254740993,\"labels\":[\"alpha\",\"beta\"]}"
        board.clearContents(); XCTAssertTrue(board.setString(original, forType: .string))
        let clipboard = CornerClipboardStore(pasteboard: board)
        let fixture = makeFixture(clipboard: clipboard)
        defer { fixture.store.shutdown() }
        fixture.store.perform(.init(kind: .clipboardJSONPretty))
        try await waitUntil { !fixture.store.isRunningAction }
        XCTAssertNil(fixture.store.errorMessage)
        let formatted = try XCTUnwrap(board.string(forType: .string))
        XCTAssertTrue(formatted.contains("\n")); XCTAssertTrue(formatted.contains("9007199254740993"))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(formatted.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["labels"] as? [String], ["alpha", "beta"])
        let newer = "Synthetic content from a different clipboard writer"
        board.clearContents(); XCTAssertTrue(board.setString(newer, forType: .string))
        fixture.store.perform(.init(kind: .clipboardUndo))
        try await waitUntil { !fixture.store.isRunningAction }
        XCTAssertNotNil(fixture.store.errorMessage)
        XCTAssertEqual(board.string(forType: .string), newer)
        XCTAssertTrue(fixture.workspace.opened.isEmpty)
        XCTAssertEqual(fixture.input.requests, 0)
    }

    @MainActor
    func testFailedProfilePublicationRetainsOldBindingsAndSelectionAndPausesUntilSuccessfulRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CornerExpansionProfileFailure-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = CornerPreferencesPersistence(directory: directory)
        try initial.save(.defaults)
        let gate = ExpansionPublicationGate()
        let persistence = CornerPreferencesPersistence(directory: directory, publish: { try gate.publish($0, $1) })
        var settings = CornerSettings.defaults
        settings.corners[.topLeft, default: .init()].bindings[.singleClick] = .init(kind: .openURL, url: "https://example.com/profile-retry")
        let profile = CornerProfile(name: "Synthetic Retry Profile", settings: settings)
        let profiles = CornerProfilesStore(persistence: nil, initialArchive: .init(profiles: [profile]))
        let fixture = makeFixture(profiles: profiles, persistence: persistence)
        defer { fixture.store.shutdown() }
        fixture.input.authorized = true; fixture.store.setMonitoring(true)
        XCTAssertTrue(fixture.store.monitor.isEnabled)
        let original = try Data(contentsOf: persistence.file)
        gate.setFailing(true)
        XCTAssertThrowsError(try profiles.activate(id: profile.id))
        XCTAssertNil(profiles.activeProfileID)
        XCTAssertEqual(fixture.store.action(corner: .topLeft, gesture: .singleClick), .none)
        XCTAssertEqual(try Data(contentsOf: persistence.file), original)
        XCTAssertFalse(fixture.store.monitor.isEnabled)
        XCTAssertNotNil(fixture.store.errorMessage)
        XCTAssertTrue(fixture.store.suspensionReason?.contains("profile") == true)
        fixture.store.pause(minutes: 5); fixture.store.resumePausedGestures(); fixture.store.resume()
        XCTAssertFalse(fixture.store.monitor.isEnabled, "An old requested monitoring preference cannot bypass profile failure")
        fixture.store.page = .profiles
        try await CornerNativeEvaluation.render(AnyView(CornerSettingsView(store: fixture.store)),
            named: "CornerOrbit-v02-Profile-apply-failure-fixture.png", size: NSSize(width: 1000, height: 900))
        gate.setFailing(false)
        try profiles.activate(id: profile.id)
        XCTAssertEqual(profiles.activeProfileID, profile.id)
        XCTAssertEqual(fixture.store.action(corner: .topLeft, gesture: .singleClick).url, "https://example.com/profile-retry")
        XCTAssertTrue(fixture.store.monitor.isEnabled)
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertEqual(fixture.input.requests, 0)
        XCTAssertTrue(fixture.workspace.opened.isEmpty)
    }

    @MainActor
    private func makeFixture(preferences: CornerPreferences = .defaults, clipboard: CornerClipboardStore? = nil,
                             profiles: CornerProfilesStore? = nil, persistence: CornerPreferencesPersistence? = nil) -> ExpansionFixture {
        let input = ExpansionInput(), workspace = ExpansionWorkspace()
        let dependencies = CornerMonitorDependencies(preflightAccess: { input.preflights += 1; return input.authorized },
            requestAccess: { input.requests += 1; return false },
            screens: { [.init(id: "synthetic-expansion-display", frame: .init(x: 0, y: 0, width: 1200, height: 800))] },
            installMouseEvents: { receive in input.installs += 1; input.receiver = receive; return input.source }, now: { input.now })
        let store = CornerAppStore(preferences: preferences, persistence: persistence, monitorDependencies: dependencies,
            actionRunner: CornerActionRunner(workspace: workspace, scripts: ExpansionScripts()),
            history: ChromeHistoryStore(previewEntries: []), recent: RecentlyOpenedStore(previewEntries: []), profiles: profiles, clipboard: clipboard)
        return .init(store: store, input: input, workspace: workspace)
    }

    @MainActor
    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The actual injected expansion operation did not finish")
    }
}

@MainActor
private struct ExpansionFixture {
    let store: CornerAppStore
    let input: ExpansionInput
    let workspace: ExpansionWorkspace
}
@MainActor
private final class ExpansionInput {
    var preflights = 0, requests = 0, installs = 0
    var authorized = false
    var now: Double = 0
    let source = ExpansionMouseSource()
    var receiver: (@MainActor (CornerMouseSample) -> Void)?
}
@MainActor
private final class ExpansionMouseSource: CornerMouseEventSource { func stop() {} }
@MainActor
private final class ExpansionWorkspace: CornerWorkspaceAccessing {
    var opened: [URL] = []
    func applicationURL(bundleID: String) -> URL? { URL(fileURLWithPath: "/synthetic-expansion-app/Browser.app") }
    func openApplication(at url: URL) async throws { XCTFail("Expansion evaluation must not launch target apps") }
    func openWebsite(_ url: URL, in application: URL) async throws { opened.append(url) }
    func openDirectory(_ url: URL) async throws { XCTFail("Expansion evaluation must not open folders") }
}
private actor ExpansionScripts: CornerScriptExecuting {
    func execute(_ request: CornerAppleScriptRequest) async throws { XCTFail("Expansion evaluation must not request Automation") }
}

@MainActor
private final class ExpansionProfileContext: CornerProfileContextSource {
    var currentBundleID: String? = "com.example.OrdinaryApp"
    private var callback: (@MainActor (String?) -> Void)?
    func start(_ onChange: @escaping @MainActor (String?) -> Void) { callback = onChange }
    func stop() { callback = nil }
    func emit(_ identifier: String) { currentBundleID = identifier; callback?(identifier) }
}

private enum ExpansionPublicationFailure: Error { case intentionalBeforeCommit }
private final class ExpansionPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    func setFailing(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
    func publish(_ staging: URL, _ final: URL) throws {
        lock.lock(); let shouldFail = failing; lock.unlock()
        if shouldFail { throw ExpansionPublicationFailure.intentionalBeforeCommit }
        guard rename(staging.path, final.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
