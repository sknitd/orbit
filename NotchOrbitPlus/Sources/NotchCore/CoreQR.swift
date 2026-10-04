import Foundation

public enum QRValidationError: Error, LocalizedError, Equatable, Sendable {
    case emptyPayload, payloadTooLarge, invalidScale
    public var errorDescription: String? {
        switch self {
        case .emptyPayload: "Enter text or a URL to encode."
        case .payloadTooLarge: "QR generation accepts up to 1,024 UTF-8 bytes. Shorten the text first."
        case .invalidScale: "Choose an integer QR scale from 4 to 16."
        }
    }
}

public enum QRCorrectionLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    case low = "L", medium = "M", quartile = "Q", high = "H"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .low: "Low · 7%"
        case .medium: "Medium · 15%"
        case .quartile: "Quartile · 25%"
        case .high: "High · 30%"
        }
    }
}

/// Integer module scaling and a four-module quiet zone keep exported PNGs readable.
public struct QREncodingOptions: Codable, Equatable, Sendable {
    public static let quietZoneModules = 4
    public let correction: QRCorrectionLevel
    public let scale: Int
    public init(correction: QRCorrectionLevel = .medium, scale: Int = 8) throws {
        guard (4...16).contains(scale) else { throw QRValidationError.invalidScale }
        self.correction = correction; self.scale = scale
    }
    private enum CodingKeys: String, CodingKey { case correction, scale }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(correction: values.decode(QRCorrectionLevel.self, forKey: .correction),
                      scale: values.decode(Int.self, forKey: .scale))
    }
}

public struct QRGenerationRequest: Codable, Equatable, Sendable {
    /// Fits every supported correction level, including multibyte text.
    public static let maximumPayloadBytes = 1_024
    public let payload: String
    public let options: QREncodingOptions
    public var utf8Data: Data { Data(payload.utf8) }
    public init(payload: String, options: QREncodingOptions = try! .init()) throws {
        guard !payload.isEmpty else { throw QRValidationError.emptyPayload }
        guard payload.utf8.count <= Self.maximumPayloadBytes else { throw QRValidationError.payloadTooLarge }
        self.payload = payload; self.options = options
    }
    private enum CodingKeys: String, CodingKey { case payload, options }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(payload: values.decode(String.self, forKey: .payload),
                      options: values.decode(QREncodingOptions.self, forKey: .options))
    }
}
