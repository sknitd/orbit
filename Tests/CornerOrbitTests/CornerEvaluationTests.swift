import AppKit
import SwiftUI
import XCTest
import CornerCore
@testable import CornerOrbit

final class CornerEvaluationTests: XCTestCase {
    @MainActor
    func testAllTwentyAssignmentsAndPresetAreDataOnlyAndPersistWithoutImplicitAccess() async throws {
        let suite = "CornerEvaluationDataOnly-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CornerEvaluation-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = CornerPreferencesPersistence(directory: directory)
        let fixture = makeStore(defaults: defaults, persistence: persistence)
        defer { fixture.store.shutdown() }
        XCTAssertEqual(fixture.permission.preflights, 0)
        XCTAssertEqual(fixture.permission.requests, 0)
        XCTAssertEqual(fixture.permission.installs, 0)
        for corner in Corner.allCases {
            for gesture in CornerGesture.allCases {
                let address = "https://example.com/\(corner.rawValue)/\(gesture.rawValue)"
                try fixture.store.assign(.init(kind: .openURL, url: address), to: corner, gesture: gesture)
                XCTAssertEqual(fixture.store.action(corner: corner, gesture: gesture).url, address)
            }
        }
        let saved = try persistence.load()
        XCTAssertEqual(saved, fixture.store.preferences)
        XCTAssertEqual(saved.settings.corners.values.reduce(0) { $0 + $1.bindings.count }, 20)
        XCTAssertFalse(saved.settings.enabled)
        fixture.store.setAutomation(true)
        XCTAssertTrue(fixture.store.preferences.automationEnabled)
        fixture.store.applyPreset()
        XCTAssertEqual(fixture.store.preferences.settings, .samplePreset)
        XCTAssertFalse(fixture.store.preferences.settings.enabled)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fixture.workspace.openedWebsites.isEmpty)
        XCTAssertTrue(fixture.workspace.openedApplications.isEmpty)
        XCTAssertEqual(fixture.permission.requests, 0)
        XCTAssertEqual(fixture.permission.installs, 0)
        let scriptCalls = await fixture.scripts.calls
        let historyCalls = await fixture.reader.calls
        XCTAssertEqual(scriptCalls, 0); XCTAssertEqual(historyCalls, 0)
    }

    @MainActor
    func testInputMonitoringDenialRequiresExplicitEnableAndSurfacesNativeRecoveryInstructions() async throws {
        let suite = "CornerEvaluationPermission-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = makeStore(defaults: defaults)
        defer { fixture.store.shutdown() }
        XCTAssertFalse(fixture.store.monitor.isEnabled)
        XCTAssertEqual(fixture.permission.preflights, 0)
        fixture.store.setMonitoring(true)
        XCTAssertEqual(fixture.permission.requests, 1)
        XCTAssertEqual(fixture.permission.preflights, 2)
        XCTAssertEqual(fixture.permission.installs, 0)
        XCTAssertFalse(fixture.store.monitor.isEnabled)
        XCTAssertEqual(fixture.store.monitor.status, .inputMonitoringRequired)
        XCTAssertTrue(fixture.store.monitor.diagnostic.contains("Input Monitoring"))
        fixture.store.resume()
        XCTAssertEqual(fixture.permission.requests, 1, "Restoring a requested setting must never ask for permission again")
        fixture.store.page = .behavior
        try await CornerNativeEvaluation.render(AnyView(CornerSettingsView(store: fixture.store)),
            named: "CornerOrbit-Settings-input-monitoring-denied-fixture.png", size: NSSize(width: 960, height: 760))
        XCTAssertEqual(fixture.permission.requests, 1, "Rendering recovery instructions must not request access")
        XCTAssertEqual(fixture.permission.installs, 0)
        fixture.store.setMonitoring(false)
        XCTAssertFalse(fixture.store.preferences.settings.enabled)
        XCTAssertEqual(fixture.store.monitor.status, .disabled)
        let historyCalls = await fixture.reader.calls
        XCTAssertEqual(historyCalls, 0)
    }

    @MainActor
    func testActualStoreDisableCancelsDelayedBindingThenNewGestureRunsOnlyItsConfiguredWebsite() async throws {
        let suite = "CornerEvaluationDelayedGesture-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = makeStore(defaults: defaults)
        defer { fixture.store.shutdown() }
        fixture.permission.authorized = true
        let address = "https://example.com/explicit-corner-action"
        try fixture.store.assign(.init(kind: .openURL, url: address), to: .topLeft, gesture: .singleClick)
        fixture.store.setMonitoring(true)
        XCTAssertTrue(fixture.store.monitor.isEnabled)
        XCTAssertEqual(fixture.permission.installs, 1)
        let receive = try XCTUnwrap(fixture.permission.receiver)
        let corner = CornerPoint(x: 1, y: 799)
        receive(.init(kind: .down, timestamp: 0, point: corner))
        receive(.init(kind: .up, timestamp: 0.01, point: corner))
        XCTAssertTrue(fixture.workspace.openedWebsites.isEmpty, "A single click waits for multi-click disambiguation")
        fixture.store.setMonitoring(false)
        fixture.permission.now = 1
        fixture.store.monitor.flushPending()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fixture.workspace.openedWebsites.isEmpty)
        XCTAssertEqual(fixture.permission.source.stops, 1)
        fixture.store.setMonitoring(true)
        let freshReceive = try XCTUnwrap(fixture.permission.receiver)
        freshReceive(.init(kind: .down, timestamp: 1.1, point: corner))
        freshReceive(.init(kind: .up, timestamp: 1.11, point: corner))
        fixture.permission.now = 2
        fixture.store.monitor.flushPending()
        try await waitUntil { fixture.workspace.openedWebsites.count == 1 && !fixture.store.isRunningAction }
        XCTAssertEqual(fixture.workspace.openedWebsites.map(\.absoluteString), [address])
        XCTAssertEqual(fixture.workspace.resolvedBundleIDs, ["com.google.Chrome"])
        XCTAssertTrue(fixture.workspace.openedApplications.isEmpty)
        XCTAssertTrue(fixture.store.recent.entries.isEmpty, "Successful actions do not enable optional local history")
        XCTAssertEqual(fixture.permission.requests, 0, "An injected existing grant never requests a new grant")
        let scriptCalls = await fixture.scripts.calls
        XCTAssertEqual(scriptCalls, 0)
    }

    @MainActor
    func testActionErrorsPreserveBindingsAndRecentWebsitesRequireSuccessfulExplicitOptInOpens() async throws {
        let suite = "CornerEvaluationActionErrors-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = makeStore(defaults: defaults)
        defer { fixture.store.shutdown() }
        let chosen = CornerAction(kind: .newWord)
        try fixture.store.assign(chosen, to: .bottomRight, gesture: .tripleClick)
        fixture.store.perform(chosen)
        try await waitUntil { !fixture.store.isRunningAction }
        XCTAssertTrue(fixture.store.errorMessage?.contains("Automation") == true)
        XCTAssertEqual(fixture.store.action(corner: .bottomRight, gesture: .tripleClick), chosen)
        XCTAssertTrue(fixture.workspace.resolvedBundleIDs.isEmpty)
        XCTAssertTrue(fixture.workspace.openedApplications.isEmpty)
        fixture.store.page = .corners
        fixture.store.selectedCorner = .bottomRight
        try await CornerNativeEvaluation.render(AnyView(CornerSettingsView(store: fixture.store)),
            named: "CornerOrbit-Settings-action-error-fixture.png", size: NSSize(width: 960, height: 760))
        let address = "https://example.com/intentional-open"
        fixture.store.perform(.init(kind: .openURL, url: address))
        try await waitUntil { !fixture.store.isRunningAction }
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertTrue(fixture.store.recent.entries.isEmpty)
        fixture.store.recent.setEnabled(true)
        fixture.store.perform(.init(kind: .openURL, url: address))
        try await waitUntil { !fixture.store.isRunningAction }
        XCTAssertEqual(fixture.store.recent.entries.map(\.url.absoluteString), [address])
        fixture.workspace.refuseOpens = true
        fixture.store.perform(.init(kind: .openURL, url: "https://example.org/refused-open"))
        try await waitUntil { !fixture.store.isRunningAction }
        XCTAssertNotNil(fixture.store.errorMessage)
        XCTAssertEqual(fixture.store.recent.entries.map(\.url.absoluteString), [address], "Failed opens must not become recorded success")
        let scriptCalls = await fixture.scripts.calls
        XCTAssertEqual(scriptCalls, 0)
    }

    @MainActor
    func testActualSettingsAndBindingEditorRenderAllFourCornersWithoutEnablingMonitoring() async throws {
        let now = Date()
        let chrome = CornerHistoryEntry(url: try XCTUnwrap(URL(string: "https://example.com/reference")),
            title: "Synthetic Chrome history reference", lastVisited: now.addingTimeInterval(-60), source: .chrome)
        let recent = CornerHistoryEntry(url: try XCTUnwrap(URL(string: "https://example.org/notes")),
            title: "Synthetic explicitly opened website", lastVisited: now.addingTimeInterval(-120), source: .recent)
        let store = CornerAppStore.preview(settings: .samplePreset, historyEntries: [chrome], recentEntries: [recent])
        for corner in Corner.allCases {
            let configuration = try XCTUnwrap(store.preferences.settings.corners[corner])
            XCTAssertEqual(Set(configuration.bindings.keys), Set(CornerGesture.allCases))
        }
        XCTAssertFalse(store.preferences.settings.enabled)
        store.page = .corners
        try await CornerNativeEvaluation.render(AnyView(CornerSettingsView(store: store)),
            named: "CornerOrbit-Settings-four-corners-fixture.png", size: NSSize(width: 960, height: 760))
        for corner in Corner.allCases where corner != .topLeft {
            store.selectedCorner = corner
            try await CornerNativeEvaluation.render(AnyView(CornerSettingsView(store: store)),
                named: "CornerOrbit-Settings-corner-\(corner.rawValue)-fixture.png", size: NSSize(width: 960, height: 760))
        }
        store.page = .behavior
        try await CornerNativeEvaluation.render(AnyView(CornerSettingsView(store: store)),
            named: "CornerOrbit-Settings-behavior-fixture.png", size: NSSize(width: 960, height: 760))
        store.page = .history
        try await CornerNativeEvaluation.render(AnyView(CornerSettingsView(store: store)),
            named: "CornerOrbit-Settings-history-fixture.png", size: NSSize(width: 960, height: 760))
        store.page = .about
        try await CornerNativeEvaluation.render(AnyView(CornerSettingsView(store: store)),
            named: "CornerOrbit-Settings-onboarding-fixture.png", size: NSSize(width: 960, height: 760))
        try store.assign(.init(kind: .openURL, url: "https://example.com/custom-website"), to: .topRight, gesture: .doubleClick)
        try await CornerNativeEvaluation.render(AnyView(CornerBindingEditorView(store: store, corner: .topRight, gesture: .doubleClick)),
            named: "CornerOrbit-BindingEditor-custom-website-fixture.png", size: NSSize(width: 600, height: 480))
        XCTAssertFalse(store.preferences.settings.enabled, "Opening settings/editors must never enable observation")
        XCTAssertFalse(store.preferences.automationEnabled)
    }

    @MainActor
    func testActualChromeAndRecentDropdownPopoversRenderLocalFixturesWithoutOpeningWebsites() async throws {
        let now = Date()
        let chrome = CornerHistoryEntry(url: try XCTUnwrap(URL(string: "https://example.com/reference?chapter=2")),
            title: "Synthetic Chrome reference", lastVisited: now.addingTimeInterval(-60), source: .chrome)
        let recent = CornerHistoryEntry(url: try XCTUnwrap(URL(string: "https://example.org/recent")),
            title: "Synthetic recent website", lastVisited: now.addingTimeInterval(-120), source: .recent)
        var opened: [CornerHistoryEntry] = [], settingsRequests = 0
        let chromeView = WebsiteDropdownView(entries: [chrome], title: "Chrome History · Synthetic Fixture",
            onOpen: { opened.append($0) }, onSettings: { settingsRequests += 1 })
        try await CornerNativeEvaluation.renderPopover(AnyView(chromeView),
            named: "CornerOrbit-ChromeHistory-dropdown-fixture.png", size: NSSize(width: 440, height: 420))
        let recentView = WebsiteDropdownView(entries: [recent], title: "Recent Websites · Synthetic Fixture",
            onOpen: { opened.append($0) }, onSettings: { settingsRequests += 1 })
        try await CornerNativeEvaluation.renderPopover(AnyView(recentView),
            named: "CornerOrbit-RecentWebsites-dropdown-fixture.png", size: NSSize(width: 440, height: 420))
        XCTAssertTrue(opened.isEmpty, "Merely presenting/search-selecting local history must not launch a website")
        XCTAssertEqual(settingsRequests, 0)
        XCTAssertEqual(chrome.url.absoluteString, "https://example.com/reference?chapter=2")
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The actual injected CornerOrbit operation did not finish")
    }

    @MainActor
    private func makeStore(defaults: UserDefaults, persistence: CornerPreferencesPersistence? = nil) -> EvaluationFixture {
        let permission = EvaluationPermission(), workspace = EvaluationWorkspace()
        let scripts = EvaluationScripts(), reader = EvaluationHistoryReader()
        let dependencies = CornerMonitorDependencies(preflightAccess: { permission.preflights += 1; return permission.authorized },
            requestAccess: { permission.requests += 1; return false },
            screens: { [.init(id: "synthetic-display", frame: .init(x: 0, y: 0, width: 1200, height: 800))] },
            installMouseEvents: { receiver in permission.installs += 1; permission.receiver = receiver; return permission.source },
            now: { permission.now })
        let history = ChromeHistoryStore(reader: reader, defaults: defaults)
        let recent = RecentlyOpenedStore(defaults: defaults)
        let runner = CornerActionRunner(workspace: workspace, scripts: scripts)
        let store = CornerAppStore(persistence: persistence, monitorDependencies: dependencies,
            actionRunner: runner, history: history, recent: recent)
        return EvaluationFixture(store: store, permission: permission, workspace: workspace, scripts: scripts, reader: reader)
    }
}

