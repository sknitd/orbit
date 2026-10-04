import AppKit
import XCTest
@testable import NotchOrbitPlus

@MainActor
final class ClipboardOCREvaluationTests: XCTestCase {
    func testCapturedImageRecognizesRealTextThatCanBeSearchedAndCopied() async throws {
        let board = NSPasteboard(name: .init("NotchOrbitPlus.OCR.\(UUID().uuidString)"))
        let store = ClipboardToolStore(pasteboard: board, persistHistory: false)
        defer { store.shutdown(); board.releaseGlobally() }
        let image = try textImage()
        let clip = try capture(image, on: board, store: store)
        XCTAssertNil(clip.recognizedText)
        XCTAssertFalse(clip.matchesSearch("8472"))
        store.recognizeText(in: clip)
        try await waitForRecognition(store)
        let recognized = try XCTUnwrap(store.clips.first { $0.id == clip.id })
        let text = try XCTUnwrap(recognized.recognizedText)
        XCTAssertTrue(text.uppercased().contains("ORBIT"), text)
        XCTAssertTrue(text.uppercased().contains("CLIPBOARD"), text)
        XCTAssertTrue(text.contains("8472"), text)
        XCTAssertNotNil(recognized.recognizedAt)
        XCTAssertTrue(recognized.matchesSearch("8472"))
        XCTAssertEqual(recognized.image, image)
        store.copyRecognizedText(recognized)
        XCTAssertEqual(board.string(forType: .string), text)
        XCTAssertEqual(store.clips.first?.image, image)
        XCTAssertEqual(store.clips.count, 1)
        XCTAssertNil(store.error)
    }

    func testInvalidAndOversizedImagesFailWithoutInventedText() async {
        for (data, expected) in [(Data("not an image".utf8), ClipboardImageOCR.Failure.invalidImage),
                                 (Data(repeating: 0, count: ClipboardImageOCR.maximumDataBytes + 1), .imageTooLarge)] {
            do {
                _ = try await ClipboardImageOCR.recognize(data)
                XCTFail("Invalid clipboard data must not produce recognized text")
            } catch let failure as ClipboardImageOCR.Failure {
                XCTAssertEqual(failure, expected)
            } catch { XCTFail("Unexpected image validation failure: \(error.localizedDescription)") }
        }
    }

    func testClearingAnImageWithPendingRecognitionCannotRestoreHistory() async throws {
        let board = NSPasteboard(name: .init("NotchOrbitPlus.OCR.Clear.\(UUID().uuidString)"))
        let store = ClipboardToolStore(pasteboard: board, persistHistory: false)
        defer { store.shutdown(); board.releaseGlobally() }
        let image = try textImage()
        let clip = try capture(image, on: board, store: store)
        store.recognizeText(in: clip)
        XCTAssertTrue(store.ocrRunning.contains(clip.id))
        store.clear()
        try await waitForRecognition(store)
        XCTAssertTrue(store.clips.isEmpty)
        XCTAssertTrue(store.ocrRunning.isEmpty)
        XCTAssertEqual(board.data(forType: .png), image)
        XCTAssertNil(store.error)
    }

    func testCancelledRecognitionOfAValidImageThrowsCancellation() async throws {
        let image = try textImage()
        let worker = Task { try await ClipboardImageOCR.recognize(image) }
        worker.cancel()
        do {
            _ = try await worker.value
            XCTFail("A cancelled recognition task must not return text")
        } catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error.localizedDescription)") }
    }

    private func capture(_ image: Data, on board: NSPasteboard, store: ClipboardToolStore) throws -> LocalClip {
        store.setObserving(true)
        board.clearContents()
        XCTAssertTrue(board.setData(image, forType: .png))
        store.captureIfChanged()
        store.setObserving(false)
        XCTAssertEqual(store.clips.count, 1)
        let clip = try XCTUnwrap(store.clips.first)
        XCTAssertEqual(clip.kind, .image)
        XCTAssertEqual(clip.image, image)
        return clip
    }

    private func waitForRecognition(_ store: ClipboardToolStore) async throws {
        for _ in 0..<600 {
            if store.ocrRunning.isEmpty { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Recognition did not finish within 15 seconds: \(store.error ?? store.status)")
    }

    private func textImage() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 220,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 220).fill()
        NSAttributedString(string: "ORBIT CLIPBOARD 8472", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black
        ]).draw(at: NSPoint(x: 40, y: 80))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertLessThan(data.count, ClipboardImageOCR.maximumDataBytes)
        return data
    }
}
