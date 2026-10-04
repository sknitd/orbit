import AppKit
import CoreGraphics
import CoreText
import PDFKit
import SwiftUI
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class AssistantFileActionsEvaluationTests: NativeImageFixtureCase, @unchecked Sendable {
    func testActualMarkdownAndPDFReadersKeepOriginalsAndReadableText() throws {
        let text = fixtureDirectory.appendingPathComponent("notes.md")
        let bytes = Data("# Project\nBudget: 42\nMeeting on Friday.".utf8)
        try bytes.write(to: text)
        let document = try AssistantFileIO.read(text, action: .summarize)
        XCTAssertTrue(document.text.contains("Budget: 42")); XCTAssertEqual(try Data(contentsOf: text), bytes)
        let pdf = fixtureDirectory.appendingPathComponent("invoice.pdf")
        var rectangle = CGRect(x: 0, y: 0, width: 320, height: 200)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &rectangle, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 20, y: 100)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Invoice total 42", attributes: [
            .font: NSFont.systemFont(ofSize: 18)
        ]))
        CTLineDraw(line, context); context.endPDFPage(); context.closePDF()
        let originalPDF = try Data(contentsOf: pdf)
        let readable = try AssistantFileIO.read(pdf, action: .extractCSV)
        XCTAssertTrue(readable.text.contains("42")); XCTAssertEqual(try Data(contentsOf: pdf), originalPDF)
    }

    func testNamedCopiesThroughParentAliasNeverOverwriteAndUndoRetainsEditedOutput() throws {
        let real = fixtureDirectory.appendingPathComponent("Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let alias = fixtureDirectory.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let source = alias.appendingPathComponent("source.md")
        let original = Data("Actual meeting notes".utf8); try original.write(to: source)
        let existing = real.appendingPathComponent("Meeting notes.md")
        let reserved = Data("preexisting file".utf8); try reserved.write(to: existing)
        let document = try AssistantFileIO.read(source, action: .suggestFilename)
        let copies = try AssistantFileIO.createNamedCopies([.init(document: document, response: "Meeting notes"),
                                                          .init(document: document, response: "Meeting notes")])
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(copies[0].output.lastPathComponent, "Meeting notes (2).md")
        XCTAssertEqual(try Data(contentsOf: copies[0].output), original)
        try Data("User-edited named copy".utf8).write(to: copies[1].output)
        let retained = AssistantFileIO.undo(copies)
        XCTAssertEqual(retained.map(\.output), [copies[1].output])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copies[0].output.path))
        XCTAssertEqual(try Data(contentsOf: copies[1].output), Data("User-edited named copy".utf8))
        XCTAssertEqual(try Data(contentsOf: source), original); XCTAssertEqual(try Data(contentsOf: existing), reserved)
    }

    @MainActor
    func testActualScreenshotOCRBatchCreatesConfirmedNamedCopiesWithoutChangingImages() async throws {
        let image = NSImage(size: NSSize(width: 800, height: 260))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 800, height: 260).fill()
        NSAttributedString(string: "Project Alpha Invoice 42", attributes: [
            .font: NSFont.systemFont(ofSize: 38), .foregroundColor: NSColor.black
        ]).draw(at: NSPoint(x: 30, y: 120))
        image.unlockFocus()
        let raster = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let first = fixtureDirectory.appendingPathComponent("Screenshot1.png")
        let second = fixtureDirectory.appendingPathComponent("Screenshot2.png")
        try ScreenCaptureFiles.writePNG(raster, at: first); try ScreenCaptureFiles.writePNG(raster, at: second)
        let original = try Data(contentsOf: first)
        let store = AssistantFilesStore(generator: { document, action in
            XCTAssertEqual(action, .renameScreenshots)
            XCTAssertTrue(document.text.contains("Alpha")); XCTAssertTrue(document.text.contains("42"))
            return "Project Alpha Invoice"
        })
        store.selectAction(.renameScreenshots); store.setFiles([first, second]); store.generate()
        try await NativeFeatureEvaluation.waitUntil("Two real OCR naming previews", timeout: .seconds(10)) { store.proposals.count == 2 || store.error != nil }
        XCTAssertNil(store.error); XCTAssertEqual(store.proposals.count, 2)
        XCTAssertTrue(store.copies.isEmpty, "Preview alone must not write named copies")
        store.confirmNamedCopies()
        try await NativeFeatureEvaluation.waitUntil("Confirmed verified image copies") { store.copies.count == 2 || store.error != nil }
        XCTAssertNil(store.error); XCTAssertEqual(store.copies.count, 2)
        XCTAssertEqual(try Data(contentsOf: first), original); XCTAssertEqual(try Data(contentsOf: second), original)
        XCTAssertEqual(Set(store.copies.map(\.output)).count, 2)
        store.undoCopies()
        try await NativeFeatureEvaluation.waitUntil("Named image copies undone") { !store.isWorking }
        XCTAssertTrue(store.copies.isEmpty)
        XCTAssertEqual(try Data(contentsOf: first), original); XCTAssertEqual(try Data(contentsOf: second), original)
        store.shutdown()
    }

    @MainActor
    func testCancelledGeneratorCannotPublishLateFileProposals() async throws {
        let source = fixtureDirectory.appendingPathComponent("local.md")
        try Data("Local project budget 42".utf8).write(to: source)
        let fixture = AssistantGeneratorFixture()
        let store = AssistantFilesStore(generator: { _, _ in
            try await withCheckedThrowingContinuation { fixture.continuation = $0 }
        })
        store.setFiles([source]); store.generate()
        try await NativeFeatureEvaluation.waitUntil("Injected generator started") { fixture.continuation != nil }
        store.cancel()
        fixture.continuation?.resume(returning: "Late response"); fixture.continuation = nil
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(store.proposals.isEmpty); XCTAssertTrue(store.copies.isEmpty); XCTAssertFalse(store.isWorking)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "Local project budget 42")
        XCTAssertEqual(store.status, "File action stopped; originals retained.")
    }

    @MainActor
    func testRealFileCSVPreviewRendersWithoutLoadingTheOnDeviceModel() async throws {
        let source = fixtureDirectory.appendingPathComponent("table.md")
        try Data("Item: pencil\nQuantity: 2".utf8).write(to: source)
        let store = AssistantFilesStore(generator: { document, action in
            XCTAssertTrue(document.text.contains("pencil")); XCTAssertEqual(action, .extractCSV)
            return "Item,Quantity\npencil,2"
        })
        store.selectAction(.extractCSV); store.setFiles([source]); store.generate()
        try await NativeFeatureEvaluation.waitUntil("CSV proposal ready") { !store.proposals.isEmpty }
        XCTAssertEqual(store.proposals.first?.response, "Item,Quantity\npencil,2")
        try await NativeFeatureEvaluation.render(AnyView(AssistantFilesToolView(store: store)),
                                                named: "NotchOrbitPlus-AskOrbitFiles-fixture-preview.png")
        XCTAssertTrue(store.copies.isEmpty)
    }
}

@MainActor
private final class AssistantGeneratorFixture {
    var continuation: CheckedContinuation<String, Error>?
}
