import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import OrbitCore

struct ImageEngine: ActionEngine {
    func perform(_ action: ActionID, items: [FileItem], context: ActionContext) async throws -> ActionResult {
        let work = Task.detached(priority: .userInitiated) {
            try Self.process(action, items: items, context: context)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private static func process(_ action: ActionID, items: [FileItem], context: ActionContext) throws -> ActionResult {
        guard !items.isEmpty, items.allSatisfy({ $0.kind == .image }) else { throw OrbitError.invalidInput("Choose one or more images.") }
        let supported: Set<ActionID> = [.jpeg, .png, .heic, .webp, .compressImage, .resize1600, .removeMetadata, .removeGPS]
        guard supported.contains(action) else { throw OrbitError.unsupported("That action is not an image transformation.") }
        var outputs = [URL]()
        do {
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                context.progress(Double(index) / Double(items.count), "Processing \(item.url.lastPathComponent)")
                let output = try autoreleasepool { try transform(action, item: item, context: context) }
                outputs.append(output)
            }
            try Task.checkCancellation()
            context.progress(1, "Images ready")
            return ActionResult(outputs: outputs, inputBytes: items.reduce(0) { $0 + $1.byteCount }, outputBytes: try totalBytes(outputs))
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output) }
            throw error
        }
    }

    private static func transform(_ action: ActionID, item: FileItem, context: ActionContext) throws -> URL {
        let source = CGImageSourceCreateWithURL(item.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let sourceType = source.flatMap { CGImageSourceGetType($0) }.map { $0 as String } ?? item.typeIdentifier
        let outputType: String
        let suffix: String
        switch action {
        case .jpeg: outputType = UTType.jpeg.identifier; suffix = "jpg"
        case .png: outputType = UTType.png.identifier; suffix = "png"
        case .heic: outputType = UTType.heic.identifier; suffix = "heic"
        case .webp: outputType = "org.webmproject.webp"; suffix = "webp"
        default:
            if sourceType == "org.webmproject.webp" { outputType = sourceType; suffix = "webp" }
            else if sourceType == UTType.jpeg.identifier { outputType = sourceType; suffix = "jpg" }
            else if sourceType == UTType.png.identifier { outputType = sourceType; suffix = "png" }
            else if sourceType == UTType.heic.identifier || sourceType == "public.heif" { outputType = UTType.heic.identifier; suffix = "heic" }
            else if sourceType == UTType.tiff.identifier, action != .compressImage { outputType = sourceType; suffix = "tiff" }
            else { throw OrbitError.unsupported("Choose JPEG, PNG, HEIC, or WebP output for this image format.") }
        }
        if action == .removeGPS, outputType == "org.webmproject.webp" {
            throw OrbitError.unsupported("Use Remove Metadata for WebP. Selective WebP metadata preservation is not available.")
        }
        if outputType != "org.webmproject.webp" {
            let destinations = CGImageDestinationCopyTypeIdentifiers() as! [String]
            guard destinations.contains(outputType) else { throw OrbitError.unsupported("This Mac cannot encode \(suffix.uppercased()) images.") }
        }
        let image = try loadUpright(item.url, maxPixelSize: action == .resize1600 ? 1600 : nil)
        var properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any] ?? [:]
        if action == .removeMetadata { properties = [:] }
        if action == .removeGPS { properties.removeValue(forKey: kCGImagePropertyGPSDictionary as String) }
        // Decoded images carry their display color space. An upright raster no longer needs EXIF rotation.
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyPixelWidth as String] = image.width
        properties[kCGImagePropertyPixelHeight as String] = image.height
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = image.width
            exif[kCGImagePropertyExifPixelYDimension as String] = image.height
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        let quality = min(1, max(0.1, context.quality.isFinite ? context.quality : 0.82))
        properties[kCGImageDestinationLossyCompressionQuality as String] = quality
        let label: String
        switch action {
        case .compressImage: label = "compressed"
        case .resize1600: label = "1600px"
        case .removeMetadata: label = "private"
        case .removeGPS: label = "no-gps"
        default: label = "converted"
        }
        let originalSize = try byteCount(item.url)
        return try OutputTransaction.write(source: item.url, outputDirectory: context.outputDirectory,
                                           stem: item.url.deletingPathExtension().lastPathComponent + "-" + label, extension: suffix,
                                           writer: { destination in
            try Task.checkCancellation()
            if outputType == "org.webmproject.webp" {
                try writeWebP(image, to: destination, quality: quality)
            } else {
                guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, outputType as CFString, 1, nil) else {
                    throw OrbitError.failed("Cannot create the image output.")
                }
                let raster = outputType == UTType.jpeg.identifier ? try flattened(image) : image
                CGImageDestinationAddImage(writer, raster, properties as CFDictionary)
                guard CGImageDestinationFinalize(writer) else { throw OrbitError.failed("The image encoder did not finish.") }
            }
            try Task.checkCancellation()
        }, validate: { destination in
            try verifyImage(destination, expectedWidth: image.width, expectedHeight: image.height)
            if action == .compressImage, try byteCount(destination) >= originalSize {
                throw OrbitError.unsupported("This image is already compact at the chosen quality. Try WebP, JPEG, or Resize instead.")
            }
            if action == .removeGPS, outputType != "org.webmproject.webp",
               let check = CGImageSourceCreateWithURL(destination as CFURL, nil),
               let tags = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [String: Any],
               tags[kCGImagePropertyGPSDictionary as String] != nil {
                throw OrbitError.failed("Location metadata could not be removed.")
            }
        })
    }

    /// Decodes one still image, applies its orientation, and optionally downsamples during decode.
    static func loadUpright(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        try Task.checkCancellation()
        guard try byteCount(url) <= 512 * 1024 * 1024 else { throw OrbitError.unsupported("Images larger than 512 MB need a dedicated editor.") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return try loadWebP(url, maxPixelSize: maxPixelSize)
        }
        guard CGImageSourceGetCount(source) == 1 else { throw OrbitError.unsupported("Animated and multi-page images are not flattened. Choose a still image.") }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else {
            throw OrbitError.invalidInput("Cannot read image dimensions: \(url.lastPathComponent)")
        }
        let w = width.intValue, h = height.intValue
        guard w > 0, h > 0, w <= 100_000, h <= 100_000,
              Double(w) * Double(h) <= (maxPixelSize == nil ? 40_000_000 : 250_000_000) else {
            throw OrbitError.unsupported("This image exceeds Orbit's safe decode limit. Use Resize for large photographs.")
        }
        let maximum = min(max(w, h), maxPixelSize ?? max(w, h))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maximum,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw OrbitError.invalidInput("Cannot decode \(url.lastPathComponent).")
        }
        return image
    }

    private static func flattened(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw OrbitError.failed("Not enough memory to prepare this image.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let result = context.makeImage() else { throw OrbitError.failed("Cannot flatten image transparency.") }
        return result
    }

    private static func writeWebP(_ image: CGImage, to url: URL, quality: Double) throws {
        let stride = image.width * 4
        var rgba = [UInt8](repeating: 0, count: stride * image.height)
        let encoded: Data = try rgba.withUnsafeMutableBytes { raw in
            guard let raster = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                         bitsPerComponent: 8, bytesPerRow: stride,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw OrbitError.failed("Cannot prepare WebP pixels.")
            }
            raster.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            let bytes = raw.bindMemory(to: UInt8.self)
            // libwebp expects straight RGBA; Core Graphics draws premultiplied RGBA.
            for offset in Swift.stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Int(bytes[offset + 3])
                if alpha > 0, alpha < 255 {
                    for channel in 0..<3 { bytes[offset + channel] = UInt8(min(255, (Int(bytes[offset + channel]) * 255 + alpha / 2) / alpha)) }
                }
            }
            try Task.checkCancellation()
            var output: UnsafeMutablePointer<UInt8>?
            let count = WebPEncodeRGBA(bytes.baseAddress, Int32(image.width), Int32(image.height), Int32(stride), Float(quality * 100), &output)
            guard count > 0, let output else { throw OrbitError.failed("WebP encoding failed.") }
            defer { WebPFree(output) }
            return Data(bytes: output, count: count)
        }
        try encoded.write(to: url)
    }

    private static func loadWebP(_ url: URL, maxPixelSize: Int?) throws -> CGImage {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var width: Int32 = 0, height: Int32 = 0
            guard WebPGetInfo(bytes.baseAddress, data.count, &width, &height) != 0,
                  width > 0, height > 0, Int64(width) * Int64(height) <= 40_000_000 else {
                throw OrbitError.invalidInput("This file is not a supported still image: \(url.lastPathComponent)")
            }
            // The animation bit in VP8X is explicit. libwebp's simple decoder would otherwise flatten it.
            if data.count > 20, data.subdata(in: 12..<16) == Data("VP8X".utf8), data[20] & 0x02 != 0 {
                throw OrbitError.unsupported("Animated WebP images are not flattened.")
            }
            guard let decoded = WebPDecodeRGBA(bytes.baseAddress, data.count, &width, &height) else {
                throw OrbitError.invalidInput("Cannot decode this WebP image.")
            }
            defer { WebPFree(decoded) }
            let pixelData = Data(bytes: decoded, count: Int(width) * Int(height) * 4)
            guard let provider = CGDataProvider(data: pixelData as CFData),
                  let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: Int(width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw OrbitError.failed("Cannot create WebP image pixels.")
            }
            guard let maximum = maxPixelSize, max(image.width, image.height) > maximum else { return image }
            let scale = Double(maximum) / Double(max(image.width, image.height))
            let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: image.colorSpace!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw OrbitError.failed("Cannot resize the WebP image.")
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            guard let resized = context.makeImage() else { throw OrbitError.failed("Cannot resize the WebP image.") }
            return resized
        }
    }

    static func verifyImage(_ url: URL, expectedWidth: Int, expectedHeight: Int) throws {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
           let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
           decoded.width == expectedWidth, decoded.height == expectedHeight { return }
        let decoded = try loadWebP(url, maxPixelSize: nil)
        guard decoded.width == expectedWidth, decoded.height == expectedHeight else { throw OrbitError.failed("Output dimensions failed verification.") }
    }

    static func byteCount(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func totalBytes(_ urls: [URL]) throws -> Int64 { try urls.reduce(0) { try $0 + byteCount($1) } }
}
