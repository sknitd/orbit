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
    func testPreviewedEnabledExpiryAutomaticallyRetainsCopiesAndUndoDisablesRulesAcrossRelaunch() throws {
        let managed = fixtureDirectory.appendingPathComponent("AutoExpiry", isDirectory: true)
        let original = fixtureDirectory.appendingPathComponent("original-auto.txt"), bytes = Data("Original must remain unchanged".utf8)
        try bytes.write(to: original)
        let id = UUID(), folder = managed.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("original-auto.txt"); try bytes.write(to: copy)
        let item = FileShelfItem(id: id, originalURL: original, managedURL: copy, addedAt: Date().addingTimeInterval(-10 * 86_400))
        let reference = FileShelfItem(originalURL: original, addedAt: item.addedAt)
        let archive = ShelfLibraryArchive(state: .init(items: [item, reference], retention: .forever))
        try JSONEncoder().encode(archive).write(to: managed.appendingPathComponent("file-shelf.json"))
        let store = FileShelfToolStore(managedDirectory: managed, persistState: true, onPortableChange: {}); defer { store.shutdown() }
        let rule = CoreShelfRule(name: "Seven-day owned-copy expiry", kind: .expireOwnedCopies, days: 7)
        XCTAssertTrue(store.collections.saveRule(rule)); store.pruneExpired()
        XCTAssertEqual(store.items.count, 2); XCTAssertEqual(try Data(contentsOf: copy), bytes)
        store.collections.enablePreviewedRule(rule.id); XCTAssertFalse(store.collections.isEnabled(rule.id))
        store.previewRule(rule); XCTAssertEqual(store.collections.preview?.cleanupIDs, [item.id])
        store.collections.enablePreviewedRule(rule.id)
        XCTAssertTrue(store.collections.isEnabled(rule.id)); XCTAssertNil(store.error)
        XCTAssertEqual(store.items.map(\.id), [reference.id]); XCTAssertTrue(store.canUndoRemoval)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path)); XCTAssertEqual(try Data(contentsOf: original), bytes)
        store.shutdown()
        let reopened = FileShelfToolStore(managedDirectory: managed, persistState: true, onPortableChange: {}); defer { reopened.shutdown() }
        XCTAssertTrue(reopened.collections.isEnabled(rule.id)); XCTAssertTrue(reopened.canUndoRemoval)
        reopened.undoRemoval(); XCTAssertNil(reopened.error); XCTAssertFalse(reopened.collections.isEnabled(rule.id))
        XCTAssertEqual(Set(reopened.items.map(\.id)), [item.id, reference.id]); XCTAssertEqual(try Data(contentsOf: copy), bytes)
        reopened.pruneExpired(); XCTAssertEqual(try Data(contentsOf: copy), bytes)
        reopened.collections.enablePreviewedRule(rule.id)
        XCTAssertFalse(reopened.collections.isEnabled(rule.id), "Undo invalidates the old preview; renewed background expiry requires a fresh preview")
        let third = FileShelfToolStore(managedDirectory: managed, persistState: true, onPortableChange: {}); defer { third.shutdown() }
        XCTAssertFalse(third.collections.isEnabled(rule.id)); XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    @MainActor
    func testFailedAutomaticExpiryStaysPausedAcrossRelaunchUntilExplicitRetry() throws {
        let managed = fixtureDirectory.appendingPathComponent("FailedExpiry", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: false)
        let original = fixtureDirectory.appendingPathComponent("source-paused.txt"), bytes = Data("Keep this source".utf8); try bytes.write(to: original)
        let id = UUID(), folder = managed.appendingPathComponent(id.uuidString, isDirectory: true), copy = folder.appendingPathComponent("source-paused.txt")
        let item = FileShelfItem(id: id, originalURL: original, managedURL: copy, addedAt: Date().addingTimeInterval(-8 * 86_400))
        try JSONEncoder().encode(ShelfLibraryArchive(state: .init(items: [item], retention: .forever))).write(to: managed.appendingPathComponent("file-shelf.json"))
        let store = FileShelfToolStore(managedDirectory: managed, persistState: true, onPortableChange: {}); defer { store.shutdown() }
        let rule = CoreShelfRule(name: "Expiry with IO failure", kind: .expireOwnedCopies, days: 7)
        XCTAssertTrue(store.collections.saveRule(rule)); store.previewRule(rule); store.collections.enablePreviewedRule(rule.id)
        XCTAssertTrue(store.expiryRequiresRetry); XCTAssertEqual(store.items.map(\.id), [item.id]); XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: original), bytes); store.shutdown()
        let reopened = FileShelfToolStore(managedDirectory: managed, persistState: true, onPortableChange: {}); defer { reopened.shutdown() }
        XCTAssertTrue(reopened.expiryRequiresRetry)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); try bytes.write(to: copy)
        reopened.pruneExpired(); XCTAssertEqual(try Data(contentsOf: copy), bytes, "Restoring readable access alone must not cause an automatic retry")
        reopened.retryAutomaticExpiry(); XCTAssertFalse(reopened.expiryRequiresRetry); XCTAssertNil(reopened.error)
        XCTAssertTrue(reopened.items.isEmpty); XCTAssertTrue(reopened.canUndoRemoval); XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    @MainActor
    func testOwnSiblingOriginalSurvivesEnabledExpiryRemoveAndConfirmedCleanup() throws {
        let managed = fixtureDirectory.appendingPathComponent("SiblingOriginal", isDirectory: true), id = UUID()
        let folder = managed.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("original.txt"), copy = folder.appendingPathComponent("copy.txt")
        let originalBytes = Data("Indexed original sibling".utf8), copyBytes = Data("Managed copy".utf8)
        try originalBytes.write(to: original); try copyBytes.write(to: copy)
        let item = FileShelfItem(id: id, originalURL: original, managedURL: copy, addedAt: Date().addingTimeInterval(-10 * 86_400))
        let store = FileShelfToolStore(managedDirectory: managed, persistState: false,
            archive: .init(state: .init(items: [item], retention: .week)), onPortableChange: {})
        defer { store.shutdown() }
        try assertAllFolderRemovalPathsRefused(store, item: item)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes); XCTAssertEqual(try Data(contentsOf: copy), copyBytes)
    }

    @MainActor
    func testCrossShelfCanonicalDescendantAndAncestorReferencesProtectWholeOwnedFolder() throws {
        let managed = fixtureDirectory.appendingPathComponent("CrossShelfOriginal", isDirectory: true), id = UUID()
        let folder = managed.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = fixtureDirectory.appendingPathComponent("external-original.txt"), copy = folder.appendingPathComponent("copy.txt"), bytes = Data("Original/reference must retain its exact location".utf8)
        try bytes.write(to: original); try bytes.write(to: copy)
        let alias = fixtureDirectory.appendingPathComponent("managed-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: managed)
        let referenceURL = alias.appendingPathComponent(id.uuidString).appendingPathComponent(copy.lastPathComponent)
        let item = FileShelfItem(id: id, originalURL: original, managedURL: copy, addedAt: Date().addingTimeInterval(-10 * 86_400))
        let reference = FileShelfItem(originalURL: referenceURL)
        let store = FileShelfToolStore(managedDirectory: managed, persistState: false,
            archive: .init(state: .init(items: [item, reference], retention: .week)), onPortableChange: {})
        defer { store.shutdown() }
        XCTAssertTrue(store.collections.addShelf("Other shelf")); let other = try XCTUnwrap(store.collections.shelves.first(where: { $0.name == "Other shelf" }))
        XCTAssertTrue(store.move([reference.id], to: other.id))
        try assertAllFolderRemovalPathsRefused(store, item: item)
        XCTAssertEqual(try Data(contentsOf: referenceURL), bytes); XCTAssertEqual(try Data(contentsOf: original), bytes)
        let ancestorReference = FileShelfItem(originalURL: managed)
        let originalDirectoryEntries = try FileManager.default.contentsOfDirectory(atPath: managed.path).sorted()
        let ancestorStore = FileShelfToolStore(managedDirectory: managed, persistState: false,
            archive: .init(state: .init(items: [item, ancestorReference], retention: .week)), onPortableChange: {})
        defer { ancestorStore.shutdown() }
        try assertAllFolderRemovalPathsRefused(ancestorStore, item: item)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: managed.path).sorted(), originalDirectoryEntries)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), managed.path)
    }

    @MainActor
    func testUnexpectedSiblingsAndDirectoryCopyChildrenAreRetainedByAllRemovalPaths() throws {
        let managed = fixtureDirectory.appendingPathComponent("UnknownContents", isDirectory: true), id = UUID()
        let folder = managed.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = fixtureDirectory.appendingPathComponent("original-unknown.txt"), copy = folder.appendingPathComponent("copy.txt"), unexpected = folder.appendingPathComponent("unindexed-original.txt")
        let bytes = Data("Retain every unknown file".utf8)
        try bytes.write(to: original); try bytes.write(to: copy); try bytes.write(to: unexpected)
        let item = FileShelfItem(id: id, originalURL: original, managedURL: copy, addedAt: Date().addingTimeInterval(-10 * 86_400))
        let store = FileShelfToolStore(managedDirectory: managed, persistState: false,
            archive: .init(state: .init(items: [item], retention: .week)), onPortableChange: {})
        defer { store.shutdown() }
        try assertAllFolderRemovalPathsRefused(store, item: item)
        XCTAssertEqual(try Data(contentsOf: unexpected), bytes); XCTAssertEqual(try Data(contentsOf: copy), bytes)
        try FileManager.default.removeItem(at: unexpected); try FileManager.default.removeItem(at: copy)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false)
        let child = copy.appendingPathComponent("child-original.txt"); try bytes.write(to: child)
        try assertAllFolderRemovalPathsRefused(store, item: item)
        XCTAssertEqual(try Data(contentsOf: child), bytes); XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    @MainActor
    func testRetainedTrashReferenceBlocksUndoImmediatelyAndAfterRelaunch() async throws {
        let managed = fixtureDirectory.appendingPathComponent("ProtectedUndo", isDirectory: true), id = UUID()
        let folder = managed.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = fixtureDirectory.appendingPathComponent("original-undo.txt"), copy = folder.appendingPathComponent("copy.txt"), bytes = Data("Retained path now explicitly referenced".utf8)
        try bytes.write(to: original); try bytes.write(to: copy)
        let item = FileShelfItem(id: id, originalURL: original, managedURL: copy)
        let store = FileShelfToolStore(managedDirectory: managed, persistState: false,
            archive: .init(state: .init(items: [item], retention: .forever)), onPortableChange: {})
        defer { store.shutdown() }
        store.remove(item); XCTAssertNil(store.error); XCTAssertTrue(store.canUndoRemoval)
        let trash = managed.appendingPathComponent("ShelfTrash", isDirectory: true)
        let batch = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).first)
        let retained = batch.appendingPathComponent(id.uuidString).appendingPathComponent(copy.lastPathComponent)
        let undoBytes = try Data(contentsOf: batch.appendingPathComponent("undo.json"))
        store.add(retained, forceCopy: false)
        for _ in 0..<100 where store.items.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let reference = try XCTUnwrap(store.items.first); XCTAssertNil(reference.managedURL)
        XCTAssertEqual(reference.originalURL.resolvingSymlinksInPath(), retained.resolvingSymlinksInPath())
        store.undoRemoval(); XCTAssertNotNil(store.error); XCTAssertEqual(store.items.map(\.id), [reference.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path)); XCTAssertEqual(try Data(contentsOf: retained), bytes)
        XCTAssertEqual(try Data(contentsOf: batch.appendingPathComponent("undo.json")), undoBytes)
        let reopened = FileShelfToolStore(managedDirectory: managed, persistState: false,
            archive: .init(state: .init(items: [reference], retention: .forever)), onPortableChange: {})
        defer { reopened.shutdown() }
        XCTAssertFalse(reopened.canUndoRemoval); reopened.undoRemoval()
        XCTAssertEqual(reopened.items.map(\.id), [reference.id]); XCTAssertEqual(try Data(contentsOf: retained), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: batch.appendingPathComponent("undo.json")), undoBytes)
    }

    @MainActor private func assertAllFolderRemovalPathsRefused(_ store: FileShelfToolStore, item: FileShelfItem) throws {
        let ids = store.items.map(\.id)
        store.pruneExpired(); XCTAssertFalse(store.cleanupPreview?.itemIDs.contains(item.id) ?? true)
        let rule = CoreShelfRule(name: "Protected original expiry", kind: .expireOwnedCopies, days: 7)
        XCTAssertTrue(store.collections.saveRule(rule)); store.previewRule(rule)
        XCTAssertTrue(try XCTUnwrap(store.collections.preview).cleanupIDs.isEmpty)
        store.collections.enablePreviewedRule(rule.id); XCTAssertTrue(store.collections.isEnabled(rule.id))
        store.pruneExpired(); XCTAssertEqual(store.items.map(\.id), ids); XCTAssertFalse(store.expiryRequiresRetry)
        store.remove(item); XCTAssertNotNil(store.error); XCTAssertEqual(store.items.map(\.id), ids)
        store.confirmCleanup([item.id]); XCTAssertNotNil(store.error); XCTAssertEqual(store.items.map(\.id), ids)
        XCTAssertFalse(store.canUndoRemoval)
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
