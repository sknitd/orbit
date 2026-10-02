import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import OrbitCore
@testable import OrbitDrop

class EngineTestCase: XCTestCase {
    var directory = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("OrbitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func inspect(_ urls: [URL]) throws -> [FileItem] { try FileInspector.inspect(urls) }

    /// Directory entries are names within this one fixture root. Comparing
    /// names avoids Foundation's /var and /private/var URL spelling aliases.
    func assertDirectoryContainsExactly(_ expectedNames: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let actualNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(actualNames), Set(expectedNames), file: file, line: line)
        XCTAssertEqual(actualNames.count, expectedNames.count, file: file, line: line)
    }

    func image(named name: String = "photo.jpg", width: Int = 96, height: Int = 64,
               metadata: Bool = false, quality: Double = 0.96) throws -> URL {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = UInt8((x * 37 + y * 19) % 256)
                pixels[index + 1] = UInt8((x * 11 + y * 47) % 256)
                pixels[index + 2] = UInt8((x * 53 + y * 7) % 256)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                         bitsPerPixel: 32, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false,
                                         intent: .defaultIntent))
        let url = directory.appendingPathComponent(name)
        let type = name.lowercased().hasSuffix(".png") ? UTType.png : UTType.jpeg
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: quality]
        if metadata {
            properties[kCGImagePropertyGPSDictionary as String] = [
                kCGImagePropertyGPSLatitude as String: 42.5,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 73.2,
                kCGImagePropertyGPSLongitudeRef as String: "W"
            ]
            properties[kCGImagePropertyExifDictionary as String] = [kCGImagePropertyExifDateTimeOriginal as String: "2026:01:02 03:04:05"]
            properties[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFArtist as String: "Orbit Test Fixture"]
        }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return url
    }

    func imageProperties(_ url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    func pdf(named name: String, pages: [CGSize]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: nil, nil))
        for (index, size) in pages.enumerated() {
            var box = CGRect(origin: .zero, size: size)
            let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: data] as CFDictionary)
            context.setFillColor(CGColor(gray: CGFloat(index + 1) / CGFloat(pages.count + 1), alpha: 1))
            context.fill(CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
