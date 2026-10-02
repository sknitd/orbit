import Foundation
import ImageIO
import XCTest
import OrbitCore
@testable import OrbitDrop

final class ImageEngineTests: EngineTestCase, @unchecked Sendable {
    func testJPEGToPNGDecodesAndRetainsOriginal() async throws {
        let source = try image(metadata: true)
        let original = try Data(contentsOf: source)
        let result = try await ImageEngine().perform(.png, items: inspect([source]), context: .init())
        XCTAssertEqual(result.outputs.count, 1)
        let output = try XCTUnwrap(result.outputs.first)
        XCTAssertEqual(output.pathExtension, "png")
        let raster = try ImageEngine.loadUpright(output)
        XCTAssertEqual(raster.width, 96)
        XCTAssertEqual(raster.height, 64)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNotEqual(output, source)
    }

    func testWebPIsRealDecodableWebP() async throws {
        let source = try image()
        let original = try Data(contentsOf: source)
        let result = try await ImageEngine().perform(.webp, items: inspect([source]), context: .init())
        let output = try XCTUnwrap(result.outputs.first)
        let bytes = try Data(contentsOf: output)
        XCTAssertEqual(String(data: bytes.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: bytes[8..<12], encoding: .ascii), "WEBP")
        let raster = try ImageEngine.loadUpright(output)
        XCTAssertEqual(raster.width, 96)
        XCTAssertEqual(raster.height, 64)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testBatchResizeProducesFiveDistinct1600PixelOutputs() async throws {
        let sources = try (0..<5).map { try image(named: "image-\($0).png", width: 2000, height: 1000) }
        let originals = try sources.map { try Data(contentsOf: $0) }
        let result = try await ImageEngine().perform(.resize1600, items: inspect(sources), context: .init())
        XCTAssertEqual(result.outputs.count, 5)
        XCTAssertEqual(Set(result.outputs).count, 5)
        for output in result.outputs {
            let raster = try ImageEngine.loadUpright(output)
            XCTAssertEqual(raster.width, 1600)
            XCTAssertEqual(raster.height, 800)
        }
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, originals)
    }

    func testGPSRemovalPreservesNonLocationMetadata() async throws {
        let source = try image(metadata: true)
        let original = try Data(contentsOf: source)
        let before = try imageProperties(source)
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary as String])
        let result = try await ImageEngine().perform(.removeGPS, items: inspect([source]), context: .init())
        let after = try imageProperties(XCTUnwrap(result.outputs.first))
        XCTAssertNil(after[kCGImagePropertyGPSDictionary as String])
        let exif = try XCTUnwrap(after[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:01:02 03:04:05")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMetadataRemovalStripsPrivateTagsAndLeavesDecodablePixels() async throws {
        let source = try image(metadata: true)
        let result = try await ImageEngine().perform(.removeMetadata, items: inspect([source]), context: .init())
        let output = try XCTUnwrap(result.outputs.first)
        let tags = try imageProperties(output)
        XCTAssertNil(tags[kCGImagePropertyGPSDictionary as String])
        let exif = tags[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal as String])
        let tiff = tags[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFArtist as String])
        XCTAssertEqual(try ImageEngine.loadUpright(output).width, 96)
    }

    func testCompressionActuallyReducesBytes() async throws {
        let source = try image(width: 512, height: 256, quality: 1)
        let result = try await ImageEngine().perform(.compressImage, items: inspect([source]), context: .init(quality: 0.35))
        XCTAssertLessThan(result.outputBytes, result.inputBytes)
        XCTAssertEqual(try ImageEngine.loadUpright(XCTUnwrap(result.outputs.first)).width, 512)
    }

    func testFailedBatchRemovesEarlierOutputs() async throws {
        let source = try image()
        let invalid = directory.appendingPathComponent("invalid.jpg")
        try Data("not an image".utf8).write(to: invalid)
        let originals = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let batch = try inspect([source]) + [FileItem(url: invalid, kind: .image, byteCount: 12, typeIdentifier: "public.jpeg")]
        do {
            _ = try await ImageEngine().perform(.png, items: batch, context: .init())
            XCTFail("An invalid image must fail the batch")
        } catch {
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)), Set(originals))
        }
    }
}
