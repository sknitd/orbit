import Foundation

public enum WorkflowFormat: String, Codable, CaseIterable, Sendable {
    case jpeg, png, heic, webp
    public var title: String { rawValue.uppercased() }
}

public enum WorkflowStep: Codable, Hashable, Sendable {
    case resize(maxDimension: Int)
    case convert(format: WorkflowFormat)
    case compress(quality: Double)
    case compressVideo
    case zip

    public var order: Int {
        switch self { case .resize: 0; case .convert: 1; case .compress, .compressVideo: 2; case .zip: 3 }
    }
    public var title: String {
        switch self {
        case .resize(let pixels): "Resize ≤\(pixels) px"
        case .convert(let format): "Convert to \(format.title)"
        case .compress(let quality): quality.isFinite && (0...1).contains(quality)
            ? "Compress at \(Int((quality * 100).rounded()))%" : "Invalid compression quality"
        case .compressVideo: "Smaller H.264 MP4"
        case .zip: "One batch ZIP"
        }
    }
}

public enum WorkflowValidationError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { text } else { nil } }
}

/// Saved workflows have one explicit parameter per step and a stable safe
/// order. A ZIP is the final grouped output; inputs are never replacements.
public struct WorkflowPreset: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var steps: [WorkflowStep]
    public init(id: UUID = UUID(), name: String, steps: [WorkflowStep]) {
        self.id = id; self.name = name; self.steps = steps
    }
    public var summary: String { steps.map(\.title).joined(separator: " → ") }
    public var isVideoWorkflow: Bool { steps.contains(.compressVideo) }
    public static var starter: WorkflowPreset {
        .init(name: "Web bundle", steps: [.resize(maxDimension: 1600), .convert(format: .jpeg), .compress(quality: 0.72), .zip])
    }
    public static var videoStarter: WorkflowPreset {
        .init(name: "Smaller recording", steps: [.compressVideo])
    }
    public func validated() throws -> WorkflowPreset {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        guard !copy.name.isEmpty, copy.name.utf8.count <= 80,
              copy.name != ".", copy.name != "..", copy.name.rangeOfCharacter(from: forbidden) == nil else {
            throw WorkflowValidationError.invalid("Use a preset name of 1–80 bytes without filename separators.")
        }
        guard (1...4).contains(steps.count), zipIsLast else {
            throw WorkflowValidationError.invalid("Choose 1–4 steps; ZIP must be last.")
        }
        if isVideoWorkflow {
            guard steps == [.compressVideo] || steps == [.compressVideo, .zip] else {
                throw WorkflowValidationError.invalid("Video workflows use Compress Video, optionally followed by ZIP. Image and video steps cannot be mixed.")
            }
        }
        guard zip(steps, steps.dropFirst()).allSatisfy({ $0.order < $1.order }) else {
            throw WorkflowValidationError.invalid("Use each step once, in Resize → Convert → Compress → ZIP order.")
        }
        for step in steps {
            switch step {
            case .resize(let size):
                guard (64...12_000).contains(size) else {
                    throw WorkflowValidationError.invalid("Maximum image dimension must be 64–12,000 pixels.")
                }
            case .compress(let quality):
                guard quality.isFinite, (0.1...0.95).contains(quality) else {
                    throw WorkflowValidationError.invalid("Compression quality must be 10–95%.")
                }
                guard !steps.contains(.convert(format: .png)) else {
                    throw WorkflowValidationError.invalid("PNG is lossless. Use JPEG, HEIC, or WebP for a compression quality step.")
                }
                guard !steps.contains(where: { if case .resize = $0 { true } else { false } })
                        || steps.contains(where: { if case .convert = $0 { true } else { false } }) else {
                    throw WorkflowValidationError.invalid("Choose JPEG, HEIC, or WebP conversion after resizing before a quality step.")
                }
            case .convert, .compressVideo, .zip: break
            }
        }
        return copy
    }
    private var zipIsLast: Bool { !steps.dropLast().contains(.zip) }
}
