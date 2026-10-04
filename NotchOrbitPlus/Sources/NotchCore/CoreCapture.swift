import Foundation

public enum CaptureSelectionKind: String, Codable, CaseIterable, Sendable {
    case display, window, area
}

public enum CaptureValidationError: Error, LocalizedError, Equatable, Sendable {
    case invalidArea, invalidScale, invalidDuration, invalidRecord
    public var errorDescription: String? {
        switch self {
        case .invalidArea: "Choose an area at least eight points wide and high inside the display."
        case .invalidScale: "This display has no usable capture dimensions."
        case .invalidDuration: "Choose a recording duration between one and sixty seconds."
        case .invalidRecord: "The saved capture index contains invalid data."
        }
    }
}

/// Display-relative top-left coordinates, matching ScreenCaptureKit sourceRect.
public struct CaptureArea: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct CapturePixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int
}

public enum CaptureGeometry {
    /// Converts a reversible drag in AppKit's bottom-left coordinates and clips to the chosen display.
    public static func area(startX: Double, startY: Double, endX: Double, endY: Double,
                            displayWidth: Double, displayHeight: Double) throws -> CaptureArea {
        let values = [startX, startY, endX, endY, displayWidth, displayHeight]
        guard values.allSatisfy(\.isFinite), displayWidth > 0, displayHeight > 0 else {
            throw CaptureValidationError.invalidArea
        }
        let left = max(0, min(displayWidth, min(startX, endX)))
        let right = max(0, min(displayWidth, max(startX, endX)))
        let bottom = max(0, min(displayHeight, min(startY, endY)))
        let top = max(0, min(displayHeight, max(startY, endY)))
        guard right - left >= 8, top - bottom >= 8 else { throw CaptureValidationError.invalidArea }
        return CaptureArea(x: left, y: displayHeight - top, width: right - left, height: top - bottom)
    }

    public static func pixels(width: Double, height: Double, scale: Double,
                              recording: Bool) throws -> CapturePixelSize {
        guard [width, height, scale].allSatisfy(\.isFinite), width > 0, height > 0,
              scale >= 0.5, scale <= 8, width <= 100_000, height <= 100_000 else {
            throw CaptureValidationError.invalidScale
        }
        let rawWidth = width * scale, rawHeight = height * scale
        let maximumWidth = recording ? 3_840.0 : 16_384.0
        let maximumHeight = recording ? 2_160.0 : 16_384.0
        let pixelLimit = recording ? 3_840.0 * 2_160.0 : 32_000_000.0
        let factor = min(1, maximumWidth / rawWidth, maximumHeight / rawHeight,
                         sqrt(pixelLimit / (rawWidth * rawHeight)))
        let quantum = recording ? 2 : 1
        let outputWidth = max(quantum, Int(floor(rawWidth * factor)) / quantum * quantum)
        let outputHeight = max(quantum, Int(floor(rawHeight * factor)) / quantum * quantum)
        return CapturePixelSize(width: outputWidth, height: outputHeight)
    }

    public static func duration(_ seconds: Double) throws -> Double {
        guard seconds.isFinite, seconds >= 1, seconds <= 60 else { throw CaptureValidationError.invalidDuration }
        return seconds
    }
}

public struct CaptureShelfRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let createdAt: Date
    public let selection: CaptureSelectionKind
    public let width: Int
    public let height: Int
    public let duration: Double?
    public let byteCount: Int64
    public init(id: UUID = UUID(), fileURL: URL, createdAt: Date = Date(), selection: CaptureSelectionKind,
                width: Int, height: Int, duration: Double? = nil, byteCount: Int64) {
        self.id = id; self.fileURL = fileURL; self.createdAt = createdAt; self.selection = selection
        self.width = width; self.height = height; self.duration = duration; self.byteCount = byteCount
    }
    public func validated() throws -> Self {
        guard fileURL.isFileURL, (fileURL.host ?? "").isEmpty || fileURL.host == "localhost",
              (duration == nil ? ["png"] : ["mov", "mp4"]).contains(fileURL.pathExtension.lowercased()),
              (1...16_384).contains(width), (1...16_384).contains(height),
              Int64(width) * Int64(height) <= 32_000_000,
              byteCount > 0, byteCount <= 512 * 1_024 * 1_024,
              createdAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince1970 >= 0 else {
            throw CaptureValidationError.invalidRecord
        }
        if let duration { guard duration.isFinite, duration > 0, duration <= 65 else { throw CaptureValidationError.invalidRecord } }
        return self
    }
}

public struct CaptureShelfArchive: Codable, Equatable, Sendable {
    public var records: [CaptureShelfRecord]
    public init(records: [CaptureShelfRecord] = []) { self.records = records }
    private enum CodingKeys: String, CodingKey { case records }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decode([CaptureShelfRecord].self, forKey: .records)
        _ = try validated()
    }
    public func validated() throws -> Self {
        guard records.count <= 50, Set(records.map(\.id)).count == records.count,
              Set(records.map(\.fileURL)).count == records.count else { throw CaptureValidationError.invalidRecord }
        return .init(records: try records.map { try $0.validated() })
    }
}
