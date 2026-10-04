import AppKit
import QuickLookUI
import XCTest
@testable import NotchOrbitPlus

final class ShelfQuickLookEvaluationTests: NativeImageFixtureCase, @unchecked Sendable {
    @MainActor
    func testRealQuickLookPanelOwnsTheSelectedItemAndRestoresItsResponderChain() throws {
        let source = fixtureDirectory.appendingPathComponent("preview.txt")
        let original = Data("A real local Quick Look preview fixture.\n".utf8)
        try original.write(to: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let previous = window.nextResponder
        let controller = ShelfQuickLookController()
        defer { controller.close(); window.close() }
        window.makeKeyAndOrderFront(nil)
        let id = UUID()
        try controller.show(url: source, itemID: id, ownerWindow: window)
        let panel = try XCTUnwrap(QLPreviewPanel.shared())
        XCTAssertTrue(panel.dataSource === controller)
        XCTAssertTrue(panel.delegate === controller)
        XCTAssertEqual(controller.previewURLs, [source])
        XCTAssertEqual(controller.currentItemID, id)
        XCTAssertEqual(controller.numberOfPreviewItems(in: panel), 1)
        let preview = try XCTUnwrap(controller.previewPanel(panel, previewItemAt: 0))
        let previewURL = try XCTUnwrap(preview as? NSURL) as URL
        XCTAssertEqual(previewURL.standardizedFileURL.resolvingSymlinksInPath(),
                       source.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertTrue(window.nextResponder === controller)
        controller.close(ifShowing: UUID())
        XCTAssertEqual(controller.currentItemID, id)
        controller.close(ifShowing: id)
        XCTAssertNil(controller.currentItemID)
        XCTAssertTrue(controller.previewURLs.isEmpty)
        XCTAssertEqual(controller.numberOfPreviewItems(in: panel), 0)
        XCTAssertTrue(window.nextResponder === previous)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
