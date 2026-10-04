import Foundation
import XCTest
@testable import NotchCore

final class PersonalLibraryTests: XCTestCase {
    func testSnippetSearchFoldsAccentsAndSyncOmitsLocalSecretsAndPrivateFolders() throws {
        let privateFolder = CoreSnippetFolder(name: "Private"), sharedFolder = CoreSnippetFolder(name: "Replies")
        let secret = CoreSnippet(folderID: privateFolder.id, title: "Local code", text: "123456")
        let reply = CoreSnippet(folderID: sharedFolder.id, title: "Café reply", text: "Hello team", allowsSync: true)
        let library = CoreSnippetLibrary(folders: [privateFolder, sharedFolder], snippets: [secret, reply])
        XCTAssertEqual(library.search("CAFE team").map(\.id), [reply.id])
        let shared = library.syncLibrary()
        XCTAssertEqual(shared.snippets, [reply]); XCTAssertEqual(shared.folders, [sharedFolder])
        XCTAssertFalse(String(decoding: try shared.encoded(), as: UTF8.self).contains("123456"))
        XCTAssertEqual(try CoreSnippetLibrary.decode(library.encoded()), library)
    }
    func testIncomingSnippetChangesRetainLocalOnlyDataAndRejectIdentityCollision() throws {
        let local = CoreSnippet(title: "Private", text: "Local original")
        let ordinary = CoreSnippet(title: "Shared", text: "Ordinary text", allowsSync: true)
        let library = CoreSnippetLibrary(snippets: [local])
        XCTAssertEqual(try library.applyingShared(.init(snippets: [ordinary])).snippets, [local, ordinary])
        var collision = local; collision.allowsSync = true; collision.text = "Incoming"
        XCTAssertThrowsError(try library.applyingShared(.init(snippets: [collision])))
        XCTAssertThrowsError(try library.applyingShared(.init(snippets: [local])))
        XCTAssertEqual(library.snippets, [local])
    }
    func testSnippetBoundsAndMalformedFolderReferencesRejectOriginalPayload() throws {
        XCTAssertThrowsError(try CoreSnippetLibrary(snippets: [.init(folderID: UUID(), title: "Wrong folder", text: "Text")]).encoded())
        XCTAssertThrowsError(try CoreSnippetLibrary(snippets: [.init(title: "Large", text: String(repeating: "x", count: 32_769))]).encoded())
        XCTAssertThrowsError(try CoreSnippetLibrary.decode(Data(repeating: 32, count: CoreSnippetLibrary.maximumBytes + 1)))
        XCTAssertThrowsError(try CoreSnippetLibrary.decode(Data("{broken".utf8)))
    }
    func testHabitGregorianDatesRejectRolloverAndCountLeapDayAcrossMonthBoundary() throws {
        XCTAssertNil(CoreHabitCalendar.date("2025-02-29")); XCTAssertNil(CoreHabitCalendar.date("2024-02-30"))
        XCTAssertNil(CoreHabitCalendar.date("2024-2-09")); XCTAssertNil(CoreHabitCalendar.date("2024-13-01"))
        let habit = CoreHabit(name: "Walk", checkedDays: ["2024-02-28", "2024-02-29", "2024-03-01"])
        XCTAssertEqual(CoreHabitCalendar.streak(habit, today: "2024-03-01"), 3)
        XCTAssertEqual(CoreHabitCalendar.streak(habit, today: "2024-03-02"), 3)
        XCTAssertEqual(CoreHabitCalendar.streak(habit, today: "2024-03-03"), 0)
        let heatmap = CoreHabitCalendar.heatmap(habit, through: "2024-03-02")
        XCTAssertEqual(heatmap.count, 49); XCTAssertEqual(heatmap.last?.id, "2024-03-02"); XCTAssertEqual(heatmap.filter(\.checked).count, 3)
    }
    func testHabitLocalDayTimezoneAndTogglePersistenceDoNotCountDuplicateCheckoffs() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-03-10T07:30:00Z"))
        XCTAssertEqual(CoreHabitCalendar.key(for: date, timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))), "2024-03-09")
        let habit = CoreHabit(name: "Read"); var library = CoreHabitLibrary(habits: [habit])
        try library.toggle(habit.id, day: "2024-03-10"); XCTAssertEqual(library.habits[0].checkedDays, ["2024-03-10"])
        XCTAssertEqual(try CoreHabitLibrary.decode(library.encoded()), library)
        try library.toggle(habit.id, day: "2024-03-10"); XCTAssertTrue(library.habits[0].checkedDays.isEmpty)
        XCTAssertThrowsError(try library.toggle(habit.id, day: "2024-04-31"))
        XCTAssertThrowsError(try CoreHabitLibrary(habits: [.init(name: "Duplicates", checkedDays: ["2024-01-01", "2024-01-01"])]).encoded())
    }
    func testSyncMigratesVersionTwoAndRetainsConcurrentHabitAndSnippetVariants() throws {
        let a = UUID(), b = UUID(); var base = SyncSnapshot(deviceID: a)
        let shared = CoreSnippet(title: "Reply", text: "Base", allowsSync: true)
        let habit = CoreHabit(name: "Walk")
        try base.capturePortable(.init(snippets: .init(snippets: [shared]), habits: .init(habits: [habit])))
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: base.encoded()) as? [String: Any])
        old["schemaVersion"] = 2; old.removeValue(forKey: "snippets"); old.removeValue(forKey: "habits"); old.removeValue(forKey: "shelves")
        let migrated = try SyncSnapshot.decode(JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(migrated.schemaVersion, 3); XCTAssertTrue(migrated.snippets.revisions.isEmpty)
        var local = base, remote = try SyncMerge.threeWay(base: .init(deviceID: b), local: .init(deviceID: b), remote: base)
        var left = shared, right = shared; left.text = "Local"; right.text = "Remote"
        var leftHabits = CoreHabitLibrary(habits: [habit]), rightHabits = leftHabits
        try leftHabits.toggle(habit.id, day: "2026-10-03"); try rightHabits.toggle(habit.id, day: "2026-10-04")
        try local.capturePortable(.init(snippets: .init(snippets: [left]), habits: leftHabits))
        try remote.capturePortable(.init(snippets: .init(snippets: [right]), habits: rightHabits))
        let merged = try SyncMerge.threeWay(base: base, local: local, remote: remote)
        XCTAssertTrue(merged.snippets.hasConflict); XCTAssertTrue(merged.habits.hasConflict)
        XCTAssertEqual(Set(merged.snippets.revisions.map { $0.value.snippets[0].text }), ["Local", "Remote"])
        XCTAssertEqual(merged.habits.revisions.count, 2)
        XCTAssertEqual(try SyncSnapshot.decode(merged.encoded()), merged)
    }
    func testOwnedCleanupPlanExcludesReferencesOriginalAliasesAndForeignPaths() throws {
        let root = URL(fileURLWithPath: "/private/shelf"), original = URL(fileURLWithPath: "/original/file.txt"), old = Date(timeIntervalSince1970: 100)
        let id = UUID(), valid = FileShelfItem(id: id, originalURL: original, managedURL: root.appendingPathComponent(id.uuidString).appendingPathComponent("file.txt"), addedAt: old)
        let reference = FileShelfItem(originalURL: original, addedAt: old)
        let foreign = FileShelfItem(originalURL: original, managedURL: URL(fileURLWithPath: "/outside/file.txt"), addedAt: old)
        let originalAlias = FileShelfItem(originalURL: valid.managedURL!, managedURL: valid.managedURL!, addedAt: old)
        let fresh = FileShelfItem(originalURL: original, addedAt: Date(timeIntervalSince1970: 1000))
        let plan = CoreShelfCleanupPlan.preview(items: [valid, reference, foreign, originalAlias, fresh], managedRoot: root, olderThan: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(plan.itemIDs, [valid.id]); XCTAssertEqual(plan.excludedReferences, 1)
    }
    func testPortableShelfRulesRoundTripWithoutFilesystemOrEnablementAndBoundTargets() throws {
        let shelf = CoreShelfCollection(name: "Screenshots")
        let configuration = CoreShelfConfiguration(shelves: [.init(id: CoreShelfCollection.inboxID, name: "Inbox"), shelf], rules: [.init(name: "Capture copies", kind: .captures, shelfID: shelf.id, tags: ["Capture"], fileExtensions: ["png"])])
        XCTAssertEqual(try CoreShelfConfiguration.decode(configuration.encoded()), configuration)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: configuration.encoded()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "shelves", "rules"])
        XCTAssertThrowsError(try CoreShelfConfiguration(rules: [.init(name: "Foreign shelf", kind: .watchFolder, shelfID: UUID())]).encoded())
        XCTAssertThrowsError(try CoreShelfConfiguration(rules: [.init(name: "Unsafe suffix", kind: .watchFolder, fileExtensions: ["../png"])]).encoded())
    }
}
