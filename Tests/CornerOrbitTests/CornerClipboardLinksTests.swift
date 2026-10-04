import AppKit
import Foundation
import XCTest
import CornerCore
@testable import CornerOrbit

final class CornerClipboardLinksTests: XCTestCase {
    @MainActor
    func testClipboardConstructorAndPurePreviewDoNotReadOrWritePersonalClipboard() throws {
        let board = pasteboard(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("Private fixture sentinel", forType: .string))
        let before = board.changeCount, store = CornerClipboardStore(pasteboard: board)
        XCTAssertNil(store.snapshotString); XCTAssertTrue(store.input.isEmpty); XCTAssertEqual(board.changeCount, before)
        XCTAssertThrowsError(try store.preview()) { XCTAssertEqual($0 as? CornerClipboardError, .readFirst) }
        XCTAssertEqual(board.string(forType: .string), "Private fixture sentinel")
        let preview = CornerClipboardStore(preview: true, pasteboard: board, previewText: "{\"name\":\"Local fixture\",\"count\":2}")
        preview.mode = .jsonPretty; _ = try preview.preview(); _ = try preview.apply()
        XCTAssertTrue(preview.output.contains("\n")); XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(board.string(forType: .string), "Private fixture sentinel")
    }
    @MainActor
    func testActualTransformAndUndoRestoreMultipleRichItemTypesAndExactBytes() throws {
        let board = pasteboard(); defer { board.releaseGlobally() }
        let first = NSPasteboardItem(), second = NSPasteboardItem(), binaryType = NSPasteboard.PasteboardType("com.cornerorbit.fixture.binary")
        XCTAssertTrue(first.setString("Café", forType: .string))
        XCTAssertTrue(first.setData(Data("<p>Café</p>".utf8), forType: .html))
        XCTAssertTrue(first.setData(Data([0, 1, 255, 0]), forType: binaryType))
        XCTAssertTrue(second.setData(Data("{\\rtf1 Second item}".utf8), forType: .rtf))
        XCTAssertTrue(second.setString("Second item", forType: .string)); XCTAssertTrue(board.writeObjects([first, second]))
        let original = try snapshot(board), store = CornerClipboardStore(pasteboard: board)
        _ = try store.perform(kind: .clipboardBase64Encode)
        XCTAssertEqual(board.string(forType: .string), Data("Café".utf8).base64EncodedString())
        XCTAssertEqual(board.pasteboardItems?.count, 1); XCTAssertTrue(store.canUndo)
        _ = try store.undo(); XCTAssertEqual(try snapshot(board), original); XCTAssertFalse(store.canUndo)
    }
    @MainActor
    func testUndoRefusesSameOwnerPayloadRewriteEvenWhenChangeCountIsUnchanged() throws {
        let board = pasteboard(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("Original text", forType: .string))
        let store = CornerClipboardStore(pasteboard: board); _ = try store.perform(kind: .clipboardUppercase)
        let ownCount = board.changeCount
        XCTAssertTrue(board.setString("New same-owner payload", forType: .string))
        XCTAssertEqual(board.changeCount, ownCount, "This fixture reaches the same ownership-count data mutation")
        XCTAssertThrowsError(try store.undo()) { XCTAssertEqual($0 as? CornerClipboardError, .clipboardChanged) }
        XCTAssertEqual(board.string(forType: .string), "New same-owner payload"); XCTAssertEqual(board.changeCount, ownCount)
        XCTAssertFalse(store.canUndo)
    }
    @MainActor
    func testApplyRefusesSourcePayloadRewriteWithUnchangedOwnershipCount() throws {
        let board = pasteboard(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("Read this original", forType: .string))
        let store = CornerClipboardStore(pasteboard: board); try store.read(); store.mode = .lowercase; _ = try store.preview()
        let count = board.changeCount
        XCTAssertTrue(board.setString("NEW unrelated payload", forType: .string)); XCTAssertEqual(board.changeCount, count)
        XCTAssertThrowsError(try store.apply()) { XCTAssertEqual($0 as? CornerClipboardError, .clipboardChanged) }
        XCTAssertEqual(board.string(forType: .string), "NEW unrelated payload"); XCTAssertEqual(board.changeCount, count)
    }
    @MainActor
    func testUndoRefusesAnotherOwnerAndKeepsItsNewRichContents() throws {
        let board = pasteboard(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("Original", forType: .string))
        let store = CornerClipboardStore(pasteboard: board); _ = try store.perform(kind: .clipboardUppercase)
        let ownCount = board.changeCount
        board.clearContents(); let newer = NSPasteboardItem(); XCTAssertTrue(newer.setString("Other app's newer content", forType: .string)); XCTAssertTrue(newer.setData(Data("<b>New</b>".utf8), forType: .html)); XCTAssertTrue(board.writeObjects([newer]))
        let before = try snapshot(board); XCTAssertNotEqual(board.changeCount, ownCount)
        XCTAssertThrowsError(try store.undo()) { XCTAssertEqual($0 as? CornerClipboardError, .clipboardChanged) }
        XCTAssertEqual(try snapshot(board), before)
    }
    @MainActor
    func testOversizedOriginalRichDataIsRefusedBeforeClipboardReplacement() throws {
        let board = pasteboard(); defer { board.releaseGlobally() }
        let item = NSPasteboardItem(), largeType = NSPasteboard.PasteboardType("com.cornerorbit.fixture.large")
        XCTAssertTrue(item.setString("small text", forType: .string)); XCTAssertTrue(item.setData(Data(repeating: 0xa5, count: 2_097_153), forType: largeType)); XCTAssertTrue(board.writeObjects([item]))
        let before = try snapshot(board), count = board.changeCount, store = CornerClipboardStore(pasteboard: board)
        XCTAssertThrowsError(try store.perform(kind: .clipboardUppercase)) { XCTAssertEqual($0 as? CornerClipboardError, .backupTooLarge) }
        XCTAssertEqual(board.changeCount, count); XCTAssertEqual(try snapshot(board), before); XCTAssertFalse(store.canUndo)
    }
    @MainActor
    func testInvalidBase64AndMissingTextFailBeforeAnyClipboardWrite() throws {
        let board = pasteboard(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("not canonical Base64", forType: .string))
        let store = CornerClipboardStore(pasteboard: board), original = try snapshot(board), count = board.changeCount
        XCTAssertThrowsError(try store.perform(kind: .clipboardBase64Decode)); XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(board.changeCount, count); XCTAssertEqual(try snapshot(board), original)
        board.clearContents(); XCTAssertTrue(board.setData(Data([1, 2, 3]), forType: .png))
        XCTAssertThrowsError(try store.read()) { XCTAssertEqual($0 as? CornerClipboardError, .noText) }
    }
    @MainActor
    func testLinksActuallyPersistReorderAndResolveGroupWithoutOpeningWebsites() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CornerLinkStore(directory: root)
        let first = CornerFavorite(title: "Café reference", url: try XCTUnwrap(URL(string: "https://example.com/?q=keep")))
        let second = CornerFavorite(title: "Notes", url: try XCTUnwrap(URL(string: "https://example.org/notes")))
        try store.saveFavorite(first); try store.saveFavorite(second); try store.moveFavorite(second.id, by: -1)
        let group = CornerLinkGroup(name: "Daily", urls: [first.url, second.url]); try store.saveGroup(group)
        XCTAssertEqual(try store.urls(forGroup: group.id.uuidString), group.urls)
        let reopened = CornerLinkStore(directory: root)
        XCTAssertEqual(reopened.favorites, [second, first]); XCTAssertEqual(reopened.groups, [group]); XCTAssertEqual(reopened.searchFavorites("CAFE example"), [first])
        let file = root.appendingPathComponent("links-v1.json"), bytes = try Data(contentsOf: file)
        XCTAssertEqual(try CornerLinkLibrary.decode(bytes).favorites, [second, first])
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        try reopened.removeFavorite(second.id); try reopened.removeGroup(group.id)
        XCTAssertEqual(CornerLinkStore(directory: root).favorites, [first]); XCTAssertTrue(CornerLinkStore(directory: root).groups.isEmpty)
    }
    @MainActor
    func testCorruptLinkOriginalIsRetainedUntilExplicitBackupAndReset() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("links-v1.json"), bad = Data("{invalid-original".utf8); try bad.write(to: file)
        let store = CornerLinkStore(directory: root); XCTAssertTrue(store.needsRecovery)
        XCTAssertThrowsError(try store.saveFavorite(.init(title: "Cannot replace", url: try XCTUnwrap(URL(string: "https://example.com")))))
        XCTAssertEqual(try Data(contentsOf: file), bad)
        try store.resetPreservingOriginal(); XCTAssertFalse(store.needsRecovery)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix("links-v1.backup.") }))
        XCTAssertEqual(try Data(contentsOf: backup), bad); XCTAssertEqual(try CornerLinkLibrary.decode(Data(contentsOf: file)), .init())
    }
    @MainActor
    func testExternallyChangedLinkBytesAreNeverBlindlyOverwritten() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CornerLinkStore(directory: root), favorite = CornerFavorite(title: "External edit", url: try XCTUnwrap(URL(string: "https://example.org/changed")))
        let file = root.appendingPathComponent("links-v1.json"), changed = try CornerLinkLibrary(favorites: [favorite]).encoded(); try changed.write(to: file)
        XCTAssertThrowsError(try store.saveGroup(.init(name: "New group", urls: [favorite.url])))
        XCTAssertEqual(try Data(contentsOf: file), changed); XCTAssertTrue(store.groups.isEmpty)
        try store.reload(); XCTAssertEqual(store.favorites, [favorite]); try store.saveGroup(.init(name: "After explicit reload", urls: [favorite.url]))
        XCTAssertEqual(CornerLinkStore(directory: root).groups.count, 1)
    }
    @MainActor
    func testSymlinkLibraryAndInvalidModelsRetainTargetAndSavedBytes() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("original.json"), bytes = try CornerLinkLibrary().encoded(); try bytes.write(to: target)
        let file = root.appendingPathComponent("links-v1.json"); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let linked = CornerLinkStore(directory: root); XCTAssertTrue(linked.needsRecovery)
        XCTAssertThrowsError(try linked.resetPreservingOriginal()); XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), target.path)
        try FileManager.default.removeItem(at: file)
        let good = CornerLinkStore(directory: root); try good.saveFavorite(.init(title: "Keep", url: try XCTUnwrap(URL(string: "https://example.com"))))
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try good.saveFavorite(.init(title: "Credentials", url: try XCTUnwrap(URL(string: "https://user:secret@example.com")))))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    @MainActor
    func testRealLinkIOFailureRetainsPriorBytesMemoryAndLeavesNoPartialStage() throws {
        let root = try fixture(); defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        let store = CornerLinkStore(directory: root), favorite = CornerFavorite(title: "Keep original", url: try XCTUnwrap(URL(string: "https://example.com")))
        try store.saveFavorite(favorite)
        let file = root.appendingPathComponent("links-v1.json"), before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertThrowsError(try store.saveGroup(.init(name: "Cannot publish", urls: [favorite.url])))
        XCTAssertEqual(try Data(contentsOf: file), before); XCTAssertEqual(store.favorites, [favorite]); XCTAssertTrue(store.groups.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".links-stage-") }))
    }
    @MainActor
    func testPreviewLinkStoreBypassesExistingCorruptFileAndNeverPersistsChanges() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("links-v1.json"), bad = Data("bad-original".utf8); try bad.write(to: file)
        let favorite = CornerFavorite(title: "Synthetic", url: try XCTUnwrap(URL(string: "https://example.com")))
        let preview = CornerLinkStore(directory: root, preview: true, previewFavorites: [favorite])
        XCTAssertFalse(preview.needsRecovery); XCTAssertEqual(preview.favorites, [favorite])
        try preview.saveGroup(.init(name: "Synthetic group", urls: [favorite.url]))
        XCTAssertEqual(try Data(contentsOf: file), bad)
    }
    @MainActor private func pasteboard() -> NSPasteboard { NSPasteboard(name: .init("CornerClipboardFixture.\(UUID().uuidString)")) }
    @MainActor private func snapshot(_ board: NSPasteboard) throws -> [[String: Data]] {
        try (board.pasteboardItems ?? []).map { item in try Dictionary(uniqueKeysWithValues: item.types.map { ($0.rawValue, try XCTUnwrap(item.data(forType: $0))) }) }
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CornerLinksFixture.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return root
    }
}
