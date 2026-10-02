import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
import OrbitCore
@testable import OrbitDrop

final class MediaEngineTests: EngineTestCase, @unchecked Sendable {
    func testPCMToM4AProducesPlayableAudioAndRetainsOriginal() async throws {
        let source = try wave()
        let original = try Data(contentsOf: source)
        let result = try await NativeMediaEngine().perform(.audioM4A, items: inspect([source]), context: .init())
        let output = try XCTUnwrap(result.outputs.first)
        XCTAssertEqual(output.pathExtension, "m4a")
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.15)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testNativeVideoTranscodeProducesPlayableH264() async throws {
        let source = try await movie()
        let original = try Data(contentsOf: source)
        let result = try await NativeMediaEngine().perform(.videoMP4, items: inspect([source]), context: .init())
        let output = try XCTUnwrap(result.outputs.first)
        XCTAssertEqual(output.pathExtension, "mp4")
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.15)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        XCTAssertTrue(formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 })
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testExtractAudioFromMovieWithRealAudioTrack() async throws {
        let video = try await movie()
        let audio = try wave()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let composition = AVMutableComposition()
        let videoTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        try videoTrack.insertTimeRange(range, of: XCTUnwrap(videoTracks.first), at: .zero)
        try audioTrack.insertTimeRange(range, of: XCTUnwrap(audioTracks.first), at: .zero)
        let combined = directory.appendingPathComponent("with-audio.mov")
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        export.outputURL = combined
        export.outputFileType = .mov
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        XCTAssertEqual(export.status, .completed, export.error?.localizedDescription ?? "Fixture export failed")
        let original = try Data(contentsOf: combined)
        let result = try await NativeMediaEngine().perform(.extractAudio, items: inspect([combined]), context: .init())
        let output = try XCTUnwrap(result.outputs.first)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        let outputAudio = try await asset.loadTracks(withMediaType: .audio)
        let outputVideo = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(outputAudio.count, 1)
        XCTAssertTrue(outputVideo.isEmpty)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.15)
        XCTAssertEqual(try Data(contentsOf: combined), original)
    }

    func testExtractionFromSilentVideoFailsWithoutPublishingAudio() async throws {
        let source = try await movie()
        do {
            _ = try await NativeMediaEngine().perform(.extractAudio, items: inspect([source]), context: .init())
            XCTFail("An audio-less video must not produce synthetic audio")
        } catch {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            XCTAssertEqual(files, [source])
        }
    }

    private func wave() throws -> URL {
        let samples = 44_100
        var body = Data()
        for index in 0..<samples {
            let sample = Int16(sin(Double(index) * 2 * .pi * 440 / 44_100) * 12_000)
            body.le16(UInt16(bitPattern: sample))
        }
        var bytes = Data("RIFF".utf8); bytes.le32(UInt32(body.count + 36)); bytes.append(Data("WAVEfmt ".utf8))
        bytes.le32(16); bytes.le16(1); bytes.le16(1); bytes.le32(44_100); bytes.le32(88_200)
        bytes.le16(2); bytes.le16(16); bytes.append(Data("data".utf8)); bytes.le32(UInt32(body.count)); bytes.append(body)
        let url = directory.appendingPathComponent("tone.wav")
        try bytes.write(to: url)
        return url
    }

    private func movie() async throws -> URL {
        let url = directory.appendingPathComponent("fixture.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240
        ])
        XCTAssertTrue(writer.canAdd(input)); writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? OrbitError.failed("Fixture writer failed") }
                try await Task.sleep(for: .milliseconds(2))
            }
            var optionalBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32ARGB, nil, &optionalBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(optionalBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<240 {
                for x in 0..<320 {
                    let offset = y * rowBytes + x * 4
                    address[offset] = 255
                    address[offset + 1] = UInt8((x + frame * 7) % 256)
                    address[offset + 2] = UInt8((y + frame * 3) % 256)
                    address[offset + 3] = UInt8((x + y) % 256)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "Fixture writer did not finish")
        return url
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func le32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16)); append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
