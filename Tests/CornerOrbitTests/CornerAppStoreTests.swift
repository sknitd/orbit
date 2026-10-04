import AppKit
import Darwin
import Foundation
import XCTest
import CornerCore
@testable import CornerOrbit

final class CornerAppStoreTests: XCTestCase, @unchecked Sendable {
    func testSettingsArePrivateBeforeAtomicPublicationAndRoundTrip() throws {
        let directory = makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let initial = CornerPreferencesPersistence(directory: directory)
        try initial.save(.defaults)
        let old = try Data(contentsOf: initial.file)
        let probe = CornerPublicationProbe(fail: false)
        let persistence = CornerPreferencesPersistence(directory: directory, publish: { [probe] stage, final in try probe.publish(stage, final) })
        var next = CornerPreferences.defaults; next.settings.cornerSize = 36; next.showHints = true
        try persistence.save(next)
        XCTAssertEqual(probe.permissions, 0o600)
        XCTAssertEqual(probe.priorBytes, old, "The old file remains intact until the atomic commit")
        XCTAssertEqual(try persistence.load(), next)
        let attributes = try FileManager.default.attributesOfItem(atPath: persistence.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings.json"])
    }

    func testPublicationFailurePreservesExactOldSettingsAndCleansPrivateStaging() throws {
        let directory = makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let initial = CornerPreferencesPersistence(directory: directory); try initial.save(.defaults)
        let original = try Data(contentsOf: initial.file)
        let probe = CornerPublicationProbe(fail: true)
        let persistence = CornerPreferencesPersistence(directory: directory, publish: { [probe] stage, final in try probe.publish(stage, final) })
        var next = CornerPreferences.defaults; next.automationEnabled = true
        XCTAssertThrowsError(try persistence.save(next))
        XCTAssertEqual(probe.permissions, 0o600)
        XCTAssertEqual(try Data(contentsOf: persistence.file), original)
        XCTAssertEqual(try persistence.load(), .defaults)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["settings.json"])
    }

    func testStructuralAndSemanticCorruptionRequireExplicitPreserveBeforeReset() throws {
        let directory = makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = CornerPreferencesPersistence(directory: directory)
        let valid = try JSONEncoder().encode(CornerPreferences.defaults)
        var semantic = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var settings = try XCTUnwrap(semantic["settings"] as? [String: Any]); settings["schemaVersion"] = 99; semantic["settings"] = settings
        let rejected = [Data("{broken original settings".utf8), try JSONSerialization.data(withJSONObject: semantic)]
        for original in rejected {
            try original.write(to: persistence.file)
            XCTAssertThrowsError(try persistence.load())
            XCTAssertThrowsError(try persistence.save(.defaults))
            XCTAssertEqual(try Data(contentsOf: persistence.file), original)
            let backup = try XCTUnwrap(persistence.preserveForReset())
            XCTAssertEqual(try Data(contentsOf: backup), original)
            try persistence.save(.defaults)
            XCTAssertEqual(try persistence.load(), .defaults)
        }
    }

