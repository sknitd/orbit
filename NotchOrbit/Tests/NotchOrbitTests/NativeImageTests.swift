import Foundation
import ImageIO
import XCTest
import OrbitCore
import NotchCore
@testable import NotchOrbit

final class NativeImageTests: NativeImageFixtureCase, @unchecked Sendable {
    func testRealJPEGToWebPDecodesAndPreservesSource() async throws {
        let source = try rasterFile(named: "original.jpg", width: 96, height: 64)
        let original = try Data(contentsOf: source)
        let items = try FileInspector.inspect([source])
        XCTAssertEqual(items.first?.kind, .image)
        XCTAssertTrue(ActionResolver.actions(for: items).contains { $0.id == .webp })
        let result = try await ImageEngine().perform(.webp, items: items, context: .init())
        XCTAssertEqual(result.outputs.count, 1)
        let output = try XCTUnwrap(result.outputs.first)
        XCTAssertEqual(output.pathExtension, "webp")
        XCTAssertNotEqual(output.lastPathComponent, source.lastPathComponent)
        let bytes = try Data(contentsOf: output)
        XCTAssertEqual(String(data: bytes.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: bytes[8..<12], encoding: .ascii), "WEBP")
        let decoded = try ImageEngine.loadUpright(output)
        XCTAssertEqual(decoded.width, 96)
        XCTAssertEqual(decoded.height, 64)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(result.inputBytes, Int64(original.count))
        XCTAssertEqual(result.outputBytes, Int64(bytes.count))
    }

    func testFivePNGResizeOutputsActuallyDecodeAt1600AndRetainOriginals() async throws {
        let sources = try (0..<5).map { try rasterFile(named: "input-\($0).png", width: 2000, height: 1000) }
        let originals = try sources.map { try Data(contentsOf: $0) }
        let items = try FileInspector.inspect(sources)
        XCTAssertTrue(ActionResolver.actions(for: items).contains { $0.id == .resize1600 })
        let result = try await ImageEngine().perform(.resize1600, items: items, context: .init())
        XCTAssertEqual(result.outputs.count, 5)
        XCTAssertEqual(Set(result.outputs.map(\.lastPathComponent)).count, 5)
        for output in result.outputs {
            let decoded = try ImageEngine.loadUpright(output)
            XCTAssertEqual(decoded.width, 1600)
            XCTAssertEqual(decoded.height, 800)
        }
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, originals)
    }

    func testInvalidSecondImageRollsBackPublishedFirstOutput() async throws {
        let source = try rasterFile(named: "original.jpg", width: 96, height: 64)
        let original = try Data(contentsOf: source)
        let invalid = fixtureDirectory.appendingPathComponent("invalid.jpg")
        let invalidBytes = Data("this is not a raster image".utf8)
        try invalidBytes.write(to: invalid)
        let items = try FileInspector.inspect([source]) + [
            FileItem(url: invalid, kind: .image, byteCount: Int64(invalidBytes.count), typeIdentifier: "public.jpeg")
        ]
        do {
            _ = try await ImageEngine().perform(.webp, items: items, context: .init())
            XCTFail("An invalid batch input must fail without leaving unreported output")
        } catch {
            let names = try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path)
            XCTAssertEqual(Set(names), Set([source.lastPathComponent, invalid.lastPathComponent]))
            XCTAssertEqual(names.count, 2)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try Data(contentsOf: invalid), invalidBytes)
        }
    }
}
