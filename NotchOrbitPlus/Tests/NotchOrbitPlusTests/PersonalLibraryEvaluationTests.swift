import AppKit
import SwiftUI
import NotchCore
import XCTest
@testable import NotchOrbitPlus

final class PersonalLibraryEvaluationTests: NativeImageFixtureCase, @unchecked Sendable {
    @MainActor
    func testSnippetsActuallyPersistCopyAndKeepLocalSecretAcrossSharedApply() throws {
        let store = SnippetsStore(directory: fixtureDirectory, onChange: {})
        let privateSnippet = CoreSnippet(title: "Local only", text: "Private fixture text")
        XCTAssertTrue(store.save(privateSnippet))
        let shared = CoreSnippet(title: "Reply", text: "Ordinary shared reply", allowsSync: true)
        try store.applySyncedLibrary(.init(snippets: [shared]))
        let reopened = SnippetsStore(directory: fixtureDirectory, onChange: {})
        XCTAssertEqual(reopened.library.snippets, [privateSnippet, shared])
        XCTAssertEqual(try reopened.exportSyncedLibrary().snippets, [shared])
        let board = NSPasteboard(name: .init("NotchSnippet.\(UUID().uuidString)")); defer { board.releaseGlobally() }
        reopened.copy(shared, to: board); XCTAssertEqual(board.string(forType: .string), shared.text)
        reopened.setEditorOpen(true)
        XCTAssertThrowsError(try reopened.applySyncedLibrary(.init()))
        XCTAssertEqual(reopened.library.snippets, [privateSnippet, shared])
        let file = fixtureDirectory.appendingPathComponent(SnippetsStore.fileName), original = Data("{unreadable-snippets".utf8)
        try original.write(to: file)
        let unreadable = SnippetsStore(directory: fixtureDirectory, onChange: {})
        XCTAssertFalse(unreadable.save(shared)); XCTAssertThrowsError(try unreadable.exportSyncedLibrary())
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testHabitsActuallyPersistDailyToggleAndPreserveCorruptOriginal() throws {
        let store = HabitsStore(directory: fixtureDirectory, onChange: {}); defer { store.shutdown() }
        store.add("Read")
        let habit = try XCTUnwrap(store.library.habits.first)
        store.toggleToday(habit.id)
        let reopened = HabitsStore(directory: fixtureDirectory, onChange: {}); defer { reopened.shutdown() }
        XCTAssertEqual(reopened.library.habits.first?.checkedDays, [store.today])
        XCTAssertEqual(CoreHabitCalendar.streak(try XCTUnwrap(reopened.library.habits.first), today: store.today), 1)
        reopened.toggleToday(habit.id); XCTAssertTrue(reopened.library.habits[0].checkedDays.isEmpty)
        let file = fixtureDirectory.appendingPathComponent(HabitsStore.fileName), original = Data("broken-habits".utf8)
        try original.write(to: file)
        let invalid = HabitsStore(directory: fixtureDirectory, onChange: {})
        invalid.add("Cannot replace corrupt history")
        XCTAssertThrowsError(try invalid.exportSyncedLibrary()); XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testExpiredOwnedShelfCopiesRemainUntilConfirmedAndUndoRestoresAfterRelaunch() throws {
        let managed = fixtureDirectory.appendingPathComponent("Managed", isDirectory: true)
        let original = fixtureDirectory.appendingPathComponent("original.txt"), bytes = Data("Keep original and owned copy".utf8)
        try bytes.write(to: original)
        let id = UUID(), ownedFolder = managed.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: ownedFolder, withIntermediateDirectories: true)
        let owned = ownedFolder.appendingPathComponent("original.txt"); try bytes.write(to: owned)
        let item = FileShelfItem(id: id, originalURL: original, managedURL: owned, addedAt: Date().addingTimeInterval(-10 * 86_400))
        let reference = FileShelfItem(originalURL: original, addedAt: item.addedAt)
        let archive = ShelfLibraryArchive(state: .init(items: [item, reference], retention: .week))
        let store = FileShelfToolStore(managedDirectory: managed, persistState: false, archive: archive, onPortableChange: {})
        defer { store.shutdown() }
        store.pruneExpired()
        XCTAssertEqual(store.items.count, 2); XCTAssertEqual(try Data(contentsOf: owned), bytes)
        XCTAssertEqual(store.cleanupPreview?.itemIDs, [item.id]); XCTAssertEqual(store.cleanupPreview?.excludedReferences, 1)
        XCTAssertTrue(store.collections.addShelf("Work"))
        let work = try XCTUnwrap(store.collections.shelves.first(where: { $0.name == "Work" }))
        XCTAssertTrue(store.move([item.id], to: work.id)); XCTAssertEqual(store.shelfID(for: item), work.id)
        XCTAssertEqual(try Data(contentsOf: owned), bytes); XCTAssertEqual(try Data(contentsOf: original), bytes)
        store.confirmCleanup([item.id]); XCTAssertNil(store.error)
        XCTAssertEqual(store.items.map(\.id), [reference.id]); XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path)); XCTAssertTrue(store.canUndoRemoval)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let reopened = FileShelfToolStore(managedDirectory: managed, persistState: false,
            archive: .init(state: .init(items: [reference])), onPortableChange: {})
        defer { reopened.shutdown() }
        XCTAssertTrue(reopened.canUndoRemoval); reopened.undoRemoval(); XCTAssertNil(reopened.error)
        XCTAssertEqual(Set(reopened.items.map(\.id)), [item.id, reference.id])
        XCTAssertEqual(try Data(contentsOf: owned), bytes); XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    @MainActor
    func testChosenFolderRuleDoesNotImportUntilActualPreviewAndExplicitEnable() async throws {
        let source = fixtureDirectory.appendingPathComponent("Chosen", isDirectory: true), managed = fixtureDirectory.appendingPathComponent("Managed", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("reply.txt"), bytes = Data("Real watched-folder fixture".utf8); try bytes.write(to: file)
        let link = source.appendingPathComponent("link.txt"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let store = FileShelfToolStore(managedDirectory: managed, persistState: false, onPortableChange: {}); defer { store.shutdown() }
        let rule = CoreShelfRule(name: "Watch text", kind: .watchFolder, tags: ["Watched"], fileExtensions: ["txt"])
        XCTAssertTrue(store.collections.saveRule(rule)); try store.collections.configureWatchedFolder(source, ruleID: rule.id)
        store.collections.startIfConfigured(); XCTAssertFalse(store.collections.watching); XCTAssertTrue(store.items.isEmpty)
        store.collections.enablePreviewedRule(rule.id); XCTAssertFalse(store.collections.isEnabled(rule.id))
        store.previewRule(rule)
        for _ in 0..<100 where store.collections.preview == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try XCTUnwrap(store.collections.preview).fileURLs.map(\.lastPathComponent), ["reply.txt"])
        XCTAssertTrue(store.items.isEmpty, "A real preview must not import files or follow the link")
        store.collections.enablePreviewedRule(rule.id)
        for _ in 0..<100 where store.items.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(store.items.count, 1); XCTAssertEqual(store.info(for: item).tags, ["Watched"])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(item.managedURL)), bytes); XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), file.path)
        var changed = rule; changed.tags = ["Changed"]
        XCTAssertTrue(store.collections.saveRule(changed)); XCTAssertFalse(store.collections.isEnabled(rule.id)); XCTAssertFalse(store.collections.watching)
    }

    func testInboxActualUniqueCoordinatedCopiesPreserveSourceAndRejectLinks() throws {
        let destination = fixtureDirectory.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let file = fixtureDirectory.appendingPathComponent("source.txt"), bytes = Data("File or note handoff fixture".utf8); try bytes.write(to: file)
        let first = try OrbitInboxStore.writeFile(file, to: destination), second = try OrbitInboxStore.writeFile(file, to: destination)
        XCTAssertNotEqual(first, second); XCTAssertEqual(try Data(contentsOf: first), bytes); XCTAssertEqual(try Data(contentsOf: second), bytes)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let note = try OrbitInboxStore.writeNote(bytes, to: destination); XCTAssertEqual(note.pathExtension, "txt"); XCTAssertEqual(try Data(contentsOf: note), bytes)
        let link = fixtureDirectory.appendingPathComponent("link.txt"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try OrbitInboxStore.writeFile(link, to: destination)); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 3)
        XCTAssertThrowsError(try OrbitInboxStore.writeNote(Data(), to: destination))
    }

    @MainActor
    func testLateRealIOFailureRollsBackAllNewSyncLibrariesAndAbsentLegacyFiles() throws {
        let snippets = SnippetsStore(directory: fixtureDirectory, onChange: {})
        XCTAssertTrue(snippets.save(.init(title: "Private retained text", text: "Only on this Mac")))
        let habits = HabitsStore(directory: fixtureDirectory, onChange: {}); defer { habits.shutdown() }; habits.add("Original habit")
        let shelves = ShelfCollectionsStore(directory: fixtureDirectory, onChange: {}); defer { shelves.shutdown() }; XCTAssertTrue(shelves.addShelf("Original shelf"))
        let oldSnippet = snippets.library, oldHabits = habits.library, oldShelves = shelves.state
        let names = [SnippetsStore.fileName, HabitsStore.fileName, ShelfCollectionsStore.fileName]
        let oldBytes = try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: fixtureDirectory.appendingPathComponent($0))) })
        let tx = try PlusSyncLocalTransaction(in: fixtureDirectory, files: [
            ("quick-note.txt", 200_000), ("todos.json", 4 * 1024 * 1024), ("sync-state-v1.json", SyncSnapshot.maximumBytes),
            (SnippetsStore.fileName, CoreSnippetLibrary.maximumBytes), (HabitsStore.fileName, CoreHabitLibrary.maximumBytes), (ShelfCollectionsStore.fileName, 3 * 1024 * 1024)
        ])
        tx.addRollback(snippets.prepareSyncRollback()); tx.addRollback(habits.prepareSyncRollback()); tx.addRollback(shelves.prepareSyncRollback())
        var incoming = SyncSnapshot(deviceID: UUID()); try incoming.captureNote("Incoming note")
        var reachedIOFailure = false
        XCTAssertThrowsError(try tx.apply(incoming) {
            try snippets.applySyncedLibrary(.init(snippets: [.init(title: "Shared incoming", text: "Ordinary reply", allowsSync: true)]))
            try habits.applySyncedLibrary(.init(habits: [.init(name: "Incoming habit", checkedDays: ["2026-10-04"])]))
            try shelves.applySyncedLibrary(.init(shelves: [.init(id: CoreShelfCollection.inboxID, name: "Incoming Inbox")]))
            reachedIOFailure = true
            try Data("Cannot write a regular file over a directory".utf8).write(to: fixtureDirectory)
        }) { error in XCTAssertTrue(error is PlusSyncLocalApplyFailure); XCTAssertNil((error as? PlusSyncLocalApplyFailure)?.recoveryDirectory) }
        XCTAssertTrue(reachedIOFailure)
        XCTAssertEqual(snippets.library, oldSnippet); XCTAssertEqual(habits.library, oldHabits); XCTAssertEqual(shelves.state, oldShelves)
        for name in names { XCTAssertEqual(try Data(contentsOf: fixtureDirectory.appendingPathComponent(name)), oldBytes[name]) }
        for name in ["quick-note.txt", "todos.json", "sync-state-v1.json"] { XCTAssertFalse(try PlusSyncFolderIO.hasNode(fixtureDirectory.appendingPathComponent(name))) }
        XCTAssertNil(try PlusSyncLocalTransaction.pendingRecovery(in: fixtureDirectory))
    }

    @MainActor
    func testActualSnippetsHabitsAndShelfSettingsRenderWithoutProviders() async throws {
        let snippets = SnippetsStore(directory: fixtureDirectory, onChange: {})
        XCTAssertTrue(snippets.save(.init(title: "Project reply", text: "Thanks — I will review the update today.", allowsSync: true)))
        let habits = HabitsStore(directory: fixtureDirectory, onChange: {}); defer { habits.shutdown() }
        habits.add("Walk outside"); habits.toggleToday(try XCTUnwrap(habits.library.habits.first).id)
        let shelf = FileShelfToolStore(managedDirectory: fixtureDirectory.appendingPathComponent("Shelf"), persistState: false, onPortableChange: {}); defer { shelf.shutdown() }
        XCTAssertTrue(shelf.collections.addShelf("Projects")); XCTAssertTrue(shelf.collections.saveRule(.init(name: "Capture copies", kind: .captures, tags: ["Capture"])))
        try await render(SnippetsToolView(store: snippets), name: "NotchOrbitPlus-Snippets-fixture-library.png")
        try await render(HabitsToolView(store: habits), name: "NotchOrbitPlus-Habits-fixture-seven-weeks.png")
        try await render(ShelfSettingsView(store: shelf), name: "NotchOrbitPlus-ShelfRules-fixture-disabled.png")
        XCTAssertFalse(shelf.collections.watching); XCTAssertTrue(shelf.items.isEmpty)
    }
    @MainActor private func render<V: View>(_ view: V, name: String) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; let host = NSHostingView(rootView: view.frame(width: 560, height: 480).background(Color(nsColor: window.backgroundColor)))
        window.contentView = host; window.makeKeyAndOrderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:])); XCTAssertGreaterThan(bytes.count, 1_000)
        let environment = ProcessInfo.processInfo.environment
        let path = environment["NOTCHORBITPLUS_EVAL_DIR"] ?? environment["TEST_RUNNER_NOTCHORBITPLUS_EVAL_DIR"]
        let output = path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fixtureDirectory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true); try bytes.write(to: output.appendingPathComponent(name))
    }
}
