import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import OrbitCore
@testable import NotchOrbit

class NativeImageFixtureCase: XCTestCase {
    var fixtureDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        fixtureDirectory = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("NotchOrbitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fixtureDirectory)
    }

    func rasterFile(named name: String, width: Int, height: Int) throws -> URL {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 37 + y * 19) % 256)
                pixels[offset + 1] = UInt8((x * 11 + y * 47) % 256)
                pixels[offset + 2] = UInt8((x * 53 + y * 7) % 256)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = fixtureDirectory.appendingPathComponent(name)
        let type = name.hasSuffix(".png") ? UTType.png : UTType.jpeg
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
