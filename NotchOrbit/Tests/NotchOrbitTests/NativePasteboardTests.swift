import AppKit
import Foundation
import XCTest
import OrbitCore
import NotchCore
@testable import NotchOrbit

final class NativePasteboardTests: XCTestCase {
    @MainActor
    func testRealFileURLPasteboardUsesCurrentContentAndStopsAcceptingAfterRewrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchPasteboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("actual file fixture".utf8).write(to: source)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        let before = board.changeCount
        XCTAssertTrue(board.writeObjects([source as NSURL]))
        XCTAssertNotEqual(board.changeCount, before)
        let urls = NotchDragMonitor.fileURLs(from: board)
        XCTAssertEqual(urls.map(\.lastPathComponent), [source.lastPathComponent])
        XCTAssertTrue(NotchDragPayload.matches(observed: [source], dropped: urls))
        XCTAssertNotNil(DropPayloadValidator.matchingDroppedURLs(urls, expected: [source]))
        board.clearContents()
        XCTAssertTrue(board.setString("ordinary text", forType: .string))
        XCTAssertEqual(NotchDragMonitor.fileURLs(from: board), [])
    }

    @MainActor
    func testNonFileAndDuplicatePasteboardURLPayloadsCannotBecomeCandidates() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        let remote = try XCTUnwrap(URL(string: "https://example.com/photo.jpg"))
        XCTAssertTrue(board.writeObjects([remote as NSURL]))
        XCTAssertEqual(NotchDragMonitor.fileURLs(from: board), [])
        board.clearContents()
        let duplicate = URL(fileURLWithPath: "/fixtures/repeated.jpg")
        XCTAssertTrue(board.writeObjects([duplicate as NSURL, duplicate as NSURL]))
        XCTAssertEqual(NotchDragMonitor.fileURLs(from: board), [])
    }

    @MainActor
    func testEmptyPasteboardAndStoppedMonitorDoNotAuthorizeActivation() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertEqual(NotchDragMonitor.fileURLs(from: board), [])
        let monitor = NotchDragMonitor(onActivate: { _, _ in XCTFail("A stopped observer cannot activate") }, onCancel: {})
        XCTAssertEqual(monitor.status, .stopped)
        XCTAssertNil(monitor.activationGeneration)
        XCTAssertFalse(monitor.isCurrentActivation(1))
        monitor.stop()
        XCTAssertEqual(monitor.status, .stopped)
    }
}
