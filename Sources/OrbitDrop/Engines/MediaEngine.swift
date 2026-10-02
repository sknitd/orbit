#if os(macOS)
import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import OrbitCore

/// Keeps the media implementation replaceable without coupling the UI to a codec library.
protocol MediaEngine: ActionEngine {}

/// Uses Apple's asynchronous export pipeline. No external processes or network services run.
struct NativeMediaEngine: MediaEngine {
    func perform(_ action: ActionID, items: [FileItem], context: ActionContext) async throws -> ActionResult {
        let plan = try ExportPlan(action: action)
        guard !items.isEmpty else { throw OrbitError.invalidInput("Choose a media file first.") }

        var outputs: [URL] = []
        var inputBytes: Int64 = 0
        var outputBytes: Int64 = 0
        var finished = false
        // A failed batch must not leave results that the caller never receives.
        defer {
            if !finished {
                for output in outputs { try? FileManager.default.removeItem(at: output) }
            }
        }

        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            guard item.url.isFileURL, FileManager.default.isReadableFile(atPath: item.url.path) else {
                throw OrbitError.invalidInput("The source media file cannot be read.")
            }
            let sourceBytes = try Self.byteCount(at: item.url)
            let asset = AVURLAsset(url: item.url)
            let source = try await inspect(asset, plan: plan)
            let export = try await exporter(for: asset, plan: plan)
            try Task.checkCancellation()

            let stem = item.url.deletingPathExtension().lastPathComponent + plan.nameSuffix
            let transaction = try OutputTransaction(
                source: item.url, outputDirectory: context.outputDirectory,
                stem: stem, extension: plan.pathExtension
            )
            defer { transaction.cleanup() }

            export.outputURL = transaction.stagingURL
            export.outputFileType = plan.fileType
            export.shouldOptimizeForNetworkUse = plan.fileType == .mp4
            let operation = ExportOperation(session: export)
            let total = Double(items.count)
            context.progress(Double(index) / total, "Exporting \(item.url.lastPathComponent) · \(index) of \(items.count) complete")
            try await operation.run { fraction in
                context.progress(
                    (Double(index) + fraction) / total,
                    "Exporting \(item.url.lastPathComponent) · \(index) of \(items.count) complete"
                )
            }
            try Task.checkCancellation()

            context.progress((Double(index) + 1) / total, "Checking \(item.url.lastPathComponent) · \(index) of \(items.count) complete")
            try await validateOutput(at: transaction.stagingURL, plan: plan, source: source)
            let encodedBytes = try Self.byteCount(at: transaction.stagingURL)
            if action == .compressVideo, encodedBytes >= sourceBytes {
                throw OrbitError.failed("The native compression preset could not make \(item.url.lastPathComponent) smaller. The original was kept.")
            }
            try Task.checkCancellation()
            let output = try transaction.commit { staged in
                guard try Self.byteCount(at: staged) > 0 else {
                    throw OrbitError.failed("The media export produced an empty file.")
                }
            }
            outputs.append(output)
            inputBytes += sourceBytes
            outputBytes += encodedBytes
            context.progress(Double(index + 1) / total, "\(index + 1) of \(items.count) complete")
        }

