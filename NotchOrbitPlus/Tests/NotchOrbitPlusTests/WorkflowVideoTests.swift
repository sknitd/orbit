import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
import OrbitCore
import NotchCore
@testable import NotchOrbitPlus

final class WorkflowVideoTests: NativeImageFixtureCase, @unchecked Sendable {
    func testRealMOVCompressionAndZIPPublishPlayableSmallerVideoWithoutReplacingSources() async throws {
        let source = try await movie()
        let original = try Data(contentsOf: source)
        let output = try directory("outputs")
        let collision = output.appendingPathComponent("Video delivery.zip")
        let existing = Data("preexisting archive".utf8)
        try existing.write(to: collision)
        let ledger = VideoWorkflowProgress()
        let result = try await WorkflowRunner.perform(preset: .init(name: "Video delivery", steps: [.compressVideo, .zip]),
                                                      urls: [source], outputDirectory: output) { value, message in
            ledger.record(value, message)
        }
        let archive = try XCTUnwrap(result.outputs.first)
        XCTAssertEqual(result.outputs.count, 1)
        XCTAssertEqual(archive.lastPathComponent, "Video delivery (2).zip")
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: collision), existing)
        let extraction = try directory("extracted")
        let unpacked = try await ArchiveEngine().perform(.unzip, items: FileInspector.inspect([archive]),
                                                         context: .init(outputDirectory: extraction))
        let folder = try XCTUnwrap(unpacked.outputs.first)
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        let movies = try iterator.compactMap { value -> URL? in
            guard let url = value as? URL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return url
        }
        let compressed = try XCTUnwrap(movies.first)
        XCTAssertEqual(movies.count, 1)
        XCTAssertEqual(compressed.lastPathComponent, "recording-Video delivery.mp4")
        XCTAssertLessThan(try Data(contentsOf: compressed).count, original.count)
        let asset = AVURLAsset(url: compressed)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(playable)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.15)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        XCTAssertTrue(descriptions.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 })
        let values = ledger.values()
        XCTAssertEqual(values.last, 1)
        XCTAssertTrue(values.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testUnsupportedSecondMOVRollsBackTheFirstRealCompressionAndPreservesBothSources() async throws {
        let source = try await movie()
        let original = try Data(contentsOf: source)
        let bad = fixtureDirectory.appendingPathComponent("unsupported.mov")
        let badBytes = Data("unsupported movie bytes".utf8)
        try badBytes.write(to: bad)
        let output = try directory("outputs")
        let sentinel = output.appendingPathComponent("keep.txt")
        let prior = Data("keep output".utf8); try prior.write(to: sentinel)
        let ledger = VideoWorkflowProgress()
        do {
            _ = try await WorkflowRunner.perform(preset: .videoStarter, urls: [source, bad], outputDirectory: output) { value, message in
                ledger.record(value, message)
            }
            XCTFail("An unsupported second video must reject the entire saved workflow")
        } catch {
            XCTAssertTrue(ledger.completedFirst(), "The first valid MOV must really compress before the second fails")
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try Data(contentsOf: bad), badBytes)
            XCTAssertEqual(try Data(contentsOf: sentinel), prior)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["keep.txt"])
        }
    }

    private func directory(_ name: String) throws -> URL {
        let url = fixtureDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func movie() async throws -> URL {
        let url = fixtureDirectory.appendingPathComponent("recording.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240
        ])
        guard writer.canAdd(input) else { throw OrbitError.failed("Fixture cannot add a video track") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? OrbitError.failed("Fixture writer cannot start") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? OrbitError.failed("Fixture writer failed") }
                try await Task.sleep(for: .milliseconds(2))
            }
            var optional: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32ARGB, nil, &optional), kCVReturnSuccess)
            let pixel = try XCTUnwrap(optional)
            CVPixelBufferLockBaseAddress(pixel, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<240 {
                for x in 0..<320 {
                    let offset = y * row + x * 4
                    base[offset] = 255; base[offset + 1] = UInt8((x + frame * 7) % 256)
                    base[offset + 2] = UInt8((y + frame * 3) % 256); base[offset + 3] = UInt8((x + y) % 256)
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1)); input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? OrbitError.failed("Fixture writer did not finish") }
        // A standard ignored QuickTime `free` atom guarantees headroom without altering real video frames.
        let padding = 1_048_576
        var free = Data(); var size = UInt32(padding + 8).bigEndian
        withUnsafeBytes(of: &size) { free.append(contentsOf: $0) }
        free.append(Data("free".utf8)); free.append(Data(repeating: 0, count: padding))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: free)
        return url
    }
}

private final class VideoWorkflowProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    private var firstFinished = false
    func record(_ value: Double, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(value)
        if message == "1 of 2 complete" { firstFinished = true }
    }
    func values() -> [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
    func completedFirst() -> Bool { lock.lock(); defer { lock.unlock() }; return firstFinished }
}
