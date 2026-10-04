import Foundation
import NotchCore
import XCTest
@testable import NotchOrbitPlus

final class SyncLocalTransactionTests: XCTestCase {
    @MainActor private var keys: [String] { [PlusLauncherStore.defaultsKey, PlusLauncherStore.portableKey,
                        "workflows.presets", "workflows.selected", PlusAppearanceStore.defaultsKey,
                        PlusLivePriorityStore.defaultsKey, WorldClockToolModel.zonesKey] }

    @MainActor
    private func fixture(_ body: (URL, UserDefaults) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("NotchSyncTransaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let suite = "NotchSyncTransaction.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try body(root, defaults)
    }

    @MainActor
    private func transaction(_ root: URL, _ defaults: UserDefaults) throws -> PlusSyncLocalTransaction {
        try PlusSyncLocalTransaction(in: root, files: [
            ("quick-note.txt", 200_000), ("todos.json", 4 * 1024 * 1024),
            ("sync-state-v1.json", SyncSnapshot.maximumBytes), ("color-picker-v1.json", CoreColorPaletteLibrary.maximumBytes)
        ], defaults: defaults, defaultsKeys: keys)
    }

    @MainActor
    func testLatePaletteWriteFailureRestoresExactExistingFilesAndEveryStore() throws {
        try fixture { root, defaults in
            let launcher = PlusLauncherStore(defaults: defaults, onPortableChange: {})
            let workflow = WorkflowStore(defaults: defaults, onPortableChange: {})
            let appearance = PlusAppearanceStore(defaults: defaults, onChange: {})
            let priority = PlusLivePriorityStore(defaults: defaults, onChange: {})
            let zones = WorldClockToolModel(defaults: defaults, settingsDidChange: {})
            let originalPin = SyncLauncherPin(id: UUID(), label: "Original shortcut", kind: .shortcut, targetIdentifier: UUID().uuidString)
            try launcher.applySyncedPins([originalPin])
            let originalPresets = try workflow.exportSyncedPresets()
            try workflow.applySyncedPresets(originalPresets)
            let color = try CoreColorRGBA(red: 0.2, green: 0.4, blue: 0.6)
            let originalColor = try CoreColorPickerState(history: [color], library: CoreColorPaletteLibrary(palettes: [CoreColorPalette(name: "Original")]))
            let paletteURL = root.appendingPathComponent("color-picker-v1.json")
            let paletteBytes = try JSONEncoder().encode(originalColor); try paletteBytes.write(to: paletteURL)
            var paletteWrites = 0
            let picker = ColorPickerStore(persistHistory: false, initialState: originalColor, save: { next in
                // Model the real late failure: bytes reached disk, then a later IO step failed.
                paletteWrites += 1
                try JSONEncoder().encode(next).write(to: paletteURL, options: .atomic)
                throw CocoaError(.fileWriteUnknown)
            })
            var original = SyncSnapshot(deviceID: UUID())
            try original.captureNote("Keep this original note")
            try original.captureTasks([ToDoItem(title: "Keep this original task")])
            let noteBytes = Data("Keep this original note".utf8)
            let taskBytes = try JSONEncoder().encode(original.visibleTasks()), ledgerBytes = try original.encoded()
            try noteBytes.write(to: root.appendingPathComponent("quick-note.txt"))
            try taskBytes.write(to: root.appendingPathComponent("todos.json"))
            try ledgerBytes.write(to: root.appendingPathComponent("sync-state-v1.json"))
            let defaultsBefore = defaults.dictionaryRepresentation()
            let workSelection = workflow.selectedPresetID, zoneIDs = zones.zoneIDs
            let tx = try transaction(root, defaults)
            tx.addRollback(launcher.prepareSyncRollback()); tx.addRollback(workflow.prepareSyncRollback())
            tx.addRollback(picker.prepareSyncRollback()); tx.addRollback(appearance.prepareSyncRollback())
            tx.addRollback(priority.prepareSyncRollback()); tx.addRollback(zones.prepareSyncRollback())
            var incoming = original
            try incoming.captureNote("Incoming note"); try incoming.captureTasks([])
            let changed = WorkflowPreset(name: "Incoming workflow", steps: [.resize(maxDimension: 640)])
            let imported = try CoreColorPaletteLibrary(palettes: [CoreColorPalette(name: "Incoming")]).encoded()
            XCTAssertThrowsError(try tx.apply(incoming) {
                try launcher.applySyncedPins([]); try workflow.applySyncedPresets([changed])
                try appearance.applySynced(.init(theme: .dark)); try priority.applySynced(.init(order: Array(LiveNotchKind.allCases.reversed())))
                try zones.applySyncedZoneIDs(["Europe/London"])
                try picker.applySyncedData(imported)
            }) { error in
                XCTAssertTrue(error is PlusSyncLocalApplyFailure)
                XCTAssertNil((error as? PlusSyncLocalApplyFailure)?.recoveryDirectory)
            }
            XCTAssertEqual(paletteWrites, 1, "The fixture must reach the actual palette persistence failure after earlier stores changed")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("quick-note.txt")), noteBytes)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("todos.json")), taskBytes)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sync-state-v1.json")), ledgerBytes)
            XCTAssertEqual(try Data(contentsOf: paletteURL), paletteBytes)
            XCTAssertEqual(try launcher.exportSyncedPins(), [originalPin]); XCTAssertEqual(workflow.presets, originalPresets)
            XCTAssertEqual(workflow.selectedPresetID, workSelection); XCTAssertEqual(picker.state, originalColor)
            XCTAssertEqual(appearance.settings, CoreAppearancePreferences()); XCTAssertEqual(priority.configuration, LiveNotchPriorityConfiguration())
            XCTAssertEqual(zones.zoneIDs, zoneIDs)
            for key in keys { XCTAssertEqual(defaults.object(forKey: key) as? NSObject, defaultsBefore[key] as? NSObject, key) }
            XCTAssertNil(try PlusSyncLocalTransaction.pendingRecovery(in: root))
        }
    }

    @MainActor
    func testLateFailureRestoresAbsentFilesAndAbsentDefaultsRatherThanCreatingEmptyValues() throws {
        try fixture { root, defaults in
            let launcher = PlusLauncherStore(defaults: defaults, onPortableChange: {})
            let workflow = WorkflowStore(defaults: defaults, onPortableChange: {})
            let originalPresets = workflow.presets
            for key in keys { defaults.removeObject(forKey: key) }
            let initial = try CoreColorPickerState(library: CoreColorPaletteLibrary())
            var paletteWrites = 0
            let picker = ColorPickerStore(persistHistory: false, initialState: initial, save: { value in
                paletteWrites += 1
                try JSONEncoder().encode(value).write(to: root.appendingPathComponent("color-picker-v1.json"), options: .atomic)
                throw CocoaError(.fileWriteUnknown)
            })
            XCTAssertEqual(paletteWrites, 0, "Construction must not persist palettes")
            let tx = try transaction(root, defaults)
            tx.addRollback(launcher.prepareSyncRollback()); tx.addRollback(workflow.prepareSyncRollback()); tx.addRollback(picker.prepareSyncRollback())
            var incoming = SyncSnapshot(deviceID: UUID()); try incoming.captureNote("Incoming"); try incoming.captureTasks([ToDoItem(title: "Incoming")])
            XCTAssertThrowsError(try tx.apply(incoming) {
                try launcher.applySyncedPins([SyncLauncherPin(id: UUID(), label: "Incoming", kind: .shortcut, targetIdentifier: UUID().uuidString)])
                try workflow.applySyncedPresets([])
                try picker.applySyncedData(CoreColorPaletteLibrary(palettes: [CoreColorPalette(name: "Incoming")]).encoded())
            })
            XCTAssertEqual(paletteWrites, 1)
            for name in ["quick-note.txt", "todos.json", "sync-state-v1.json", "color-picker-v1.json"] {
                XCTAssertFalse(try PlusSyncFolderIO.hasNode(root.appendingPathComponent(name)), name)
            }
            for key in keys { XCTAssertNil(defaults.object(forKey: key), key) }
            XCTAssertTrue(launcher.pins.isEmpty); XCTAssertTrue(launcher.missingTargets.isEmpty)
            XCTAssertEqual(workflow.presets, originalPresets); XCTAssertEqual(picker.state, initial)
            XCTAssertNil(try PlusSyncLocalTransaction.pendingRecovery(in: root))
        }
    }

    @MainActor
    func testFailedFileRecoveryRetainsPrivateOriginalsAndBlocksAnotherTransaction() throws {
        try fixture { root, defaults in
            let noteURL = root.appendingPathComponent("quick-note.txt")
            let noteBytes = Data("Recover this original".utf8); try noteBytes.write(to: noteURL)
            var incoming = SyncSnapshot(deviceID: UUID()); try incoming.captureNote("Incoming")
            let tx = try transaction(root, defaults)
            var recovery: URL?
            XCTAssertThrowsError(try tx.apply(incoming) {
                // A real filesystem obstruction prevents restoring the original file.
                try FileManager.default.removeItem(at: noteURL)
                try FileManager.default.createDirectory(at: noteURL, withIntermediateDirectories: false)
                throw CocoaError(.fileWriteUnknown)
            }) { error in recovery = (error as? PlusSyncLocalApplyFailure)?.recoveryDirectory }
            let directory = try XCTUnwrap(recovery)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("quick-note.txt")), noteBytes)
            let discovered = try XCTUnwrap(PlusSyncLocalTransaction.pendingRecovery(in: root))
            XCTAssertEqual(discovered.resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
            XCTAssertThrowsError(try transaction(root, defaults), "No further local sync transaction may begin before recovery")
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("quick-note.txt")), noteBytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("defaults.plist").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("COMMITTED").path))
            let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o700)
        }
    }
}
