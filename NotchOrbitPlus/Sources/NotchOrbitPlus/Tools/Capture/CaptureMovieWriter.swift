import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

enum ScreenCaptureFailure: Error, LocalizedError, Sendable {
    case permission, unavailable, noWindow, cancelled, emptyMovie, encoding(String)
    var errorDescription: String? {
        switch self {
        case .permission: "Screen Recording access is needed. Allow NotchOrbitPlus in Privacy & Security, then retry capture. macOS may require reopening the app."
        case .unavailable: "The chosen display or window is no longer available."
        case .noWindow: "Choose a shareable window, then press Start again."
        case .cancelled: "Capture cancelled; no partial file was added to the shelf."
        case .emptyMovie: "No usable video frames arrived. The incomplete recording was removed."
        case .encoding(let message): "The recording could not be saved: \(message)"
        }
    }
}

/// Writer, sample append, and finish state are confined to the supplied stream-output queue.
final class CaptureMovieWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.sknitd.NotchOrbitPlus.capture.writer", qos: .userInitiated)
    let outputURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var began = false
    private var ending = false
    private var frames = 0
    private var firstTimestamp: CMTime?
    private var lastTimestamp: CMTime?
    private var lastSample: CMSampleBuffer?
    private let failed: @Sendable (String) -> Void

    init(url: URL, width: Int, height: Int, failed: @escaping @Sendable (String) -> Void = { _ in }) throws {
        guard width >= 2, height >= 2, width % 2 == 0, height % 2 == 0,
              width <= 3_840, height <= 2_160 else { throw ScreenCaptureFailure.unavailable }
        outputURL = url; self.failed = failed
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(128_000, min(16_000_000, width * height * 4)),
                                             AVVideoMaxKeyFrameIntervalKey: 30]
        ])
        input.expectsMediaDataInRealTime = true
        super.init()
        guard writer.canAdd(input) else { throw ScreenCaptureFailure.encoding("The video encoder is unavailable.") }
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        appendOnQueue(sampleBuffer)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { failed(error.localizedDescription) }

    /// Native fixture tests feed genuine uncompressed video samples; no display permission is requested.
    func appendVideoSample(_ sample: CMSampleBuffer) {
        let owned = CaptureOwnedSample(sample)
        queue.async { [self, owned] in appendOnQueue(owned.value) }
    }
    private func appendOnQueue(_ sample: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !ending, CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
              CMSampleBufferGetImageBuffer(sample) != nil else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]], let raw = attachments.first?[.status] as? Int,
           raw != SCFrameStatus.complete.rawValue { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard timestamp.isNumeric else { return }
        if !began {
            guard writer.startWriting() else { ending = true; failed(writer.error?.localizedDescription ?? "The encoder did not start."); return }
            writer.startSession(atSourceTime: timestamp); began = true; firstTimestamp = timestamp
        }
        guard input.isReadyForMoreMediaData else { return }
        guard input.append(sample) else {
            ending = true; failed(writer.error?.localizedDescription ?? "The encoder rejected a frame."); return
        }
        frames += 1
        lastSample = sample; lastTimestamp = timestamp
    }

    func finish(duration: Double? = nil) async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard began, frames > 0, !ending, writer.status == .writing else {
                    writer.cancelWriting(); ending = true
                    continuation.resume(throwing: ScreenCaptureFailure.emptyMovie); return
                }
                if let duration, duration.isFinite, duration > 0, let firstTimestamp {
                    let end = CMTimeAdd(firstTimestamp, CMTime(seconds: duration, preferredTimescale: 600))
                    let finalFrame = CMTimeSubtract(end, CMTime(value: 1, timescale: 30))
                    if let lastSample, let lastTimestamp, CMTimeCompare(finalFrame, lastTimestamp) > 0 {
                        let deadline = Date().addingTimeInterval(2)
                        while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        guard input.isReadyForMoreMediaData else {
                            writer.cancelWriting(); ending = true
                            continuation.resume(throwing: ScreenCaptureFailure.encoding("The encoder did not accept the final frame.")); return
                        }
                        // ScreenCaptureKit emits idle markers on an unchanged display. Extend the
                        // last real frame to the requested stop time instead of making a one-frame clip.
                        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                                       presentationTimeStamp: finalFrame, decodeTimeStamp: .invalid)
                        var copy: CMSampleBuffer?
                        if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastSample,
                            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                           let copy { _ = input.append(copy) }
                    }
                    writer.endSession(atSourceTime: end)
                }
                ending = true; lastSample = nil; input.markAsFinished()
                writer.finishWriting { [self] in
                    queue.async { [self] in
                        if writer.status == .completed { continuation.resume(returning: outputURL) }
                        else { continuation.resume(throwing: ScreenCaptureFailure.encoding(writer.error?.localizedDescription ?? "The encoder did not finish.")) }
                    }
                }
            }
        }
        } onCancel: { [self] in Task { await cancel() } }
    }
    func cancel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                ending = true
                lastSample = nil
                if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
                continuation.resume()
            }
        }
    }
}

/// One retained, immutable fixture sample can cross into the writer queue; callers never mutate it afterward.
private final class CaptureOwnedSample: @unchecked Sendable {
    let value: CMSampleBuffer
    init(_ value: CMSampleBuffer) { self.value = value }
}
