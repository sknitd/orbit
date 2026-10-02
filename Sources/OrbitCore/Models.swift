import Foundation

public enum FileKind: String, Codable, Sendable, CaseIterable {
    case image, pdf, video, audio, archive, json, text, folder, other
}

public struct FileItem: Identifiable, Sendable, Hashable {
    public var id: URL { url }
    public let url: URL
    public let kind: FileKind
    public let byteCount: Int64
    public let typeIdentifier: String
    public let privacySummary: String?
    public init(url: URL, kind: FileKind, byteCount: Int64 = 0, typeIdentifier: String = "", privacySummary: String? = nil) {
        self.url = url; self.kind = kind; self.byteCount = byteCount; self.typeIdentifier = typeIdentifier
        self.privacySummary = privacySummary
    }
}

public enum ActionID: String, Codable, Sendable, CaseIterable {
    case jpeg, png, heic, webp, compressImage, resize1600, removeMetadata, removeGPS
    case imagesToPDF, mergePDF, splitPDF, pdfToPNG
    case videoMP4, compressVideo, extractAudio, audioM4A
    case zip, unzip, checksum, duplicate, formatJSON, minifyJSON, ocr
}

public struct ActionDescriptor: Identifiable, Sendable, Hashable {
    public var id: ActionID
    public var title: String
    public var symbol: String
    public var category: String
    public var detail: String
    public init(_ id: ActionID, _ title: String, _ symbol: String, category: String, detail: String = "") {
        self.id = id; self.title = title; self.symbol = symbol; self.category = category; self.detail = detail
    }
}

public struct ActionResult: Sendable {
    public let outputs: [URL]
    public let inputBytes: Int64
    public let outputBytes: Int64
    public init(outputs: [URL], inputBytes: Int64 = 0, outputBytes: Int64 = 0) {
        self.outputs = outputs; self.inputBytes = inputBytes; self.outputBytes = outputBytes
    }
}

public struct ActionContext: Sendable {
    public let outputDirectory: URL?
    public let quality: Double
    public let progress: @Sendable (Double, String) -> Void
    public init(outputDirectory: URL? = nil, quality: Double = 0.82, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) {
        self.outputDirectory = outputDirectory; self.quality = quality; self.progress = progress
    }
}

public enum OrbitError: Error, LocalizedError, Sendable {
    case unsupported(String), invalidInput(String), failed(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .unsupported(let message), .invalidInput(let message), .failed(let message): message
        case .cancelled: "Operation cancelled."
        }
    }
}

public protocol ActionEngine: Sendable {
    func perform(_ action: ActionID, items: [FileItem], context: ActionContext) async throws -> ActionResult
}
