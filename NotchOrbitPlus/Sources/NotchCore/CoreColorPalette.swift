import Foundation

public enum CoreColorPaletteError: LocalizedError, Equatable, Sendable {
    case invalidComponent, invalidName, tooManyColors, tooManyPalettes, duplicateIdentifier, invalidSchema, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidComponent: "Color components must be finite sRGB values between 0 and 1."
        case .invalidName: "Use a palette name of 1–80 characters without control characters."
        case .tooManyColors: "A palette can hold up to 64 colors."
        case .tooManyPalettes: "You can save up to 32 palettes."
        case .duplicateIdentifier: "Palette identifiers must be unique."
        case .invalidSchema: "This color palette format is not supported."
        case .tooLarge: "The color palette file is too large."
        }
    }
}

public enum CoreColorFormat: String, CaseIterable, Identifiable, Sendable {
    case hex, rgb, hsl, swiftUI, nsColor
    public var id: String { rawValue }
    public var title: String {
        switch self { case .hex: "HEX"; case .rgb: "RGB"; case .hsl: "HSL"; case .swiftUI: "SwiftUI"; case .nsColor: "NSColor" }
    }
}

/// Normalized, non-premultiplied components in the standard sRGB color space.
public struct CoreColorRGBA: Codable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) throws {
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw CoreColorPaletteError.invalidComponent
        }
        self.red = red == 0 ? 0 : red; self.green = green == 0 ? 0 : green
        self.blue = blue == 0 ? 0 : blue; self.alpha = alpha == 0 ? 0 : alpha
    }
    private enum CodingKeys: String, CodingKey { case red, green, blue, alpha }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(red: values.decode(Double.self, forKey: .red), green: values.decode(Double.self, forKey: .green),
                      blue: values.decode(Double.self, forKey: .blue), alpha: values.decode(Double.self, forKey: .alpha))
    }
    public var hex: String {
        let channels = alpha == 1 ? [red, green, blue] : [red, green, blue, alpha]
        return "#" + channels.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }
    public func formatted(_ format: CoreColorFormat) -> String {
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
        switch format {
        case .hex: return hex
        case .rgb:
            return alpha == 1 ? "rgb(\(r), \(g), \(b))" : "rgba(\(r), \(g), \(b), \(Self.decimal(alpha)))"
        case .hsl:
            let upper = max(red, green, blue), lower = min(red, green, blue), delta = upper - lower
            let lightness = (upper + lower) / 2
            let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
            var hue = 0.0
            if delta > 0 {
                if upper == red { hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
                else if upper == green { hue = (blue - red) / delta + 2 }
                else { hue = (red - green) / delta + 4 }
                hue *= 60
                if hue < 0 { hue += 360 }
            }
            let components = "\(Self.decimal(hue)), \(Self.decimal(saturation * 100))%, \(Self.decimal(lightness * 100))%"
            return alpha == 1 ? "hsl(\(components))" : "hsla(\(components), \(Self.decimal(alpha)))"
        case .swiftUI:
            return "Color(.sRGB, red: \(Self.decimal(red)), green: \(Self.decimal(green)), blue: \(Self.decimal(blue)), opacity: \(Self.decimal(alpha)))"
        case .nsColor:
            return "NSColor(srgbRed: \(Self.decimal(red)), green: \(Self.decimal(green)), blue: \(Self.decimal(blue)), alpha: \(Self.decimal(alpha)))"
        }
    }
    private static func decimal(_ value: Double) -> String {
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), rounded == 0 ? 0 : rounded)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }
}

public struct CoreColorPalette: Codable, Identifiable, Equatable, Sendable {
    public static let maximumColors = 64
    public static let maximumNameCharacters = 80
    public let id: UUID
    public let name: String
    public let colors: [CoreColorRGBA]
    public init(id: UUID = UUID(), name: String, colors: [CoreColorRGBA] = []) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.maximumNameCharacters,
              name.unicodeScalars.count <= Self.maximumNameCharacters * 4,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CoreColorPaletteError.invalidName
        }
        guard colors.count <= Self.maximumColors else { throw CoreColorPaletteError.tooManyColors }
        self.id = id; self.name = name; self.colors = colors
    }
    private enum CodingKeys: String, CodingKey { case id, name, colors }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      colors: values.decode([CoreColorRGBA].self, forKey: .colors))
    }
}

/// Sync payload deliberately contains saved palettes, never local sampling history.
public struct CoreColorPaletteLibrary: Codable, Equatable, Sendable {
    public static let maximumPalettes = 32
    public static let maximumBytes = 512 * 1_024
    public let schemaVersion: Int
    public let palettes: [CoreColorPalette]
    public init(palettes: [CoreColorPalette] = []) throws {
        guard palettes.count <= Self.maximumPalettes else { throw CoreColorPaletteError.tooManyPalettes }
        guard Set(palettes.map(\.id)).count == palettes.count else { throw CoreColorPaletteError.duplicateIdentifier }
        schemaVersion = 1; self.palettes = palettes
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, palettes }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else { throw CoreColorPaletteError.invalidSchema }
        try self.init(palettes: values.decode([CoreColorPalette].self, forKey: .palettes))
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw CoreColorPaletteError.tooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw CoreColorPaletteError.tooLarge }
        return data
    }
}

public struct CoreColorPickerState: Codable, Equatable, Sendable {
    public static let maximumHistory = 80
    public let schemaVersion: Int
    public let history: [CoreColorRGBA]
    public let library: CoreColorPaletteLibrary
    public init(history: [CoreColorRGBA] = [], library: CoreColorPaletteLibrary) throws {
        guard history.count <= Self.maximumHistory else { throw CoreColorPaletteError.tooManyColors }
        self.schemaVersion = 1; self.history = history; self.library = library
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, history, library }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else { throw CoreColorPaletteError.invalidSchema }
        try self.init(history: values.decode([CoreColorRGBA].self, forKey: .history),
                      library: values.decode(CoreColorPaletteLibrary.self, forKey: .library))
    }
}
