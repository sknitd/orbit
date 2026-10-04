import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision
import NotchCore

enum QRImageFailure: Error, LocalizedError, Equatable, Sendable {
    case generation, invalidPNG, imageTooLarge, exportFailed
    var errorDescription: String? {
        switch self {
        case .generation: "Core Image could not encode this QR payload."
        case .invalidPNG: "Choose a readable, regular PNG file."
        case .imageTooLarge: "QR scanning accepts PNGs up to 64 MB and 32 megapixels."
        case .exportFailed: "The QR PNG could not be written and verified."
        }
    }
}

struct QRGeneratedImage: Equatable, Sendable {
    let url: URL
    let width: Int
    let height: Int
}
struct QRScanOutput: Equatable, Sendable {
    /// Includes repeated payloads when multiple QR observations contain the same text.
    let payloads: [String]
    let unreadableCount: Int
}

enum QRImageCodec {
    static let maximumDataBytes = 64 * 1_024 * 1_024
    static let maximumPixels = 32_000_000

    /// Creates a new owned PNG; this API never replaces a selected user file.
    static func generate(_ request: QRGenerationRequest, in directory: URL) throws -> QRGeneratedImage {
        try Task.checkCancellation()
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw QRImageFailure.generation }
        filter.setValue(request.utf8Data, forKey: "inputMessage")
        filter.setValue(request.options.correction.rawValue, forKey: "inputCorrectionLevel")
        guard let modules = filter.outputImage else { throw QRImageFailure.generation }
        let scale = CGFloat(request.options.scale)
        let quiet = CGFloat(QREncodingOptions.quietZoneModules) * scale
        let scaled = modules.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = scaled.extent.insetBy(dx: -quiet, dy: -quiet)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: bounds)
        let image = scaled.composited(over: white)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let raster = context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: space) else {
            throw QRImageFailure.generation
        }
        try Task.checkCancellation()
        let url = directory.appendingPathComponent("Orbit-QR.png")
        guard !FileManager.default.fileExists(atPath: url.path),
              let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw QRImageFailure.exportFailed
        }
        do {
            CGImageDestinationAddImage(writer, raster, nil)
            guard CGImageDestinationFinalize(writer) else { throw QRImageFailure.exportFailed }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try Task.checkCancellation()
            let verified = try loadPNG(url)
            guard verified.width == raster.width, verified.height == raster.height else { throw QRImageFailure.exportFailed }
            return QRGeneratedImage(url: url, width: raster.width, height: raster.height)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func scanPNG(_ url: URL) async throws -> QRScanOutput {
        let cancellation = QRVisionCancellation()
        let worker = Task.detached(priority: .userInitiated) { () throws -> QRScanOutput in
            try Task.checkCancellation()
            let image = try loadPNG(url)
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            request.preferBackgroundProcessing = true
            cancellation.attach(request)
            defer { cancellation.finish() }
            try Task.checkCancellation()
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
            catch { if Task.isCancelled { throw CancellationError() }; throw error }
            try Task.checkCancellation()
            let observations = request.results ?? []
            return QRScanOutput(payloads: observations.compactMap(\.payloadStringValue),
                                unreadableCount: observations.filter { $0.payloadStringValue == nil }.count)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: {
            worker.cancel(); cancellation.cancel()
        }
    }

    private static func loadPNG(_ url: URL) throws -> CGImage {
        guard url.isFileURL, url.host == nil || url.host == "localhost" else { throw QRImageFailure.invalidPNG }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw QRImageFailure.invalidPNG }
        guard let size = info.fileSize, size > 0, size <= maximumDataBytes else { throw QRImageFailure.imageTooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumDataBytes + 1) ?? Data()
        guard data.count <= maximumDataBytes else { throw QRImageFailure.imageTooLarge }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (values[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (values[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw QRImageFailure.invalidPNG }
        guard width <= 16_384, height <= 16_384, width * height <= maximumPixels else { throw QRImageFailure.imageTooLarge }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw QRImageFailure.invalidPNG
        }
        return image
    }
}

/// Vision's cancellation handle is synchronized; configuration and results stay on the worker.
private final class QRVisionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false
    func attach(_ request: VNRequest) {
        lock.lock(); self.request = request; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { request.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = request; lock.unlock()
        current?.cancel()
    }
    func finish() { lock.lock(); request = nil; lock.unlock() }
}
