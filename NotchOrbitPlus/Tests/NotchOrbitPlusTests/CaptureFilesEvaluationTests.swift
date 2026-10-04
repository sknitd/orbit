import AppKit
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class CaptureFilesEvaluationTests: NativeImageFixtureCase, @unchecked Sendable {
    @MainActor
    func testRealPNGBecomesManagedShelfCopyEvenWhenAutoSaveIsOff() async throws {
        let source = try rasterFile(named: "fixture.png", width: 32, height: 20)
        let decoder = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoder, 0, nil))
        let staging = fixtureDirectory.appendingPathComponent("Screenshot.png")
        try ScreenCaptureFiles.writePNG(image, at: staging)
        let original = try Data(contentsOf: staging)
        let shelf = FileShelfToolStore(managedDirectory: fixtureDirectory.appendingPathComponent("Shelf"), persistState: false)
        XCTAssertFalse(shelf.autoSave)
        let item = try await shelf.addManagedCapture(staging)
        let owned = try XCTUnwrap(item.managedURL)
        XCTAssertNotEqual(owned, staging)
        XCTAssertEqual(try Data(contentsOf: staging), original)
        XCTAssertEqual(try Data(contentsOf: owned), original)
        XCTAssertEqual(shelf.items.count, 1)
        try FileManager.default.removeItem(at: staging)
        XCTAssertEqual(shelf.resolve(item), owned)
        let copySource = try XCTUnwrap(CGImageSourceCreateWithURL(owned as CFURL, nil))
        let copiedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(copySource, 0, nil))
        XCTAssertEqual(copiedImage.width, 32); XCTAssertEqual(copiedImage.height, 20)
        shelf.shutdown()
    }

    @MainActor
    func testInvalidatedCaptureGenerationRemovesOnlyItsUnpublishedCopy() async throws {
        let source = try rasterFile(named: "cancelled.png", width: 32, height: 20)
        let original = try Data(contentsOf: source)
        let directory = fixtureDirectory.appendingPathComponent("Shelf")
        let shelf = FileShelfToolStore(managedDirectory: directory, persistState: false)
        var published = false
        do {
            _ = try await shelf.addManagedCapture(source, isCurrent: { false }, didPublish: { _ in published = true })
            XCTFail("An invalidated capture must not publish")
        } catch is CancellationError { }
        XCTAssertFalse(published)
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        shelf.shutdown()
    }

    @MainActor
    func testUnstartedLifecycleNeverRequestsPermissionAndDeniedIntentProducesNoFile() async throws {
        var checked = 0; var requested = 0
        let shelf = FileShelfToolStore(managedDirectory: fixtureDirectory.appendingPathComponent("Shelf"), persistState: false)
        let store = ScreenshotShelfStore(shelf: shelf, persistState: false,
            permissionCheck: { checked += 1; return false }, permissionRequest: { requested += 1; return false })
        store.setVisible(true); store.setVisible(false); store.shutdown()
        XCTAssertEqual(checked, 0); XCTAssertEqual(requested, 0)
        XCTAssertFalse(store.isRecording); XCTAssertFalse(store.isWorking)
        do { _ = try await store.captureFullScreenForIntent(); XCTFail("Denied capture must throw") }
        catch let failure as ScreenCaptureFailure {
            guard case .permission = failure else { return XCTFail("Unexpected capture failure: \(failure)") }
        }
        XCTAssertEqual(checked, 1); XCTAssertEqual(requested, 1)
        XCTAssertTrue(shelf.items.isEmpty); XCTAssertTrue(store.history.isEmpty)
        XCTAssertFalse(store.isRecording); XCTAssertFalse(store.isWorking)
        shelf.shutdown()
    }

    @MainActor
    func testActualHideCancelsAwaitedScreenshotBeforeScreenCaptureAndPublication() async throws {
        let directory = fixtureDirectory.appendingPathComponent("HiddenShelf")
        let shelf = FileShelfToolStore(managedDirectory: directory, persistState: false)
        let fixture = CaptureHideFixture()
        var checked = 0; var requested = 0
        let store = ScreenshotShelfStore(shelf: shelf, persistState: false,
            permissionCheck: {
                checked += 1
                // Deterministically hide during the owned screenshot child, before
                // it can invoke ScreenCaptureKit. This fixture never calls real TCC.
                fixture.store?.setVisible(false)
                return true
            }, permissionRequest: { requested += 1; return false })
        fixture.store = store
        store.setVisible(true)
        do { _ = try await store.captureFullScreenForIntent(); XCTFail("A hidden screenshot must cancel") }
        catch is CancellationError { }
        XCTAssertEqual(checked, 1); XCTAssertEqual(requested, 0)
        XCTAssertFalse(store.isWorking); XCTAssertFalse(store.isRecording)
        XCTAssertTrue(store.history.isEmpty); XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.status, "Capture stopped; no partial capture will be published.")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        store.shutdown(); shelf.shutdown()
    }

    func testNativeWriterCreatesDecodableMOVAndExtendsAnUnchangedRealFrame() async throws {
        let output = fixtureDirectory.appendingPathComponent("unchanged.mov")
        let writer = try CaptureMovieWriter(url: output, width: 64, height: 48)
        writer.appendVideoSample(try sample(width: 64, height: 48, frame: 0))
        let completed = try await writer.finish(duration: 1)
        let details = try await ScreenCaptureFiles.movieDetails(completed)
        XCTAssertEqual(details.width, 64); XCTAssertEqual(details.height, 48)
        XCTAssertEqual(details.duration, 1, accuracy: 0.08)
        XCTAssertGreaterThan(try ScreenCaptureFiles.byteCount(completed), 0)
        XCTAssertEqual(completed.pathExtension, "mov")
    }

    func testEmptyAndCancelledNativeWriterCannotPublishAPlayableMovie() async throws {
        let empty = fixtureDirectory.appendingPathComponent("empty.mov")
        let writer = try CaptureMovieWriter(url: empty, width: 64, height: 48)
        do { _ = try await writer.finish(duration: 1); XCTFail("A zero-frame movie must fail") }
        catch let failure as ScreenCaptureFailure {
            guard case .emptyMovie = failure else { return XCTFail("Unexpected failure: \(failure)") }
        }
        let cancelled = try CaptureMovieWriter(url: fixtureDirectory.appendingPathComponent("cancelled.mov"), width: 64, height: 48)
        cancelled.appendVideoSample(try sample(width: 64, height: 48, frame: 0))
        await cancelled.cancel()
        do { _ = try await cancelled.finish(duration: 1); XCTFail("Cancelled writer must reject publication") }
        catch let failure as ScreenCaptureFailure {
            guard case .emptyMovie = failure else { return XCTFail("Unexpected cancelled-writer failure: \(failure)") }
        }
    }

    private func sample(width: Int, height: Int, frame: Int) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
        memset(address, 120, CVPixelBufferGetBytesPerRow(pixel) * height)
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixel, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &result), noErr)
        return try XCTUnwrap(result)
    }
}

@MainActor
private final class CaptureHideFixture {
    weak var store: ScreenshotShelfStore?
}
