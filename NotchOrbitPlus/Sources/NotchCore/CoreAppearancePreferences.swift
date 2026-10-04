import Foundation

public enum PlusTheme: String, Codable, CaseIterable, Sendable { case system, light, dark }
public enum PlusAccent: String, Codable, CaseIterable, Sendable { case system, blue, purple, pink, orange, green, teal, graphite }

/// Portable appearance choices contain no display geometry or macOS permission state.
public struct CoreAppearancePreferences: Codable, Equatable, Sendable {
    public var theme: PlusTheme
    public var accent: PlusAccent
    public var dropSound: Bool
    public init(theme: PlusTheme = .system, accent: PlusAccent = .blue, dropSound: Bool = false) {
        self.theme = theme; self.accent = accent; self.dropSound = dropSound
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4_096 else { throw SyncFailure.invalid("Appearance settings exceed their size limit.") }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
}
