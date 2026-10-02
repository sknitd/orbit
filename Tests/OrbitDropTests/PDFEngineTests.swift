import Foundation
import PDFKit
import XCTest
import OrbitCore
@testable import OrbitDrop

final class PDFEngineTests: EngineTestCase, @unchecked Sendable {
    func testMergePreservesPageOrderAndSources() async throws {
        let first = try pdf(named: "first.pdf", pages: [CGSize(width: 150, height: 200)])
        let second = try pdf(named: "second.pdf", pages: [CGSize(width: 250, height: 300), CGSize(width: 350, height: 400)])
        let originals = try [first, second].map { try Data(contentsOf: $0) }
        let result = try await PDFEngine().perform(.mergePDF, items: inspect([first, second]), context: .init())
        let document = try XCTUnwrap(PDFDocument(url: XCTUnwrap(result.outputs.first)))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).width, 150)
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).width, 250)
        XCTAssertEqual(document.page(at: 2)?.bounds(for: .mediaBox).width, 350)
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: $0) }, originals)
    }

    func testSplitProducesValidSinglePagePDFs() async throws {
        let source = try pdf(named: "source.pdf", pages: [CGSize(width: 150, height: 200), CGSize(width: 250, height: 300)])
        let result = try await PDFEngine().perform(.splitPDF, items: inspect([source]), context: .init())
        XCTAssertEqual(result.outputs.count, 2)
        for output in result.outputs {
            XCTAssertEqual(try XCTUnwrap(PDFDocument(url: output)).pageCount, 1)
        }
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: source)).pageCount, 2)
    }

    func testPDFPagesBecomeDecodablePNGs() async throws {
        let source = try pdf(named: "source.pdf", pages: [CGSize(width: 150, height: 200), CGSize(width: 250, height: 300)])
        let result = try await PDFEngine().perform(.pdfToPNG, items: inspect([source]), context: .init())
        XCTAssertEqual(result.outputs.count, 2)
        for output in result.outputs {
            XCTAssertEqual(output.pathExtension, "png")
            let raster = try ImageEngine.loadUpright(output)
            XCTAssertGreaterThan(raster.width, 0)
            XCTAssertGreaterThan(raster.height, 0)
        }
    }

    func testImagesBecomeOnePDFInSelectionOrder() async throws {
        let first = try image(named: "one.png", width: 100, height: 60)
        let second = try image(named: "two.jpg", width: 200, height: 90)
        let result = try await PDFEngine().perform(.imagesToPDF, items: inspect([first, second]), context: .init())
        let document = try XCTUnwrap(PDFDocument(url: XCTUnwrap(result.outputs.first)))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertLessThan(try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox).width,
                          try XCTUnwrap(document.page(at: 1)).bounds(for: .mediaBox).width)
    }
}