@MainActor
private struct EvaluationFixture {
    let store: CornerAppStore
    let permission: EvaluationPermission
    let workspace: EvaluationWorkspace
    let scripts: EvaluationScripts
    let reader: EvaluationHistoryReader
}
@MainActor
private final class EvaluationPermission {
    var preflights = 0, requests = 0, installs = 0
    var authorized = false
    var now = 0.0
    var receiver: CornerMonitorDependencies.Receiver?
    let source = EvaluationMouseSource()
}
@MainActor
private final class EvaluationMouseSource: CornerMouseEventSource {
    var stops = 0
    func stop() { stops += 1 }
}
@MainActor
private final class EvaluationWorkspace: CornerWorkspaceAccessing {
    var resolvedBundleIDs: [String] = []
    var openedWebsites: [URL] = [], openedApplications: [URL] = []
    var refuseOpens = false
    func applicationURL(bundleID: String) -> URL? {
        resolvedBundleIDs.append(bundleID)
        return URL(fileURLWithPath: "/synthetic-app-fixture/\(bundleID).app")
    }
    func openApplication(at url: URL) async throws { openedApplications.append(url) }
    func openWebsite(_ url: URL, in application: URL) async throws {
        if refuseOpens { throw CornerActionExecutionError.launchFailed("Synthetic workspace refused this request") }
        openedWebsites.append(url)
    }
    func openDirectory(_ url: URL) async throws { XCTFail("These evaluation cases never request a directory open") }
}
private actor EvaluationScripts: CornerScriptExecuting {
    private(set) var calls = 0
    func execute(_ request: CornerAppleScriptRequest) async throws { calls += 1 }
}
private actor EvaluationHistoryReader: ChromeHistoryReading {
    private(set) var calls = 0
    func read(from url: URL, limit: Int) async throws -> [CornerHistoryEntry] { calls += 1; return [] }
}

