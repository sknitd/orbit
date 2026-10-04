import Foundation
import XCTest
@testable import NotchCore

final class SyncPortableLibraryTests: XCTestCase {
    private func anotherDevice(_ source: SyncSnapshot, id: UUID) throws -> SyncSnapshot {
        let blank = SyncSnapshot(deviceID: id)
        return try SyncMerge.threeWay(base: blank, local: blank, remote: source)
    }
    private func library() throws -> SyncPortableLibrary {
        let folderID = UUID()
        return SyncPortableLibrary(launcherPins: [
            SyncLauncherPin(id: UUID(), label: "Editor", kind: .application, targetIdentifier: "com.example.Editor"),
            SyncLauncherPin(id: folderID, label: "Projects", kind: .folder, targetIdentifier: folderID.uuidString),
            SyncLauncherPin(id: UUID(), label: "Delivery", kind: .shortcut, targetIdentifier: UUID().uuidString)
        ], workflows: [WorkflowPreset(name: "Delivery", steps: [.convert(format: .jpeg), .zip])],
        palettes: try CoreColorPaletteLibrary(palettes: [CoreColorPalette(name: "Ocean", colors: [CoreColorRGBA(red: 0, green: 0.5, blue: 1)])]))
    }
    func testVersionOneSnapshotMigratesWithoutResettingMissingNewPreferences() throws {
        var source = SyncSnapshot(deviceID: UUID()); try source.captureNote("Legacy note"); try source.captureSettings(SyncSharedSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source.encoded()) as? [String: Any])
        object["schemaVersion"] = 1
        for key in ["launcherPins", "workflows", "palettes"] { object.removeValue(forKey: key) }
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), original = legacy
        let migrated = try SyncSnapshot.decode(legacy)
        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertEqual(migrated.note.preferred(on: source.deviceID), "Legacy note")
        XCTAssertTrue(migrated.launcherPins.revisions.isEmpty); XCTAssertTrue(migrated.workflows.revisions.isEmpty); XCTAssertTrue(migrated.palettes.revisions.isEmpty)
        let settings = try XCTUnwrap(migrated.settings.preferred(on: source.deviceID))
        XCTAssertNil(settings.appearance); XCTAssertNil(settings.livePriority); XCTAssertNil(settings.worldZoneIDs)
        XCTAssertEqual(legacy, original)
        XCTAssertEqual(try SyncSnapshot.decode(migrated.encoded()), migrated)
    }
    func testPortableTargetsContainOnlyLogicalIdentifiersAndRejectPaths() throws {
        let value = try library(); try value.validate()
        let bytes = try JSONEncoder().encode(value.launcherPins)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        for object in objects { XCTAssertEqual(Set(object.keys), ["id", "label", "kind", "targetIdentifier"]) }
        for path in ["/Applications/Editor.app", "/Users/test/Projects", "~/Projects", "file:///tmp/app"] {
            XCTAssertThrowsError(try SyncLauncherPin(id: UUID(), label: "Bad app", kind: .application, targetIdentifier: path).validate())
            XCTAssertThrowsError(try SyncLauncherPin(id: UUID(), label: "Bad folder", kind: .folder, targetIdentifier: path).validate())
        }
        XCTAssertThrowsError(try SyncLauncherPin(id: UUID(), label: "Wrong folder identity", kind: .folder, targetIdentifier: UUID().uuidString).validate())
        let duplicate = SyncLauncherPin(id: UUID(), label: "Same editor", kind: .application, targetIdentifier: value.launcherPins[0].targetIdentifier)
        XCTAssertThrowsError(try SyncLauncherPin.validate(value.launcherPins + [duplicate]))
    }
    func testIndependentWorkflowAndPaletteEditsMergeAcrossDevicesWithoutConflict() throws {
        var base = SyncSnapshot(deviceID: UUID()); try base.capturePortable(library())
        var left = base, right = try anotherDevice(base, id: UUID())
        var l = left.portableLibrary(), r = right.portableLibrary()
        l.workflows[0].name = "New delivery"
        r.palettes = try CoreColorPaletteLibrary(palettes: [CoreColorPalette(id: r.palettes.palettes[0].id, name: "Sky", colors: [CoreColorRGBA(red: 0.2, green: 0.3, blue: 0.4)])])
        try left.capturePortable(l); try right.capturePortable(r)
        let merged = try SyncMerge.threeWay(base: base, local: left, remote: right)
        XCTAssertEqual(merged.portableLibrary().workflows[0].name, "New delivery")
        XCTAssertEqual(merged.portableLibrary().palettes.palettes[0].name, "Sky")
        XCTAssertEqual(merged.conflictCount, 0)
    }
    func testConcurrentLauncherVariantsRemainUntilExplicitResolution() throws {
        var base = SyncSnapshot(deviceID: UUID()); try base.capturePortable(library())
        var left = base, right = try anotherDevice(base, id: UUID())
        var l = left.portableLibrary(), r = right.portableLibrary()
        l.launcherPins[0].label = "Local label"; r.launcherPins[0].label = "Other label"
        try left.capturePortable(l); try right.capturePortable(r)
        var merged = try SyncMerge.threeWay(base: base, local: left, remote: right)
        XCTAssertTrue(merged.launcherPins.hasConflict)
        XCTAssertEqual(Set(merged.launcherPins.revisions.map { $0.value[0].label }), ["Local label", "Other label"])
        var chosen = merged.portableLibrary(); chosen.launcherPins = r.launcherPins
        try merged.capturePortable(chosen, resolve: .launcher)
        let final = try SyncMerge.threeWay(base: base, local: left, remote: merged)
        XCTAssertFalse(final.launcherPins.hasConflict); XCTAssertEqual(final.portableLibrary().launcherPins[0].label, "Other label")
    }
    func testPaletteDeletionSurvivesStalePeerAndDoesNotIncludeSamplingHistory() throws {
        var base = SyncSnapshot(deviceID: UUID()); try base.capturePortable(library())
        var removed = base, empty = base.portableLibrary(); empty.palettes = try CoreColorPaletteLibrary()
        try removed.capturePortable(empty)
        let final = try SyncMerge.threeWay(base: base, local: removed, remote: base)
        XCTAssertTrue(final.portableLibrary().palettes.palettes.isEmpty)
        let data = try base.encoded(), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("bookmark")); XCTAssertFalse(text.contains("history")); XCTAssertFalse(text.contains("/Applications/")); XCTAssertFalse(text.contains("/Users/"))
    }
    func testInvalidWorkflowOrExcessivePinsCannotMutateExistingSnapshot() throws {
        var source = SyncSnapshot(deviceID: UUID()); try source.capturePortable(library())
        let original = try source.encoded()
        var invalid = source.portableLibrary(); invalid.workflows[0].name = "../unsafe"
        XCTAssertThrowsError(try source.capturePortable(invalid)); XCTAssertEqual(try source.encoded(), original)
        invalid = source.portableLibrary()
        invalid.launcherPins = (0...256).map { index in SyncLauncherPin(id: UUID(), label: "App \(index)", kind: .application, targetIdentifier: "com.example.App\(index)") }
        XCTAssertThrowsError(try source.capturePortable(invalid)); XCTAssertEqual(try source.encoded(), original)
    }
}
