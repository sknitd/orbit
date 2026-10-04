import Foundation
import XCTest
@testable import NotchCore

final class SyncModelsTests: XCTestCase {
    private let a = UUID(), b = UUID()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private func onDevice(_ source: SyncSnapshot, _ device: UUID) throws -> SyncSnapshot {
        try SyncMerge.threeWay(base: SyncSnapshot(deviceID: device), local: SyncSnapshot(deviceID: device), remote: source)
    }
    func testRoundTripAndDistinctDevicesMergeIndependentTaskFields() throws {
        var original = SyncSnapshot(deviceID: a)
        let item = ToDoItem(title: "Plan", createdAt: date)
        try original.captureTasks([item], at: date)
        XCTAssertEqual(try SyncSnapshot.decode(original.encoded()), original)
        var left = original, right = try onDevice(original, b)
        var leftItem = item; leftItem.title = "Plan revised"
        var rightItem = item; rightItem.starred = true
        try left.captureTasks([leftItem], at: date.addingTimeInterval(10))
        try right.captureTasks([rightItem], at: date.addingTimeInterval(-60_000)) // clock skew cannot lose the edit
        let merged = try SyncMerge.threeWay(base: original, local: left, remote: right)
        XCTAssertEqual(merged.visibleTasks()[0].title, "Plan revised")
        XCTAssertTrue(merged.visibleTasks()[0].starred)
        XCTAssertEqual(merged.conflictCount, 0)
    }
    func testDeletionTombstoneSurvivesStaleSnapshotsAndConcurrentTaskEdit() throws {
        var original = SyncSnapshot(deviceID: a)
        let item = ToDoItem(title: "Delete me", createdAt: date)
        try original.captureTasks([item], at: date)
        var deletion = original, editing = try onDevice(original, b)
        try deletion.captureTasks([], at: date.addingTimeInterval(5))
        var changed = item; changed.title = "Concurrent edit preserved in tombstone"
        try editing.captureTasks([changed], at: date.addingTimeInterval(3))
        let merged = try SyncMerge.threeWay(base: original, local: deletion, remote: editing)
        XCTAssertTrue(merged.visibleTasks().isEmpty)
        XCTAssertEqual(merged.tasks.count, 1)
        XCTAssertTrue(merged.tasks[0].isDeleted)
        XCTAssertTrue(merged.tasks[0].title.revisions.contains { $0.value == changed.title })
        let again = try SyncMerge.threeWay(base: original, local: merged, remote: original)
        XCTAssertTrue(again.visibleTasks().isEmpty)
    }
    func testConcurrentNotesPreserveBothUnsavedEditsAndExplicitResolutionConverges() throws {
        var original = SyncSnapshot(deviceID: a)
        try original.captureNote("Base", at: date)
        var left = original, right = try onDevice(original, b)
        try left.captureNote("Local unsaved draft", at: date.addingTimeInterval(100))
        try right.captureNote("Other Mac", at: date.addingTimeInterval(-100))
        var merged = try SyncMerge.threeWay(base: original, local: left, remote: right)
        XCTAssertTrue(merged.note.hasConflict)
        XCTAssertEqual(Set(merged.note.revisions.map(\.value)), ["Local unsaved draft", "Other Mac"])
        XCTAssertEqual(merged.note.preferred(on: a), "Local unsaved draft")
        try merged.captureNote("Combined intentionally", at: date, resolve: true)
        let converged = try SyncMerge.threeWay(base: original, local: right, remote: merged)
        XCTAssertFalse(converged.note.hasConflict)
        XCTAssertEqual(converged.note.preferred(on: b), "Combined intentionally")
    }
    func testConcurrentSettingsPreserveVariantsAndNeverIncludeDeviceConfiguration() throws {
        var original = SyncSnapshot(deviceID: a)
        try original.captureSettings(SyncSharedSettings(), at: date)
        var left = original, right = try onDevice(original, b)
        var l = SyncSharedSettings(); l.openMode = "clickOnly"
        var r = SyncSharedSettings(); r.hoverDelay = 1.0
        try left.captureSettings(l, at: date); try right.captureSettings(r, at: date)
        let merged = try SyncMerge.threeWay(base: original, local: left, remote: right)
        XCTAssertTrue(merged.settings.hasConflict)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: merged.encoded()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "deviceID", "generatedAt", "context", "note", "settings", "tasks", "launcherPins", "workflows", "palettes", "snippets", "habits", "shelves"])
        let settings = try XCTUnwrap(object["settings"] as? [String: Any])
        let revisions = try XCTUnwrap(settings["revisions"] as? [[String: Any]])
        for revision in revisions {
            let value = try XCTUnwrap(revision["value"] as? [String: Any])
            XCTAssertEqual(Set(value.keys), ["toolOrder", "hiddenToolIDs", "openMode", "hoverDelay"])
        }
    }
    func testEqualConcurrentValuesMergeIdempotentlyWithoutCreatingSpuriousConflicts() throws {
        var original = SyncSnapshot(deviceID: a)
        try original.captureNote("Base", at: date)
        var left = original, right = try onDevice(original, b)
        try left.captureNote("Same", at: date); try right.captureNote("Same", at: date)
        let merged = try SyncMerge.threeWay(base: original, local: left, remote: right)
        XCTAssertFalse(merged.note.hasConflict)
        let again = try SyncMerge.threeWay(base: original, local: merged, remote: left)
        XCTAssertEqual(again.note, merged.note)
        XCTAssertEqual(again.context, merged.context)
    }
    func testOversizedCorruptAndUnsupportedSnapshotsLeaveOriginalUntouched() throws {
        var original = SyncSnapshot(deviceID: a)
        try original.captureNote("Keep original", at: date)
        let bytes = try original.encoded()
        XCTAssertThrowsError(try SyncSnapshot.decode(Data(repeating: 65, count: SyncSnapshot.maximumBytes + 1)))
        XCTAssertThrowsError(try SyncSnapshot.decode(Data("{broken".utf8)))
        var unsupported = original; unsupported.schemaVersion = 99
        XCTAssertThrowsError(try unsupported.encoded())
        XCTAssertThrowsError(try original.captureNote(String(repeating: "é", count: 100_001), at: date))
        XCTAssertEqual(try original.encoded(), bytes)
        var invalid = ToDoItem(title: "Valid", createdAt: date); invalid.title = ""
        XCTAssertThrowsError(try original.captureTasks([invalid]))
        XCTAssertEqual(try original.encoded(), bytes)
    }
}