        try Task.checkCancellation()
        finished = true
        return ActionResult(outputs: outputs, inputBytes: inputBytes, outputBytes: outputBytes)
    }

    private func inspect(_ asset: AVURLAsset, plan: ExportPlan) async throws -> SourceMedia {
        let protected = try await asset.load(.hasProtectedContent)
        guard !protected else {
            throw OrbitError.unsupported("Protected media cannot be exported.")
        }
        guard try await asset.load(.isExportable) else {
            throw OrbitError.unsupported("Apple's media framework cannot export this file.")
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw OrbitError.invalidInput("The media file has no valid duration.")
        }
        let requiredTracks = try await asset.loadTracks(withMediaType: plan.mediaType)
        guard !requiredTracks.isEmpty else {
            let trackName = plan.mediaType == .video ? "video" : "audio"
            throw OrbitError.invalidInput("The selected file has no \(trackName) track.")
        }
        var requiredDuration: Double = 0
        for track in requiredTracks {
            let range = try await track.load(.timeRange)
            if range.duration.isNumeric, range.duration.seconds.isFinite {
                requiredDuration = max(requiredDuration, range.duration.seconds)
            }
        }
        guard requiredDuration > 0 else {
            throw OrbitError.invalidInput("The selected media track is empty.")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        return SourceMedia(requiredDuration: requiredDuration, hasAudio: !audioTracks.isEmpty)
    }

    private func exporter(for asset: AVURLAsset, plan: ExportPlan) async throws -> AVAssetExportSession {
        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        for preset in plan.presets where compatiblePresets.contains(preset) {
            try Task.checkCancellation()
            let compatible = await withCheckedContinuation { continuation in
                AVAssetExportSession.determineCompatibility(
                    ofExportPreset: preset, with: asset, outputFileType: plan.fileType
                ) { compatible in
                    continuation.resume(returning: compatible)
                }
            }
            guard compatible,
                  let session = AVAssetExportSession(asset: asset, presetName: preset),
                  session.supportedFileTypes.contains(plan.fileType) else { continue }
            return session
        }
        throw OrbitError.unsupported("This file has no compatible native \(plan.pathExtension.uppercased()) export preset. Try a media format supported by macOS.")
    }

    private func validateOutput(at url: URL, plan: ExportPlan, source: SourceMedia) async throws {
        guard try Self.byteCount(at: url) > 0 else {
            throw OrbitError.failed("The media export produced an empty file.")
        }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw OrbitError.failed("The exported media could not be played by macOS.")
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw OrbitError.failed("The exported media has no valid duration.")
        }
        let tracks = try await asset.loadTracks(withMediaType: plan.mediaType)
        guard !tracks.isEmpty else {
            throw OrbitError.failed("The exported media is missing its required track.")
        }
        var longestTrack: Double = 0
        for track in tracks {
            let range = try await track.load(.timeRange)
            if range.duration.isNumeric, range.duration.seconds.isFinite {
                longestTrack = max(longestTrack, range.duration.seconds)
            }
            if plan.mediaType == .video {
                let descriptions = try await track.load(.formatDescriptions)
                guard descriptions.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else {
                    throw OrbitError.failed("The export did not produce the expected H.264 video codec.")
                }
            }
        }
        // Audio extraction uses audio-track duration, since it may differ from video duration.
        let tolerance = max(0.3, source.requiredDuration * 0.01)
        guard abs(longestTrack - source.requiredDuration) <= tolerance else {
            throw OrbitError.failed("The exported media duration does not match its source track.")
        }
        if plan.mediaType == .video, source.hasAudio {
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard !audio.isEmpty else {
                throw OrbitError.failed("The exported video lost its audio track.")
            }
        }
    }

    private static func byteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let count = values.fileSize else {
            throw OrbitError.invalidInput("Choose a regular media file.")
        }
        return Int64(count)
    }
}

private struct SourceMedia {
    let requiredDuration: Double
    let hasAudio: Bool
}

private struct ExportPlan {
    let presets: [String]
    let fileType: AVFileType
    let mediaType: AVMediaType
    let pathExtension: String
    let nameSuffix: String

    init(action: ActionID) throws {
        switch action {
        case .videoMP4:
            presets = [AVAssetExportPreset1920x1080, AVAssetExportPresetMediumQuality]
            fileType = .mp4; mediaType = .video; pathExtension = "mp4"; nameSuffix = " converted"
        case .compressVideo:
            presets = [AVAssetExportPresetMediumQuality, AVAssetExportPreset1920x1080]
            fileType = .mp4; mediaType = .video; pathExtension = "mp4"; nameSuffix = " compressed"
        case .extractAudio, .audioM4A:
            presets = [AVAssetExportPresetAppleM4A]
            fileType = .m4a; mediaType = .audio; pathExtension = "m4a"
            nameSuffix = action == .extractAudio ? " audio" : " converted"
        default:
            throw OrbitError.unsupported("This action is not a media export.")
        }
    }
}

/// The session belongs exclusively to one operation. A lock serializes starting,
/// cancellation, progress reads, and completion; AVFoundation owns the encoder threads.
private final class ExportOperation: @unchecked Sendable {
    private let session: AVAssetExportSession
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var cancellationRequested = false

    init(session: AVAssetExportSession) { self.session = session }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        let reporter = Task {
            while !Task.isCancelled {
                progress(reportedProgress())
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
        }
        defer { reporter.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation)
            }
        } onCancel: {
            self.cancel()
        }
        try Task.checkCancellation()
    }

    private func start(_ continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        guard !cancellationRequested else {
            lock.unlock()
            continuation.resume(throwing: OrbitError.cancelled)
            return
        }
        self.continuation = continuation
        lock.unlock()
        session.exportAsynchronously { [self] in finish() }
        // Cancellation may have arrived just before the session started. Recheck
        // after starting so that an early cancelExport() cannot be lost.
        lock.lock()
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { session.cancelExport() }
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let hasContinuation = continuation != nil
        lock.unlock()
        if hasContinuation { session.cancelExport() }
    }

    private func reportedProgress() -> Double {
        lock.lock()
        let fraction = Double(session.progress)
        lock.unlock()
        return fraction.isFinite ? min(1, max(0, fraction)) : 0
    }

    private func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let status = session.status
        let message = session.error?.localizedDescription
        let wasCancelled = cancellationRequested || status == .cancelled
        lock.unlock()
        guard let continuation else { return }
        if wasCancelled {
            continuation.resume(throwing: OrbitError.cancelled)
        } else if status == .completed {
            continuation.resume()
        } else {
            continuation.resume(throwing: OrbitError.failed(message ?? "The native media export failed."))
        }
    }
}
#endif
