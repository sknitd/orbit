import Foundation

public enum PlusLauncherKind: String, Codable, Sendable, CaseIterable {
    case application, folder, shortcut
}

public struct PlusLauncherPin: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var label: String
    public let kind: PlusLauncherKind
    public var targetIdentifier: String
    public var bookmark: Data?
    public init(id: UUID = UUID(), label: String, kind: PlusLauncherKind, targetIdentifier: String, bookmark: Data? = nil) {
        self.id = id; self.label = label; self.kind = kind
        self.targetIdentifier = targetIdentifier; self.bookmark = bookmark
    }
}

public enum PlusLauncherPins {
    public static func validate(_ pin: PlusLauncherPin) throws {
        let label = pin.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 120, label.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw error("Use a label with 1–120 characters and no control characters.")
        }
        switch pin.kind {
        case .shortcut:
            guard UUID(uuidString: pin.targetIdentifier) != nil, pin.bookmark == nil else {
                throw error("A pinned shortcut must have a valid Shortcuts identifier.")
            }
        case .application, .folder:
            guard pin.targetIdentifier.hasPrefix("/"), pin.targetIdentifier.rangeOfCharacter(from: .controlCharacters) == nil,
                  let bookmark = pin.bookmark, !bookmark.isEmpty, bookmark.count <= 2_097_152 else {
                throw error("A pinned application or folder must have a local file bookmark.")
            }
        }
    }
    public static func encode(_ pins: [PlusLauncherPin]) throws -> Data {
        try validateCollection(pins)
        let data = try JSONEncoder().encode(pins)
        guard data.count <= 8_388_608 else { throw error("Saved launcher data exceeds its supported size.") }
        return data
    }
    public static func decode(_ data: Data) throws -> [PlusLauncherPin] {
        guard data.count <= 8_388_608 else { throw error("Saved launcher data exceeds its supported size.") }
        let pins = try JSONDecoder().decode([PlusLauncherPin].self, from: data)
        try validateCollection(pins)
        return pins
    }
    public static func inserting(_ pin: PlusLauncherPin, into pins: [PlusLauncherPin]) throws -> [PlusLauncherPin] {
        try validate(pin)
        guard !pins.contains(where: { identity($0) == identity(pin) }) else { throw error("This target is already pinned.") }
        let next = pins + [pin]; try validateCollection(next); return next
    }
    public static func moved(_ pins: [PlusLauncherPin], id: UUID, by delta: Int) -> [PlusLauncherPin] {
        guard let from = pins.firstIndex(where: { $0.id == id }), delta != 0 else { return pins }
        let to = delta > 0 ? min(pins.count - 1, from + 1) : max(0, from - 1)
        guard from != to else { return pins }
        var next = pins; let pin = next.remove(at: from); next.insert(pin, at: to); return next
    }
    public static func matches(_ pin: PlusLauncherPin, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || pin.label.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || pin.kind.rawValue.range(of: query, options: .caseInsensitive) != nil
    }
    private static func identity(_ pin: PlusLauncherPin) -> String {
        pin.kind.rawValue + ":" + (pin.kind == .shortcut ? pin.targetIdentifier.uppercased() : pin.targetIdentifier)
    }
    private static func validateCollection(_ pins: [PlusLauncherPin]) throws {
        guard pins.count <= 256, Set(pins.map(\.id)).count == pins.count, Set(pins.map(identity)).count == pins.count else {
            throw error("Launcher pins contain duplicate targets/identities or exceed 256 items.")
        }
        for pin in pins { try validate(pin) }
    }
    private static func error(_ message: String) -> NSError {
        NSError(domain: "NotchOrbitPlus.Launcher", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
