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
        let before = board.changeCount
        board.clearContents()
        XCTAssertNotEqual(board.changeCount, before, "Taking pasteboard ownership starts a fresh payload")
        XCTAssertEqual(NotchDragMonitor.fileURLs(from: board), [])
        XCTAssertTrue(board.writeObjects([source as NSURL]))
        // changeCount tracks ownership; writing as the current owner need not
        // increment it. Verify the representations and actual payload instead.
        XCTAssertEqual(board.availableType(from: [.fileURL]), .fileURL)
        let urls = NotchDragMonitor.fileURLs(from: board)
        XCTAssertEqual(urls.map(\.lastPathComponent), [source.lastPathComponent])
        XCTAssertTrue(NotchDragPayload.matches(observed: [source], dropped: urls))
        XCTAssertNotNil(DropPayloadValidator.matchingDroppedURLs(urls, expected: [source]))

        let frame = NotchRect(x: 0, y: 0, width: 1200, height: 800)
        let layout = NotchLayout(metrics: NotchScreenMetrics(
            frame: frame, visibleFrame: NotchRect(x: 0, y: 0, width: 1200, height: 776)))
        let zone = NotchActivationZone(screenID: 1, screenFrame: frame, layout: layout)
        let target = NotchPoint(x: layout.activationRegion.midX, y: layout.activationRegion.midY)
        var fresh = NotchActivationTracker()
        fresh.begin(pasteboardCount: before)
        guard case .activate = fresh.dragged(at: target, pasteboardCount: board.changeCount,
                                             hasFileURLs: !urls.isEmpty, zones: [zone]) else {
            return XCTFail("New ownership with actual file URLs must authorize presentation")
        }
        var stale = NotchActivationTracker()
        stale.begin(pasteboardCount: board.changeCount)
        XCTAssertEqual(stale.dragged(at: target, pasteboardCount: board.changeCount,
                                    hasFileURLs: !urls.isEmpty, zones: [zone]), .none)
        XCTAssertNil(stale.current)

        board.clearContents()
        XCTAssertTrue(board.setString("ordinary text", forType: .string))
        XCTAssertEqual(board.string(forType: .string), "ordinary text")
        XCTAssertEqual(board.availableType(from: [.string]), .string)
        XCTAssertNil(board.availableType(from: [.fileURL]))
        XCTAssertEqual(NotchDragMonitor.fileURLs(from: board), [])
        XCTAssertEqual(try Data(contentsOf: source), Data("actual file fixture".utf8))
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchDuplicates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let duplicate = root.appendingPathComponent("repeated.jpg")
        let bytes = Data("existing duplicate payload fixture".utf8)
        try bytes.write(to: duplicate)
        XCTAssertTrue(board.writeObjects([duplicate as NSURL, duplicate as NSURL]))
        let rawURLs = try XCTUnwrap(board.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [NSURL])
        XCTAssertEqual(rawURLs.count, 2, "The native reader must receive both accessible duplicate entries")
        XCTAssertEqual(rawURLs.map { ($0 as URL).lastPathComponent }, ["repeated.jpg", "repeated.jpg"])
        XCTAssertEqual(NotchDragMonitor.fileURLs(from: board), [])
        XCTAssertEqual(try Data(contentsOf: duplicate), bytes)
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
