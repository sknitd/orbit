import AppKit
import Foundation
import NotchCore
import XCTest
@testable import NotchOrbitPlus

final class LauncherSyncTests: XCTestCase {
    @MainActor
    private func withStore(_ body: (PlusLauncherStore, UserDefaults) throws -> Void) throws {
        let suite = "NotchOrbitPlus.LauncherSync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(PlusLauncherStore(defaults: defaults, onPortableChange: {}), defaults)
    }
    @MainActor
    func testPortableFolderNeedsExplicitLocalResolutionWithoutInventedPathOrBookmark() throws {
        try withStore { store, defaults in
            let id = UUID(), logical = SyncLauncherPin(id: id, label: "Projects", kind: .folder, targetIdentifier: id.uuidString)
            try store.applySyncedPins([logical])
            XCTAssertTrue(store.pins.isEmpty); XCTAssertEqual(store.missingTargets, [logical])
            XCTAssertEqual(try store.exportSyncedPins(), [logical])
            XCTAssertTrue(try PlusLauncherPins.decode(XCTUnwrap(defaults.data(forKey: PlusLauncherStore.defaultsKey))).isEmpty)
            let bytes = try XCTUnwrap(defaults.data(forKey: PlusLauncherStore.portableKey))
            let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
            XCTAssertEqual(Set(try XCTUnwrap(objects.first).keys), ["id", "label", "kind", "targetIdentifier"])
        }
    }
    @MainActor
    func testInstalledApplicationSyncResolvesLocallyWithoutLaunchingOrExportingBookmark() throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil else { throw XCTSkip("Terminal is not installed on this runner.") }
        let before = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.Terminal" }.map(\.processIdentifier))
        try withStore { store, _ in
            let logical = SyncLauncherPin(id: UUID(), label: "Terminal", kind: .application, targetIdentifier: "com.apple.Terminal")
            try store.applySyncedPins([logical])
            let local = try XCTUnwrap(store.pins.first)
            XCTAssertTrue(local.targetIdentifier.hasPrefix("/")); XCTAssertFalse(try XCTUnwrap(local.bookmark).isEmpty)
            XCTAssertEqual(try store.exportSyncedPins(), [logical]); XCTAssertTrue(store.missingTargets.isEmpty)
            let text = String(decoding: try JSONEncoder().encode(store.exportSyncedPins()), as: UTF8.self)
            XCTAssertFalse(text.contains("bookmark")); XCTAssertFalse(text.contains(local.targetIdentifier))
        }
        XCTAssertEqual(Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.Terminal" }.map(\.processIdentifier)), before)
    }
    @MainActor
    func testUnreadableLauncherOriginalBlocksSyncAndExplicitResetKeepsExactBackup() throws {
        let suite = "NotchOrbitPlus.LauncherCorrupt.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("{broken-launcher".utf8); defaults.set(original, forKey: PlusLauncherStore.defaultsKey)
        let store = PlusLauncherStore(defaults: defaults, onPortableChange: {})
        XCTAssertThrowsError(try store.applySyncedPins([])); XCTAssertEqual(defaults.data(forKey: PlusLauncherStore.defaultsKey), original)
        store.resetUnreadablePins()
        XCTAssertFalse(store.needsReset)
        let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(PlusLauncherStore.defaultsKey + ".backup.") }
        XCTAssertTrue(backups.values.contains { ($0 as? Data) == original })
    }
    @MainActor
    func testOpenEditorsBlockChangedSyncedLibrariesAndPreserveSavedOriginals() throws {
        try withStore { store, defaults in
            let id = UUID(), first = SyncLauncherPin(id: id, label: "Projects", kind: .folder, targetIdentifier: id.uuidString)
            try store.applySyncedPins([first]); store.setEditorOpen(true)
            let bytes = defaults.data(forKey: PlusLauncherStore.portableKey)
            var incoming = first; incoming.label = "Remote name"
            XCTAssertThrowsError(try store.applySyncedPins([incoming])); XCTAssertEqual(defaults.data(forKey: PlusLauncherStore.portableKey), bytes)
            let workflow = WorkflowStore(defaults: defaults, onPortableChange: {})
            let original = try workflow.exportSyncedPresets(); workflow.setEditorOpen(true)
            var changed = original; changed[0].name = "Remote workflow"
            XCTAssertThrowsError(try workflow.applySyncedPresets(changed)); XCTAssertEqual(workflow.presets, original)
        }
    }
    @MainActor
    func testWrongPropertyTypesBlockEveryPortableStoreAndExplicitResetPreservesOriginal() throws {
        let suite = "NotchOrbitPlus.PortableWrongType.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = "wrong property type, keep original"
        let keys = [PlusAppearanceStore.defaultsKey, PlusLivePriorityStore.defaultsKey, PlusLauncherStore.defaultsKey, "workflows.presets"]
        for key in keys { defaults.set(original, forKey: key) }
        let appearance = PlusAppearanceStore(defaults: defaults, onChange: {}), priority = PlusLivePriorityStore(defaults: defaults, onChange: {})
        let launcher = PlusLauncherStore(defaults: defaults, onPortableChange: {}), workflows = WorkflowStore(defaults: defaults, onPortableChange: {})
        XCTAssertThrowsError(try appearance.applySynced(.init(theme: .dark)))
        XCTAssertThrowsError(try priority.applySynced(.init()))
        XCTAssertThrowsError(try launcher.applySyncedPins([])); XCTAssertThrowsError(try workflows.applySyncedPresets([]))
        for key in keys { XCTAssertEqual(defaults.string(forKey: key), original) }
        appearance.resetKeepingBackup(); priority.resetKeepingBackup(); launcher.resetUnreadablePins()
        XCTAssertTrue(workflows.save(WorkflowPreset(name: "Intentional replacement", steps: [.zip])))
        for key in keys.dropLast() {
            let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(key + ".backup.") }
            XCTAssertTrue(backups.values.contains { ($0 as? String) == original })
        }
        XCTAssertEqual(defaults.string(forKey: "workflows.preserved-invalid"), original)
    }
}