@MainActor
enum CornerNativeEvaluation {
    static func render(_ content: AnyView, named name: String, size: NSSize) async throws {
        XCTAssertTrue(name.hasPrefix("CornerOrbit-") && name.hasSuffix(".png"))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        let background = CornerEvaluationBackgroundView(frame: NSRect(origin: .zero, size: size))
        let host = NSHostingView(rootView: content)
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        window.contentView = background
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        background.layoutSubtreeIfNeeded(); host.layoutSubtreeIfNeeded()
        background.displayIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(background.bitmapImageRepForCachingDisplay(in: background.bounds))
        background.cacheDisplay(in: background.bounds, to: bitmap)
        try save(bitmap, named: name)
    }

    static func renderPopover(_ content: AnyView, named name: String, size: NSSize) async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSButton(title: "Owned synthetic history anchor", target: nil, action: nil)
        anchor.frame = NSRect(x: 24, y: 24, width: 300, height: 32)
        window.contentView?.addSubview(anchor)
        window.center(); window.makeKeyAndOrderFront(nil)
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        let controller = NSHostingController(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        popover.contentViewController = controller
        popover.contentSize = size
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        defer { popover.close(); window.close() }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(popover.isShown, "The fixture must render an actual AppKit popover")
        controller.view.layoutSubtreeIfNeeded(); controller.view.displayIfNeeded()
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        try save(bitmap, named: name)
    }

    private static func save(_ bitmap: NSBitmapImageRep, named name: String) throws {
        XCTAssertGreaterThan(bitmap.pixelsWide, 0); XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000, "Actual rendered controls must produce a nonempty native image")
        let configured = ProcessInfo.processInfo.environment["CORNERORBIT_EVAL_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_CORNERORBIT_EVAL_DIR"]
        let root: URL
        if let configured {
            XCTAssertTrue(configured.hasPrefix("/"))
            root = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("build/evaluation", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent(name))
    }
}

@MainActor
private final class CornerEvaluationBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
