import Foundation

public enum PlusIntentFailure: LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public enum PlusIntentValidation {
    public static let maximumFileBytes = 100 * 1024 * 1024
    public static func focusMinutes(_ value: Int) throws -> Double {
        guard (1...1_440).contains(value) else { throw PlusIntentFailure.invalid("Choose a focus duration from 1 to 1,440 minutes.") }
        return Double(value)
    }
    public static func filename(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 200, !value.hasPrefix("."),
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value else {
            throw PlusIntentFailure.invalid("The Shortcut file needs a plain filename of at most 200 UTF-8 bytes.")
        }
        return value
    }
    public static func presetID(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value), value == uuid.uuidString else {
            throw PlusIntentFailure.invalid("Choose an existing workflow preset from this Mac.")
        }
        return uuid
    }
}
