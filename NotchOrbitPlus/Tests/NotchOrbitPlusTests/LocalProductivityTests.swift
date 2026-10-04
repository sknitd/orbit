import AppKit
import Foundation
import XCTest
@testable import NotchOrbitPlus

final class LocalProductivityTests: NativeImageFixtureCase {
    @MainActor
    func testClipboardRequiresOptInAndStopsCapturingAfterOptOut() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardToolStore(pasteboard: board, persistHistory: false)
        defer { store.setObserving(false) }
        board.clearContents()
        XCTAssertTrue(board.setString("before opt-in", forType: .string))
        store.captureIfChanged()
        XCTAssertFalse(store.observing)
        XCTAssertTrue(store.clips.isEmpty)

        store.setObserving(true)
        store.captureIfChanged()
        XCTAssertTrue(store.clips.isEmpty, "Opt-in must not collect pre-existing clipboard contents")
        board.clearContents()
        XCTAssertTrue(board.setString("after opt-in", forType: .string))
        store.captureIfChanged()
        XCTAssertEqual(store.clips.map(\.text), ["after opt-in"])

        store.setObserving(false)
        board.clearContents()
        XCTAssertTrue(board.setString("after opt-out", forType: .string))
        store.captureIfChanged()
        XCTAssertEqual(store.clips.map(\.text), ["after opt-in"])
    }

    @MainActor
    func testConcealedTransientAndPasswordManagerMarkersAreSkippedBeforeCapture() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardToolStore(pasteboard: board, persistHistory: false)
        defer { store.setObserving(false) }
        store.setObserving(true)
        for name in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            let marker = NSPasteboard.PasteboardType(name)
            board.declareTypes([.string, marker], owner: nil)
            XCTAssertTrue(board.setString("private test fixture", forType: .string))
            XCTAssertTrue(board.setData(Data(), forType: marker))
            store.captureIfChanged()
            XCTAssertTrue(store.clips.isEmpty, "\(name) must never enter history")
            XCTAssertTrue(store.status.hasPrefix("Skipped private"))
        }
        board.declareTypes([.string, .init("org.nspasteboard.source")], owner: nil)
        XCTAssertTrue(board.setString("private source fixture", forType: .string))
        XCTAssertTrue(board.setString("com.1password.1password", forType: .init("org.nspasteboard.source")))
        store.captureIfChanged()
        XCTAssertTrue(store.clips.isEmpty)
    }

    @MainActor
    func testClipboardImageAndURLRecopyPreserveRealData() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardToolStore(pasteboard: board, persistHistory: false)
        defer { store.setObserving(false) }
        store.setObserving(true)
        let imageURL = try rasterFile(named: "clipboard.png", width: 24, height: 16)
        let imageData = try Data(contentsOf: imageURL)
        board.clearContents()
        XCTAssertTrue(board.setData(imageData, forType: .png))
        store.captureIfChanged()
        let image = try XCTUnwrap(store.clips.first)
        XCTAssertEqual(image.kind, .image)
        store.copy(image)
        XCTAssertEqual(board.data(forType: .png), imageData)

        board.clearContents()
        XCTAssertTrue(board.setString("https://example.com/local-fixture", forType: .URL))
        store.captureIfChanged()
        let link = try XCTUnwrap(store.clips.first)
        XCTAssertEqual(link.kind, .link)
        store.copy(link)
        XCTAssertEqual(board.string(forType: .string), "https://example.com/local-fixture")
    }

    @MainActor
    func testSharedStoresSurviveToolViewLifetimeAndLaunchDoesNotOptIn() {
        ClipboardToolStore.shutdownIfInitialized()
        LocalProductivityLifecycle.start()
        let firstClipboard = ClipboardToolStore.shared
        let firstShelf = FileShelfToolStore.shared
        XCTAssertTrue(firstClipboard === ClipboardToolStore.shared)
        XCTAssertTrue(firstShelf === FileShelfToolStore.shared)
        XCTAssertFalse(firstClipboard.observing)
        LocalProductivityLifecycle.shutdown()
        XCTAssertFalse(firstClipboard.observing)
    }

    @MainActor
    func testRemovingManagedShelfCopyPreservesOriginalBytes() async throws {
        let source = fixtureDirectory.appendingPathComponent("original.txt")
        let original = Data("original bytes remain intact".utf8)
        try original.write(to: source)
        let store = FileShelfToolStore(managedDirectory: fixtureDirectory.appendingPathComponent("managed"), persistState: false)
        defer { store.shutdown() }
        store.autoSave = true
        store.add(source)
        for _ in 0..<100 where store.items.isEmpty && store.error == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        let item = try XCTUnwrap(store.items.first, store.error ?? "Copy did not finish")
        let managed = try XCTUnwrap(item.managedURL)
        XCTAssertNotEqual(managed.standardizedFileURL, source.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: managed), original)
        store.remove(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.error)
    }

    @MainActor
    func testRemovingShelfReferenceNeverDeletesSource() async throws {
        let source = fixtureDirectory.appendingPathComponent("reference.txt")
        let original = Data("referenced original".utf8)
        try original.write(to: source)
        let store = FileShelfToolStore(managedDirectory: fixtureDirectory.appendingPathComponent("references"), persistState: false)
        defer { store.shutdown() }
        store.add(source)
        for _ in 0..<100 where store.items.isEmpty && store.error == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        let item = try XCTUnwrap(store.items.first, store.error ?? "Reference did not finish")
        XCTAssertNil(item.managedURL)
        store.remove(item)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.error)
    }
}
