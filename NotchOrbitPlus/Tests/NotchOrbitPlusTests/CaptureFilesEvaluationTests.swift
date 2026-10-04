import AppKit
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import SwiftUI
import Combine
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

    @MainActor
    func testImmediateRecordingHideNeverChecksOrRequestsPermission() async throws {
        let directory = fixtureDirectory.appendingPathComponent("ImmediateHideShelf")
        let shelf = FileShelfToolStore(managedDirectory: directory, persistState: false)
        var checked = 0; var requested = 0
        let store = ScreenshotShelfStore(shelf: shelf, persistState: false,
            permissionCheck: { checked += 1; return false }, permissionRequest: { requested += 1; return false })
        store.setVisible(true)
        // Both calls share one MainActor turn, before the recording child can run.
        store.startRecording()
        store.setVisible(false)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(checked, 0); XCTAssertEqual(requested, 0)
        XCTAssertFalse(store.isWorking); XCTAssertFalse(store.isRecording)
        XCTAssertTrue(store.history.isEmpty); XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.status, "Capture stopped; no partial capture will be published.")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        store.shutdown(); shelf.shutdown()
    }

    @MainActor
    func testHostedVisibilityDefersPublishedChangesAndStopsPickerOnHideAndTeardown() async throws {
        let shelf = FileShelfToolStore(managedDirectory: fixtureDirectory.appendingPathComponent("HostedShelf"), persistState: false)
        var permissionChecks = 0; var permissionRequests = 0; var samples = 0
        let capture = ScreenshotShelfStore(shelf: shelf, persistState: false,
            permissionCheck: { permissionChecks += 1; return false },
            permissionRequest: { permissionRequests += 1; return false })
        let picker = ColorPickerStore(persistHistory: false, sampling: { _ in samples += 1 })
        let state = CaptureHostedVisibilityState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 140),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CaptureHostedVisibilityFixture(state: state, picker: picker, capture: capture))
        window.contentView = host
        defer { window.close(); capture.shutdown(); picker.shutdown(); shelf.shutdown() }
        window.makeKeyAndOrderFront(nil)
        try await waitForVisibility { state.visibleCount > 0 }
        XCTAssertEqual(permissionChecks, 0); XCTAssertEqual(permissionRequests, 0)
        picker.pick(); XCTAssertTrue(picker.isPicking)
        window.orderOut(nil)
        try await waitForVisibility { !picker.isPicking && state.hiddenCount > 0 }
        XCTAssertTrue(picker.history.isEmpty)

        let previousVisible = state.visibleCount
        window.makeKeyAndOrderFront(nil)
        try await waitForVisibility { state.visibleCount > previousVisible }
        picker.pick(); XCTAssertTrue(picker.isPicking)
        let previousHidden = state.hiddenCount
        state.isMounted = false
        host.layoutSubtreeIfNeeded()
        // Updating/dismantling NSViewRepresentable must not publish synchronously.
        XCTAssertEqual(state.hiddenCount, previousHidden)
        try await waitForVisibility { state.hiddenCount > previousHidden && !picker.isPicking }
        let finalVisible = state.visibleCount
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.visibleCount, finalVisible, "A dismantled visibility view cannot revive")
        XCTAssertEqual(samples, 2)
        XCTAssertEqual(permissionChecks, 0); XCTAssertEqual(permissionRequests, 0)
        XCTAssertTrue(capture.history.isEmpty); XCTAssertTrue(shelf.items.isEmpty)
    }

    @MainActor
    func testDisconnectedVisibilityCancelsQueuedVisibleDeliveryAndCannotReattachAfterDismantle() async throws {
        var visible = 0; var hidden = 0
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = CaptureVisibilityView()
        view.visibleAction = { visible += 1 }; view.hiddenAction = { hidden += 1 }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.checkVisibility()
        view.removeFromSuperview()
        CaptureToolVisibility.dismantleNSView(view, coordinator: ())
        XCTAssertEqual(visible, 0); XCTAssertEqual(hidden, 0, "Teardown callbacks must be deferred")
        try await waitForVisibility { hidden == 1 }
        XCTAssertEqual(visible, 0, "An obsolete visible delivery must be discarded")
        window.contentView = view
        view.checkVisibility()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(visible, 0); XCTAssertEqual(hidden, 1)
    }

    @MainActor
    private func waitForVisibility(_ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Expected native visibility delivery before timeout")
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

@MainActor
private final class CaptureHostedVisibilityState: ObservableObject {
    @Published var isMounted = true
    @Published var visibleCount = 0
    @Published var hiddenCount = 0
}

@MainActor
private struct CaptureHostedVisibilityFixture: View {
    @ObservedObject var state: CaptureHostedVisibilityState
    @ObservedObject var picker: ColorPickerStore
    let capture: ScreenshotShelfStore
    var body: some View {
        VStack {
            Text("Visible \(state.visibleCount), hidden \(state.hiddenCount), picking \(picker.isPicking.description)")
            if state.isMounted {
                Color.clear.frame(width: 20, height: 20).background(CaptureToolVisibility(
                    onVisible: { state.visibleCount += 1; capture.setVisible(true) },
                    onHidden: { state.hiddenCount += 1; picker.shutdown(); capture.setVisible(false) }))
            }
        }.frame(width: 260, height: 140)
    }
}