    func testExistingAndDanglingSymlinksAreNeverOverwrittenOrFollowed() throws {
        let directory = makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = CornerPreferencesPersistence(directory: directory)
        let target = directory.appendingPathComponent("retained-target")
        let bytes = Data("Unrelated target retained".utf8); try bytes.write(to: target)
        for destination in [target, directory.appendingPathComponent("missing-target")] {
            try FileManager.default.createSymbolicLink(at: persistence.file, withDestinationURL: destination)
            XCTAssertThrowsError(try persistence.load()); XCTAssertThrowsError(try persistence.save(.defaults))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: persistence.file.path), destination.path)
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            try FileManager.default.removeItem(at: persistence.file)
        }
    }

    @MainActor
    func testEveryLifecycleStopCancelsSameTurnQueuedManualActionBeforeWorkspaceAccess() async throws {
        for stop in CornerLifecycleStop.allCases {
            let workspace = CornerLifecycleWorkspace()
            let store = makeStore(workspace: workspace)
            defer { store.shutdown() }
            var notices: [String] = []; var websitePanels = 0
            store.onNotice = { notices.append($0) }; store.onShowWebsites = { _, _ in websitePanels += 1 }
            store.perform(.init(kind: .openURL, url: "https://example.com/queued"))
            XCTAssertTrue(store.isRunningAction)
            switch stop {
            case .monitoring: store.setMonitoring(false)
            case .automation: store.setAutomation(false)
            case .preset: store.applyPreset()
            case .reset: store.resetPreservingSettings()
            case .shutdown: store.shutdown()
            case .reconfigure: try store.assign(.init(kind: .finder), to: .topLeft, gesture: .singleClick)
            }
            let statusAfterStop = store.lastAction
            try await waitUntil { !store.isRunningAction }
            XCTAssertTrue(workspace.lookups.isEmpty, stop.rawValue)
            XCTAssertTrue(workspace.websites.isEmpty, stop.rawValue)
            XCTAssertTrue(notices.isEmpty, stop.rawValue); XCTAssertEqual(websitePanels, 0)
            XCTAssertTrue(store.recent.entries.isEmpty)
            XCTAssertEqual(store.lastAction, statusAfterStop, "Old cancellation cannot overwrite reset/preset status")
        }
    }

    @MainActor
    func testCancelledNoncooperativeCompletionStaysSerializedAndCannotRecordOrPublishSuccess() async throws {
        let workspace = CornerLifecycleWorkspace(); workspace.blocks = true
        let store = makeStore(workspace: workspace); defer { store.shutdown(); workspace.finish() }
        var panels = 0; store.onShowWebsites = { _, _ in panels += 1 }
        store.perform(.init(kind: .openURL, url: "https://example.com/already-requested"))
        try await waitUntil { workspace.hasPending }
        store.setMonitoring(false)
        XCTAssertTrue(store.isRunningAction, "The cancelled slot remains occupied until native work settles")
        store.perform(.init(kind: .finder))
        XCTAssertEqual(workspace.lookups, ["com.google.Chrome"])
        XCTAssertTrue(workspace.applications.isEmpty)
        workspace.finish()
        try await waitUntil { !store.isRunningAction }
        XCTAssertTrue(store.recent.entries.isEmpty); XCTAssertEqual(panels, 0)
        XCTAssertEqual(store.lastAction, "Action canceled.")
        store.perform(.init(kind: .recentWebsites))
        try await waitUntil { !store.isRunningAction }
        XCTAssertEqual(panels, 1, "A fresh explicit action can run after cancellation settles")
    }

    @MainActor
    func testCancelledLateFailureCannotShowErrorOrSettingsAndShutdownRejectsNewActions() async throws {
        let workspace = CornerLifecycleWorkspace(); workspace.blocks = true; workspace.failAfterRelease = true
        let store = makeStore(workspace: workspace); defer { store.shutdown(); workspace.finish() }
        var notices = 0; var settingsRequests = 0
        store.onNotice = { _ in notices += 1 }; store.onOpenSettings = { _ in settingsRequests += 1 }
        store.perform(.init(kind: .openURL, url: "https://example.com/late-failure"))
        try await waitUntil { workspace.hasPending }
        store.setAutomation(false); workspace.finish()
        try await waitUntil { !store.isRunningAction }
        XCTAssertNil(store.errorMessage); XCTAssertEqual(notices, 0); XCTAssertEqual(settingsRequests, 0)
        store.shutdown(); store.perform(.init(kind: .finder))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(workspace.lookups, ["com.google.Chrome"])
        XCTAssertFalse(store.isRunningAction)
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CornerAppStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
    @MainActor
    private func makeStore(workspace: CornerLifecycleWorkspace) -> CornerAppStore {
        let dependencies = CornerMonitorDependencies(preflightAccess: { false }, requestAccess: { XCTFail("Lifecycle fixtures must never request permission"); return false },
            screens: { [] }, installMouseEvents: { _ in XCTFail("Lifecycle fixtures must never install observation"); return nil })
        return CornerAppStore(preferences: .init(automationEnabled: true), monitorDependencies: dependencies,
            actionRunner: CornerActionRunner(workspace: workspace, scripts: CornerLifecycleScripts()),
            history: ChromeHistoryStore(previewEntries: []), recent: RecentlyOpenedStore(previewEntries: []))
    }
    @MainActor
    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The injected lifecycle operation did not settle")
    }
}

private enum CornerLifecycleStop: String, CaseIterable { case monitoring, automation, preset, reset, shutdown, reconfigure }
private enum CornerPublicationFailure: Error { case beforeCommit }
private final class CornerPublicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let fail: Bool
    private var mode: Int?
    private var old: Data?
    init(fail: Bool) { self.fail = fail }
    var permissions: Int? { lock.lock(); defer { lock.unlock() }; return mode }
    var priorBytes: Data? { lock.lock(); defer { lock.unlock() }; return old }
    func publish(_ staging: URL, _ final: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: staging.path)
        let original = try Data(contentsOf: final)
        lock.lock(); mode = (attributes[.posixPermissions] as? NSNumber)?.intValue; old = original; lock.unlock()
        if fail { throw CornerPublicationFailure.beforeCommit }
        guard rename(staging.path, final.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
@MainActor
private final class CornerLifecycleWorkspace: CornerWorkspaceAccessing {
    var lookups: [String] = []
    var websites: [URL] = []
    var applications: [URL] = []
    var blocks = false
    var failAfterRelease = false
    private var pending: CheckedContinuation<Void, Never>?
    var hasPending: Bool { pending != nil }
    func applicationURL(bundleID: String) -> URL? { lookups.append(bundleID); return URL(fileURLWithPath: "/Applications/LifecycleFixture.app") }
    func openApplication(at url: URL) async throws { applications.append(url) }
    func openWebsite(_ url: URL, in application: URL) async throws {
        websites.append(url)
        if blocks { await withCheckedContinuation { pending = $0 } }
        if failAfterRelease { throw CornerActionExecutionError.launchFailed("Late fixture failure") }
    }
    func openDirectory(_ url: URL) async throws {}
    func finish() { let continuation = pending; pending = nil; continuation?.resume() }
}
private actor CornerLifecycleScripts: CornerScriptExecuting {
    func execute(_ request: CornerAppleScriptRequest) async throws { XCTFail("Lifecycle URL fixtures must never execute scripts") }
}
