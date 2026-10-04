import AppKit
import Darwin
import Foundation
import XCTest
import CornerCore
@testable import CornerOrbit

final class CornerProfilesNativeTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testFreshStoreDoesNotCreateFilesObserveApplyOrRegisterAndCRUDPersistsPrivateSnapshots() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = CornerProfilePersistence(directory: directory), context = ProfileContextFixture()
        let store = CornerProfilesStore(persistence: persistence, contextSource: context)
        defer { store.shutdown() }
        var applied = 0; store.onProfileSelected = { _ in applied += 1 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path)); XCTAssertEqual(context.starts, 0); XCTAssertEqual(context.reads, 0)
        XCTAssertTrue(store.profiles.isEmpty); XCTAssertFalse(store.autoSwitchEnabled)
        var armed = CornerSettings.samplePreset; armed.enabled = true
        let first = try store.create(name: " Work ", settings: armed)
        let copy = try store.duplicate(id: first)
        XCTAssertNotEqual(copy, first); XCTAssertEqual(store.profiles.count, 2)
        XCTAssertTrue(store.profiles.allSatisfy { !$0.settings.enabled }); XCTAssertEqual(applied, 0)
        try store.rename(id: copy, name: "Personal")
        var changed = CornerSettings.defaults; changed.cornerSize = 40
        try store.saveSnapshot(id: copy, settings: changed)
        XCTAssertEqual(store.profiles.first { $0.id == copy }?.settings.cornerSize, 40)
        try store.addRule(bundleID: "com.example.Work", profileID: copy)
        XCTAssertFalse(try XCTUnwrap(store.rules.first).enabled)
        try store.activate(id: copy); XCTAssertEqual(store.activeProfileID, copy); XCTAssertEqual(applied, 1)
        try store.delete(id: copy)
        XCTAssertNil(store.activeProfileID); XCTAssertTrue(store.rules.isEmpty); XCTAssertEqual(applied, 1)
        XCTAssertEqual(try persistence.load().profiles.map(\.id), [first])
        let attributes = try FileManager.default.attributesOfItem(atPath: persistence.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(context.starts, 0); XCTAssertEqual(context.reads, 0)
    }

    @MainActor
    func testImportRequiresExplicitReviewedApplyAndPreservesLocalOptInsWithoutActivation() throws {
        let context = ProfileContextFixture()
        let first = CornerProfile(name: "Local", settings: .defaults)
        let archive = CornerProfilesArchive(profiles: [first], activeProfileID: first.id, autoSwitchEnabled: true,
            rules: [.init(bundleID: "com.example.Local", profileID: first.id, enabled: true)], excludedAppIDs: ["com.example.Excluded"])
        let store = CornerProfilesStore(persistence: nil, contextSource: context, initialArchive: archive)
        var applied = 0; store.onProfileSelected = { _ in applied += 1 }
        let imported = CornerProfile(name: "Imported", settings: .samplePreset)
        let bytes = try CornerProfileDocument(profiles: [imported]).encoded()
        try store.previewImport(data: bytes)
        XCTAssertEqual(store.profiles.count, 1); XCTAssertEqual(store.importPreview?.count, 1); XCTAssertEqual(applied, 0)
        XCTAssertEqual(context.starts, 0); XCTAssertEqual(context.reads, 0)
        try store.applyImport()
        XCTAssertEqual(store.profiles.count, 2); XCTAssertNil(store.importPreview); XCTAssertEqual(applied, 0)
        XCTAssertEqual(store.activeProfileID, first.id); XCTAssertTrue(store.autoSwitchEnabled)
        XCTAssertEqual(store.rules, archive.rules); XCTAssertEqual(store.excludedAppIDs, archive.excludedAppIDs)
        let exported = try CornerProfileDocument.decode(store.exportData())
        XCTAssertTrue(exported.profiles.allSatisfy { !$0.settings.enabled })
        try store.previewImport(data: bytes); try store.rename(id: first.id, name: "Local Changed")
        XCTAssertThrowsError(try store.applyImport(), "Any edit invalidates the reviewed revision")
        XCTAssertEqual(store.profiles.count, 2)
    }

    @MainActor
    func testContextObservationRequiresOptInRetainsUnmatchedProfileAndClearsActualExclusion() throws {
        let first = CornerProfile(name: "Work", settings: .samplePreset)
        let context = ProfileContextFixture(); context.identifier = "com.example.Work"
        let store = CornerProfilesStore(persistence: nil, contextSource: context,
            initialArchive: .init(profiles: [first], rules: [.init(bundleID: "com.example.Work", profileID: first.id, enabled: true)]))
        var applied: [CornerSettings] = []; var exclusions: [Bool] = []
        store.onProfileSelected = { applied.append($0) }; store.onExclusionChanged = { exclusions.append($0) }
        store.resumeContext(); XCTAssertEqual(context.starts, 0); XCTAssertEqual(context.reads, 0)
        try store.setAutoSwitchEnabled(true)
        XCTAssertEqual(context.starts, 1); XCTAssertEqual(applied.count, 1); XCTAssertFalse(try XCTUnwrap(applied.first).enabled)
        context.emit("com.example.Unmatched"); XCTAssertEqual(applied.count, 1); XCTAssertEqual(store.activeProfileID, first.id)
        try store.setExcludedAppIDs(["com.example.Excluded"])
        context.emit("com.example.Excluded"); XCTAssertEqual(exclusions, [true])
        context.emit("com.sknitd.CornerOrbit"); XCTAssertEqual(exclusions, [true, false]); XCTAssertEqual(applied.count, 1)
        try store.setAutoSwitchEnabled(false); XCTAssertTrue(store.isObservingContext)
        try store.setExcludedAppIDs([]); XCTAssertFalse(store.isObservingContext)
        let count = applied.count; context.emitCaptured("com.example.Work")
        XCTAssertEqual(applied.count, count, "Callbacks from a stopped generation cannot apply a profile")
        store.shutdown()
    }

    @MainActor
    func testRejectedProfileApplicationRetainsPriorSelectionAndAutomaticSelectionCanRetry() throws {
        let first = CornerProfile(name: "First", settings: .defaults)
        var larger = CornerSettings.defaults; larger.cornerSize = 48
        let second = CornerProfile(name: "Second", settings: larger)
        let context = ProfileContextFixture(); context.identifier = "com.example.Second"
        let store = CornerProfilesStore(persistence: nil, contextSource: context,
            initialArchive: .init(profiles: [first, second], rules: [.init(bundleID: "com.example.Second", profileID: second.id, enabled: true)]))
        var rejectSecond = true; var accepted: [Double] = []
        store.onProfileSelected = { settings in
            if settings.cornerSize == 48 && rejectSecond { throw ProfileFixtureFailure.refused }
            accepted.append(settings.cornerSize)
        }
        try store.activate(id: first.id); XCTAssertEqual(store.activeProfileID, first.id)
        XCTAssertThrowsError(try store.activate(id: second.id)); XCTAssertEqual(store.activeProfileID, first.id)
        try store.setAutoSwitchEnabled(true); store.resumeContext()
        XCTAssertEqual(store.activeProfileID, first.id); XCTAssertNotNil(store.errorMessage)
        rejectSecond = false; context.emit("com.example.Second")
        XCTAssertEqual(store.activeProfileID, second.id); XCTAssertNil(store.errorMessage); XCTAssertEqual(accepted, [24, 48])
        try store.activate(id: first.id); try store.activate(id: second.id)
        XCTAssertEqual(store.activeProfileID, second.id, "An old runtime selection cannot override explicit A→B activation")
        store.shutdown()
    }

    @MainActor
    func testPrivatePublicationFailureAndCorruptArchiveArePreservedUntilExplicitRecovery() throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = CornerProfilePersistence(directory: directory); try persistence.save(.defaults)
        let original = try Data(contentsOf: persistence.file), probe = ProfilePublicationProbe()
        let failing = CornerProfilePersistence(directory: directory, publish: { [probe] stage, _ in try probe.inspectAndRefuse(stage) })
        XCTAssertThrowsError(try failing.save(.init(profiles: [.init(name: "Unsaved", settings: .defaults)])))
        XCTAssertEqual(probe.permissions, 0o600); XCTAssertEqual(try Data(contentsOf: persistence.file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["profiles.json"])
        let corrupt = Data("{retained invalid original profiles".utf8); try corrupt.write(to: persistence.file)
        let store = CornerProfilesStore(persistence: persistence, contextSource: ProfileContextFixture())
        XCTAssertTrue(store.needsRecovery); XCTAssertThrowsError(try store.create(name: "New", settings: .defaults))
        XCTAssertEqual(try Data(contentsOf: persistence.file), corrupt)
        try store.preserveAndReset(); XCTAssertFalse(store.needsRecovery); XCTAssertTrue(store.profiles.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("profiles-preserved-") }
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), corrupt)
        XCTAssertEqual(try persistence.load(), .defaults)
    }

    @MainActor
    func testTimedPauseCancellationAndReplacementNeverRunStaleResume() async throws {
        let sleeper = ProfilePauseSleeper(), base = Date(timeIntervalSince1970: 1_000)
        let controller = CornerTimedPauseController(now: { base }, sleep: { seconds in await sleeper.wait(seconds) })
        var pauses = 0; var resumes = 0; controller.onPause = { pauses += 1 }; controller.onResume = { resumes += 1 }
        controller.pause(minutes: 5); XCTAssertEqual(controller.until, base.addingTimeInterval(300))
        try await waitUntil { await sleeper.count() == 1 }
        controller.pause(minutes: 15); XCTAssertEqual(controller.until, base.addingTimeInterval(900))
        try await waitUntil { await sleeper.count() == 2 }
        await sleeper.releaseFirst(); try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(controller.isPaused); XCTAssertEqual(resumes, 0)
        await sleeper.releaseFirst(); try await waitUntil { !controller.isPaused }
        XCTAssertEqual(resumes, 1)
        controller.pause(minutes: 60); try await waitUntil { await sleeper.count() == 1 }
        controller.cancel(); await sleeper.releaseFirst(); try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(controller.isPaused); XCTAssertEqual(resumes, 1); XCTAssertEqual(pauses, 3)
        controller.pause(minutes: 1); XCTAssertNotNil(controller.errorMessage); XCTAssertEqual(pauses, 3)
        controller.shutdown()
    }

    @MainActor
    func testLoginRegistrationIsExplicitAndApprovalErrorsAreActualBackendState() async {
        let backend = ProfileLoginFixture(), service = CornerLaunchAtLoginService(backend: backend)
        XCTAssertFalse(service.enabled); XCTAssertEqual(backend.registrations, 0); XCTAssertEqual(backend.unregistrations, 0)
        await service.setEnabled(true)
        XCTAssertEqual(backend.registrations, 1); XCTAssertFalse(service.enabled); XCTAssertTrue(service.requiresApproval)
        await service.setEnabled(true); XCTAssertEqual(backend.registrations, 1)
        service.openApprovalSettings(); XCTAssertEqual(backend.settingsOpens, 1)
        await service.setEnabled(false); XCTAssertEqual(backend.unregistrations, 1); XCTAssertFalse(service.requiresApproval)
        backend.refuse = true; await service.setEnabled(true)
        XCTAssertFalse(service.enabled); XCTAssertNotNil(service.errorMessage)
        let calls = backend.registrations
        let preview = CornerLaunchAtLoginService(preview: true, backend: backend)
        await preview.setEnabled(true); preview.openApprovalSettings()
        XCTAssertEqual(backend.registrations, calls); XCTAssertEqual(backend.settingsOpens, 1)
    }
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("CornerProfilesTests-\(UUID())", isDirectory: true) }
    @MainActor
    private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<100 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("The injected profile/control operation did not settle")
    }
}
private enum ProfileFixtureFailure: Error { case refused }
@MainActor
private final class ProfileContextFixture: CornerProfileContextSource {
    var identifier: String?
    var starts = 0, stops = 0, reads = 0
    private var receiver: (@MainActor (String?) -> Void)?
    private var captured: (@MainActor (String?) -> Void)?
    var currentBundleID: String? { reads += 1; return identifier }
    func start(_ onChange: @escaping @MainActor (String?) -> Void) { starts += 1; receiver = onChange; captured = onChange }
    func stop() { stops += 1; receiver = nil }
    func emit(_ identifier: String) { self.identifier = identifier; receiver?(identifier) }
    func emitCaptured(_ identifier: String) { captured?(identifier) }
}
private final class ProfilePublicationProbe: @unchecked Sendable {
    private let lock = NSLock(); private var mode: Int?
    var permissions: Int? { lock.lock(); defer { lock.unlock() }; return mode }
    func inspectAndRefuse(_ stage: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: stage.path)
        lock.lock(); mode = (attributes[.posixPermissions] as? NSNumber)?.intValue; lock.unlock()
        throw ProfileFixtureFailure.refused
    }
}
private actor ProfilePauseSleeper {
    private var pending: [CheckedContinuation<Void, Never>] = []
    func wait(_ seconds: Double) async { await withCheckedContinuation { pending.append($0) } }
    func count() -> Int { pending.count }
    func releaseFirst() { guard !pending.isEmpty else { return }; pending.removeFirst().resume() }
}
@MainActor
private final class ProfileLoginFixture: CornerLoginBackend {
    var status: CornerLoginStatus = .notRegistered
    var registrations = 0, unregistrations = 0, settingsOpens = 0
    var refuse = false
    func register() throws { registrations += 1; if refuse { throw ProfileFixtureFailure.refused }; status = .requiresApproval }
    func unregister() throws { unregistrations += 1; status = .notRegistered }
    func openApprovalSettings() { settingsOpens += 1 }
}
