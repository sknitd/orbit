import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class QRToolEvaluationTests: NativeImageFixtureCase, @unchecked Sendable {
    func testRealCoreImagePNGDecodesWithVisionForEveryCorrectionLevelAndKeepsOriginal() async throws {
        for correction in QRCorrectionLevel.allCases {
            let directory = try ownedDirectory(correction.rawValue)
            let payload = "Orbit QR \(correction.rawValue) · https://example.com/orbit?value=8472"
            let generated = try QRImageCodec.generate(.init(payload: payload, options: .init(correction: correction)), in: directory)
            let original = try Data(contentsOf: generated.url)
            let result = try await QRImageCodec.scanPNG(generated.url)
            XCTAssertEqual(result.payloads, [payload])
            XCTAssertEqual(result.unreadableCount, 0)
            XCTAssertEqual(try Data(contentsOf: generated.url), original)
            XCTAssertEqual(generated.width, generated.height)
            XCTAssertEqual(generated.width % 8, 0)
            let permissions = try FileManager.default.attributesOfItem(atPath: generated.url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
    }

    func testVisionSurfacesEveryActualCodeIncludingRepeatedPayloads() async throws {
        let first = try QRImageCodec.generate(.init(payload: "ORBIT-FIRST"), in: ownedDirectory("first"))
        let second = try QRImageCodec.generate(.init(payload: "https://example.com/second"), in: ownedDirectory("second"))
        let canvas = try combinedPNG([first.url, second.url, first.url])
        let original = try Data(contentsOf: canvas)
        let result = try await QRImageCodec.scanPNG(canvas)
        XCTAssertEqual(result.payloads.count, 3)
        XCTAssertEqual(result.payloads.filter { $0 == "ORBIT-FIRST" }.count, 2)
        XCTAssertEqual(result.payloads.filter { $0 == "https://example.com/second" }.count, 1)
        XCTAssertEqual(result.unreadableCount, 0)
        XCTAssertEqual(try Data(contentsOf: canvas), original)
    }

    func testInvalidUnencodedAndCancelledImagesNeverInventPayloadsOrAlterSources() async throws {
        let invalid = fixtureDirectory.appendingPathComponent("invalid.png")
        let original = Data("not a PNG or QR code".utf8); try original.write(to: invalid)
        do { _ = try await QRImageCodec.scanPNG(invalid); XCTFail("Invalid PNG should fail") }
        catch { XCTAssertEqual(error as? QRImageFailure, .invalidPNG) }
        XCTAssertEqual(try Data(contentsOf: invalid), original)
        let unencoded = try rasterFile(named: "unencoded.png", width: 200, height: 200)
        let unencodedResult = try await QRImageCodec.scanPNG(unencoded)
        XCTAssertTrue(unencodedResult.payloads.isEmpty)
        let actual = try QRImageCodec.generate(.init(payload: "cancelled"), in: ownedDirectory("cancelled"))
        let actualBytes = try Data(contentsOf: actual.url)
        let task = Task { try await QRImageCodec.scanPNG(actual.url) }; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled scan should not publish payloads") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected cancellation failure: \(error.localizedDescription)") }
        XCTAssertEqual(try Data(contentsOf: actual.url), actualBytes)
    }

    @MainActor
    func testInitializationRenderingAndImmediateHideNeverCaptureTheScreen() async throws {
        var captures = 0
        let store = QRToolStore(captureArea: { captures += 1; throw CancellationError() },
                                exportRoot: fixtureDirectory.appendingPathComponent("exports"))
        XCTAssertEqual(captures, 0); XCTAssertNil(store.generatedPNG)
        store.start(); XCTAssertEqual(captures, 0)
        try await NativeFeatureEvaluation.render(AnyView(QRToolView(store: store)), named: "NotchOrbitPlus-QR-fixture-unstarted.png")
        XCTAssertEqual(captures, 0)
        store.scanScreenRegion(); store.shutdown()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(captures, 0)
        XCTAssertFalse(store.isWorking); XCTAssertTrue(store.decodedPayloads.isEmpty)
        store.payload = "Cancelled before encoding"; store.generate(); store.shutdown()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(store.generatedPNG)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureDirectory.appendingPathComponent("exports").path))
    }

    @MainActor
    func testExplicitSelectedCaptureScansRealManagedPNGAndCopiesExactPayload() async throws {
        let payload = "https://example.com/?a=1&b=2"
        let image = try QRImageCodec.generate(.init(payload: payload), in: ownedDirectory("managed"))
        let original = try Data(contentsOf: image.url)
        var captures = 0
        let store = QRToolStore(captureArea: {
            captures += 1
            return FileShelfItem(originalURL: image.url, managedURL: image.url)
        })
        let board = NSPasteboard(name: .init("NotchOrbitPlus.QR.\(UUID().uuidString)"))
        defer { store.shutdown(); board.releaseGlobally() }
        store.scanScreenRegion()
        try await NativeFeatureEvaluation.waitUntil("Selected-region scan finished", timeout: .seconds(10)) { !store.isWorking }
        XCTAssertEqual(captures, 1); XCTAssertEqual(store.decodedPayloads, [payload]); XCTAssertNil(store.error)
        store.copyPayload(at: 0, to: board)
        XCTAssertEqual(board.string(forType: .string), payload)
        XCTAssertEqual(try Data(contentsOf: image.url), original)
    }

    @MainActor
    func testGeneratedPreviewRendersAndCancelledLateCaptureCannotReplaceNewerResults() async throws {
        let older = try QRImageCodec.generate(.init(payload: "OLDER"), in: ownedDirectory("older"))
        let newer = try QRImageCodec.generate(.init(payload: "NEWER"), in: ownedDirectory("newer"))
        var pending: CheckedContinuation<FileShelfItem, Error>?
        let store = QRToolStore(captureArea: {
            try await withCheckedThrowingContinuation { pending = $0 }
        }, exportRoot: fixtureDirectory.appendingPathComponent("exports"))
        defer { store.shutdown() }
        store.scanScreenRegion()
        try await NativeFeatureEvaluation.waitUntil("Injected capture started") { pending != nil }
        store.cancel(); store.scanPNG(newer.url)
        let completion = try XCTUnwrap(pending); pending = nil
        completion.resume(returning: FileShelfItem(originalURL: older.url, managedURL: older.url))
        try await NativeFeatureEvaluation.waitUntil("Newer PNG scan finished", timeout: .seconds(10)) { !store.isWorking }
        XCTAssertEqual(store.decodedPayloads, ["NEWER"])
        store.payload = "Orbit QR 8472"; store.generate()
        try await NativeFeatureEvaluation.waitUntil("Generated QR PNG is ready", timeout: .seconds(10)) { !store.isWorking }
        let output = try XCTUnwrap(store.generatedPNG)
        let decodedExport = try await QRImageCodec.scanPNG(output)
        XCTAssertEqual(decodedExport.payloads, ["Orbit QR 8472"])
        XCTAssertNotNil(store.preview); XCTAssertNil(store.error)
        try await NativeFeatureEvaluation.render(AnyView(QRToolView(store: store)),
            named: "NotchOrbitPlus-QR-fixture-generated-and-decoded.png", size: NSSize(width: 560, height: 560))
    }

    private func ownedDirectory(_ name: String) throws -> URL {
        let url = fixtureDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }
    private func combinedPNG(_ urls: [URL]) throws -> URL {
        let images = try urls.map { url -> CGImage in
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let cell = (images.map(\.width).max() ?? 0) + 32
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: cell * images.count, height: cell,
            bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(cell * images.count), height: CGFloat(cell)))
        context.interpolationQuality = .none
        for (index, image) in images.enumerated() {
            context.draw(image, in: CGRect(x: CGFloat(index * cell + 16), y: 16,
                                          width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        let canvas = try XCTUnwrap(context.makeImage())
        let url = fixtureDirectory.appendingPathComponent("multiple-QR.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, canvas, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
