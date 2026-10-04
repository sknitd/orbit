import Foundation
import ImageIO
import Vision

/// Explicit local OCR for a retained image; never observes the clipboard.
enum ClipboardImageOCR {
    enum Failure: Error, LocalizedError, Equatable, Sendable {
        case invalidImage, imageTooLarge, noText
        var errorDescription: String? {
            switch self {
            case .invalidImage: "The clip does not contain a readable raster image."
            case .imageTooLarge: "Clipboard OCR accepts images up to 4 MB and 40 megapixels. Resize the image first."
            case .noText: "Vision found no readable text in this image."
            }
        }
    }
    static let maximumDataBytes = 4 * 1_024 * 1_024
    static let maximumTextBytes = 100_000

    static func recognize(_ data: Data) async throws -> String {
        guard !data.isEmpty else { throw Failure.invalidImage }
        guard data.count <= maximumDataBytes else { throw Failure.imageTooLarge }
        let cancellation = ClipboardOCRCancellation()
        let worker = Task.detached(priority: .userInitiated) { () throws -> String in
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else { throw Failure.invalidImage }
            guard width <= 20_000, height <= 20_000, width * height <= 40_000_000 else { throw Failure.imageTooLarge }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw Failure.invalidImage
            }
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            cancellation.attach(request)
            defer { cancellation.finish() }
            try Task.checkCancellation()
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
            try Task.checkCancellation()
            let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recognized.isEmpty else { throw Failure.noText }
            // Preserve a valid UTF-8 prefix without retaining unbounded OCR.
            var bounded = Data(recognized.utf8.prefix(maximumTextBytes))
            while !bounded.isEmpty {
                if let text = String(data: bounded, encoding: .utf8) { return text }
                bounded.removeLast()
            }
            throw Failure.noText
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            cancellation.cancel()
        }
    }
}

/// Synchronizes publication of the request's cancellation handle. Creation,
/// configuration, result access and perform remain on the worker; the sole
/// off-worker operation is Vision's public request.cancel() cancellation API.
private final class ClipboardOCRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false
    func attach(_ request: VNRequest) {
        lock.lock()
        self.request = request
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { request.cancel() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let current = request
        lock.unlock()
        current?.cancel()
    }
    func finish() {
        lock.lock()
        request = nil
        lock.unlock()
    }
}
