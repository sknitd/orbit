import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Vision
import UniformTypeIdentifiers
import OrbitCore

struct PDFEngine: ActionEngine {
    func perform(_ action: ActionID, items: [FileItem], context: ActionContext) async throws -> ActionResult {
        let work = Task.detached(priority: .userInitiated) { try Self.process(action, items: items, context: context) }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private static func process(_ action: ActionID, items: [FileItem], context: ActionContext) throws -> ActionResult {
        guard !items.isEmpty else { throw OrbitError.invalidInput("Choose files to process.") }
        var outputs = [URL]()
        do {
            switch action {
            case .imagesToPDF:
                guard items.allSatisfy({ $0.kind == .image }) else { throw OrbitError.invalidInput("Create PDF requires images.") }
                let first = items[0].url
                let output = try OutputTransaction.write(source: first, outputDirectory: context.outputDirectory,
                                                         stem: first.deletingPathExtension().lastPathComponent + "-images", extension: "pdf",
                                                         writer: { destination in try writeImagesPDF(items, to: destination, context: context) },
                                                         validate: { destination in try verifyPDF(destination, pageCount: items.count) })
                outputs.append(output)
            case .mergePDF:
                guard items.count >= 2, items.allSatisfy({ $0.kind == .pdf }) else { throw OrbitError.invalidInput("Merge requires at least two PDFs.") }
                guard try ImageEngine.totalBytes(items.map(\.url)) <= 1_024 * 1024 * 1024 else {
                    throw OrbitError.unsupported("Merge is limited to 1 GB of source PDFs per operation.")
                }
                let result = PDFDocument()
                for (index, item) in items.enumerated() {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        let source = try openPDF(item.url)
                        guard result.pageCount + source.pageCount <= 2_000 else { throw OrbitError.unsupported("Merge is limited to 2,000 pages per output.") }
                        for pageIndex in 0..<source.pageCount {
                            try Task.checkCancellation()
                            guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else { throw OrbitError.failed("Cannot read PDF page \(pageIndex + 1).") }
                            result.insert(page, at: result.pageCount)
                            let fraction = (Double(index) + Double(pageIndex + 1) / Double(source.pageCount)) / Double(items.count + 1)
                            context.progress(fraction, "Adding page \(pageIndex + 1) of \(source.pageCount)")
                        }
                    }
                    context.progress(Double(index + 1) / Double(items.count + 1), "Adding \(item.url.lastPathComponent)")
                }
                let output = try writePDF(result, source: items[0].url, stem: "Merged", context: context)
                outputs.append(output)
            case .splitPDF, .pdfToPNG:
                guard items.allSatisfy({ $0.kind == .pdf }) else { throw OrbitError.invalidInput("Choose PDF files.") }
                for (itemIndex, item) in items.enumerated() {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        let document = try openPDF(item.url)
                        for pageIndex in 0..<document.pageCount {
                            try Task.checkCancellation()
                            let output = try autoreleasepool { () throws -> URL in
                                guard let page = document.page(at: pageIndex) else { throw OrbitError.failed("Cannot read PDF page \(pageIndex + 1).") }
                                let stem = item.url.deletingPathExtension().lastPathComponent + "-page-" + String(format: "%03d", pageIndex + 1)
                                if action == .splitPDF {
                                    let single = PDFDocument()
                                    guard let copied = page.copy() as? PDFPage else { throw OrbitError.failed("Cannot copy PDF page.") }
                                    single.insert(copied, at: 0)
                                    return try writePDF(single, source: item.url, stem: stem, context: context)
                                }
                                let image = try render(page)
                                return try OutputTransaction.write(source: item.url, outputDirectory: context.outputDirectory, stem: stem, extension: "png",
                                                                   writer: { destination in
                                    try Task.checkCancellation()
                                    guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                                        throw OrbitError.failed("Cannot create page image.")
                                    }
                                    CGImageDestinationAddImage(writer, image, nil)
                                    guard CGImageDestinationFinalize(writer) else { throw OrbitError.failed("PNG encoding did not finish.") }
                                }, validate: { destination in try ImageEngine.verifyImage(destination, expectedWidth: image.width, expectedHeight: image.height) })
                            }
                            outputs.append(output)
                            let fraction = (Double(itemIndex) + Double(pageIndex + 1) / Double(document.pageCount)) / Double(items.count)
                            context.progress(fraction, "Page \(pageIndex + 1) of \(document.pageCount)")
                        }
                    }
                }
            case .ocr:
                guard items.allSatisfy({ $0.kind == .image || $0.kind == .pdf }) else { throw OrbitError.invalidInput("Text recognition supports images and PDFs.") }
                for (index, item) in items.enumerated() {
                    try Task.checkCancellation()
                    let output = try autoreleasepool { () throws -> URL in
                        let text = try extractText(item, itemIndex: index, itemCount: items.count, context: context)
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw OrbitError.failed("No readable text was found in \(item.url.lastPathComponent).")
                        }
                        return try OutputTransaction.write(source: item.url, outputDirectory: context.outputDirectory,
                                                           stem: item.url.deletingPathExtension().lastPathComponent + "-text", extension: "txt",
                                                           writer: { destination in
                            try Task.checkCancellation()
                            try Data(text.utf8).write(to: destination)
                        }, validate: { destination in
                            guard try String(contentsOf: destination, encoding: .utf8) == text else { throw OrbitError.failed("Text output failed verification.") }
                        })
                    }
                    outputs.append(output)
                    context.progress(Double(index + 1) / Double(items.count), "Text extracted")
                }
            default: throw OrbitError.unsupported("That PDF action is not available.")
            }
            try Task.checkCancellation()
            context.progress(1, "Files ready")
            return ActionResult(outputs: outputs, inputBytes: items.reduce(0) { $0 + $1.byteCount }, outputBytes: try ImageEngine.totalBytes(outputs))
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output) }
            throw error
        }
    }

    private static func openPDF(_ url: URL) throws -> PDFDocument {
        guard try ImageEngine.byteCount(url) <= 512 * 1024 * 1024 else { throw OrbitError.unsupported("PDFs larger than 512 MB need a dedicated editor.") }
        guard let document = PDFDocument(url: url) else { throw OrbitError.invalidInput("Cannot open \(url.lastPathComponent) as a PDF.") }
        guard !document.isLocked else { throw OrbitError.invalidInput("\(url.lastPathComponent) is password-protected. Unlock a copy in Preview first.") }
        guard document.pageCount > 0 else { throw OrbitError.invalidInput("This PDF has no pages: \(url.lastPathComponent)") }
        guard document.pageCount <= 2_000 else { throw OrbitError.unsupported("PDF processing is limited to 2,000 pages per file.") }
        return document
    }

    private static func writePDF(_ document: PDFDocument, source: URL, stem: String, context: ActionContext) throws -> URL {
        try OutputTransaction.write(source: source, outputDirectory: context.outputDirectory, stem: stem, extension: "pdf", writer: { destination in
            try Task.checkCancellation()
            guard document.write(to: destination) else { throw OrbitError.failed("PDF writing did not finish.") }
            try Task.checkCancellation()
        }, validate: { destination in try verifyPDF(destination, pageCount: document.pageCount) })
    }

    private static func verifyPDF(_ url: URL, pageCount: Int) throws {
        guard let document = CGPDFDocument(url as CFURL), !document.isEncrypted || document.isUnlocked,
              document.numberOfPages == pageCount, pageCount > 0 else { throw OrbitError.failed("PDF output failed verification.") }
        for index in 1...pageCount {
            guard let page = document.page(at: index) else { throw OrbitError.failed("A generated PDF page could not be decoded.") }
            let box = page.getBoxRect(.mediaBox)
            guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { throw OrbitError.failed("The PDF has invalid page dimensions.") }
        }
    }

    private static func writeImagesPDF(_ items: [FileItem], to url: URL, context: ActionContext) throws {
        guard items.count <= 2_000 else { throw OrbitError.unsupported("PDF creation is limited to 2,000 images.") }
        guard let consumer = CGDataConsumer(url: url as CFURL), let writer = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw OrbitError.failed("Cannot create PDF output.")
        }
        defer { writer.closePDF() }
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let image = try ImageEngine.loadUpright(item.url)
                let scale = min(1, 1440 / Double(max(image.width, image.height)))
                var page = CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale)
                let pageInfo = [kCGPDFContextMediaBox as String: NSData(bytes: &page, length: MemoryLayout<CGRect>.size)]
                writer.beginPDFPage(pageInfo as CFDictionary)
                writer.setFillColor(CGColor(gray: 1, alpha: 1))
                writer.fill(page)
                writer.draw(image, in: page)
                writer.endPDFPage()
            }
            context.progress(Double(index + 1) / Double(items.count), "Adding image \(index + 1) of \(items.count)")
        }
        try Task.checkCancellation()
    }

    /// Renders at 144 dpi, with a 4,096-pixel edge / 16-megapixel cap for hostile page boxes.
    private static func render(_ page: PDFPage) throws -> CGImage {
        try Task.checkCancellation()
        let box = page.bounds(for: .mediaBox)
        guard box.width.isFinite, box.height.isFinite, box.minX.isFinite, box.minY.isFinite,
              box.width > 0, box.height > 0, box.width <= 1_000_000, box.height <= 1_000_000 else {
            throw OrbitError.invalidInput("This PDF page has invalid dimensions.")
        }
        let sideways = ((page.rotation % 360) + 360) % 180 == 90
        let displayWidth = sideways ? box.height : box.width
        let displayHeight = sideways ? box.width : box.height
        let scale = min(2, min(4096 / max(displayWidth, displayHeight), sqrt(16_000_000 / (displayWidth * displayHeight))))
        let width = max(1, Int((displayWidth * scale).rounded(.up))), height = max(1, Int((displayHeight * scale).rounded(.up)))
        guard let raster = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw OrbitError.failed("Not enough memory to render this page.")
        }
        raster.setFillColor(CGColor(gray: 1, alpha: 1))
        raster.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        raster.scaleBy(x: scale, y: scale)
        // PDFKit's drawing method applies both page rotation and the selected box's origin.
        page.draw(with: .mediaBox, to: raster)
        try Task.checkCancellation()
        guard let image = raster.makeImage() else { throw OrbitError.failed("Cannot render PDF page.") }
        return image
    }

    private static func extractText(_ item: FileItem, itemIndex: Int, itemCount: Int, context: ActionContext) throws -> String {
        if item.kind == .image { return try recognize(ImageEngine.loadUpright(item.url, maxPixelSize: 4096)) }
        let document = try openPDF(item.url)
        var pages = [String]()
        var totalCharacters = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let text = try autoreleasepool { () throws -> String in
                guard let page = document.page(at: index) else { throw OrbitError.failed("Cannot read PDF page \(index + 1).") }
                if let embedded = page.string, !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return embedded }
                return try recognize(render(page))
            }
            totalCharacters += text.utf8.count
            guard totalCharacters <= 32 * 1024 * 1024 else { throw OrbitError.unsupported("Extracted text exceeds the 32 MB safety limit.") }
            pages.append(text)
            let fraction = (Double(itemIndex) + Double(index + 1) / Double(document.pageCount)) / Double(itemCount)
            context.progress(fraction, "Reading page \(index + 1) of \(document.pageCount)")
        }
        return pages.joined(separator: "\n\n\u{000C}\n\n")
    }

    private static func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.progressHandler = { request, _, _ in if Task.isCancelled { request.cancel() } }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
