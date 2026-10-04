import AppKit
import SwiftUI
import XCTest
@testable import NotchOrbitPlus

final class TranslationEvaluationTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testTypedClipboardOutputAndCancelledSessionIdentityWithoutPreparingModels() throws {
        let store = TranslationToolStore()
        let board = NSPasteboard(name: .init("OrbitTranslation-\(UUID())"))
        defer { board.releaseGlobally(); store.shutdown() }
        board.setString("Hello world", forType: .string); store.paste(board)
        XCTAssertEqual(store.input, "Hello world")
        XCTAssertFalse(store.isWorking); XCTAssertNil(store.request)
        store.begin(); let old = try XCTUnwrap(store.request)
        store.cancel(); store.complete(old.id, text: "Late response")
        XCTAssertTrue(store.output.isEmpty)
        store.begin(); let current = try XCTUnwrap(store.request)
        XCTAssertNotEqual(old.id, current.id)
        store.complete(current.id, text: "Hola mundo"); store.copy(board)
        XCTAssertEqual(board.string(forType: .string), "Hola mundo")
        XCTAssertFalse(store.isWorking)
    }
    @MainActor
    func testLocalTranslationControlsRenderWithoutAnActiveSessionOrDownload() async throws {
        let store = TranslationToolStore()
        store.input = "Type text or explicitly paste it here."
        try await NativeFeatureEvaluation.render(AnyView(TranslationToolView(store: store)),
                                                named: "NotchOrbitPlus-Translate-fixture-unstarted.png")
        XCTAssertNil(store.request); XCTAssertFalse(store.isWorking); XCTAssertTrue(store.output.isEmpty)
    }
}
