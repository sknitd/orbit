import Foundation

public enum Corner: String, CaseIterable, Codable, Hashable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    public var title: String {
        switch self { case .topLeft: "Top Left"; case .topRight: "Top Right"; case .bottomLeft: "Bottom Left"; case .bottomRight: "Bottom Right" }
    }
}
public enum CornerGesture: String, CaseIterable, Codable, Hashable, Sendable {
    case singleClick, doubleClick, tripleClick, dragIntoCorner, dragOutOfCorner
    public var title: String {
        switch self {
        case .singleClick: "Single Click"
        case .doubleClick: "Double Click"
        case .tripleClick: "Triple Click"
        case .dragIntoCorner: "Drag Into Corner"
        case .dragOutOfCorner: "Drag Out of Corner"
        }
    }
}

public struct CornerModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = CornerModifiers(rawValue: 1 << 0)
    public static let control = CornerModifiers(rawValue: 1 << 1)
    public static let option = CornerModifiers(rawValue: 1 << 2)
    public static let command = CornerModifiers(rawValue: 1 << 3)
    public static let all: CornerModifiers = [.shift, .control, .option, .command]
    public init(from decoder: any Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(UInt8.self)) }
    public func encode(to encoder: any Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(rawValue) }
}

public struct CornerConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var bindings: [CornerGesture: CornerAction]
    public init(enabled: Bool = true, bindings: [CornerGesture: CornerAction] = [:]) {
        self.enabled = enabled
        self.bindings = Dictionary(uniqueKeysWithValues: CornerGesture.allCases.map { ($0, bindings[$0] ?? .none) })
    }
    public func action(for gesture: CornerGesture) -> CornerAction { bindings[gesture] ?? .none }
    private enum CodingKeys: String, CodingKey { case enabled, bindings }
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try box.decode(Bool.self, forKey: .enabled)
        let raw = try box.decode([String: CornerAction].self, forKey: .bindings)
        guard raw.keys.allSatisfy({ CornerGesture(rawValue: $0) != nil }) else {
            throw CornerActionError.invalid("Settings contain an unknown corner gesture.")
        }
        bindings = Dictionary(uniqueKeysWithValues: CornerGesture.allCases.map { ($0, raw[$0.rawValue] ?? .none) })
    }
    public func encode(to encoder: any Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(enabled, forKey: .enabled)
        try box.encode(Dictionary(uniqueKeysWithValues: CornerGesture.allCases.map { ($0.rawValue, action(for: $0)) }), forKey: .bindings)
    }
}

public struct CornerSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var enabled: Bool
    public var corners: [Corner: CornerConfiguration]
    public var cornerSize: Double
    public var clickInterval: Double
    public var dragThreshold: Double
    public var cooldown: Double
    public var modifierRequirement: CornerModifiers
    /// Empty permits every display; a nonempty set permits only these stable IDs.
    public var enabledDisplayIDs: Set<String>
    public init(schemaVersion: Int = 1, enabled: Bool = false,
                corners: [Corner: CornerConfiguration] = [:], cornerSize: Double = 24,
                clickInterval: Double = 0.32, dragThreshold: Double = 12, cooldown: Double = 0.6,
                modifierRequirement: CornerModifiers = [], enabledDisplayIDs: Set<String> = []) {
        self.schemaVersion = schemaVersion; self.enabled = enabled
        self.corners = Dictionary(uniqueKeysWithValues: Corner.allCases.map { ($0, corners[$0] ?? .init()) })
        self.cornerSize = cornerSize; self.clickInterval = clickInterval; self.dragThreshold = dragThreshold
        self.cooldown = cooldown; self.modifierRequirement = modifierRequirement; self.enabledDisplayIDs = enabledDisplayIDs
    }
    public static let defaults = CornerSettings()
    /// A preset is data only. Applying it and enabling monitoring are separate user choices.
    public static var samplePreset: CornerSettings {
        var value = defaults
        value.corners[.topLeft]?.bindings[.singleClick] = .init(kind: .chromeNewTab)
        value.corners[.topLeft]?.bindings[.doubleClick] = .init(kind: .recentWebsites)
        value.corners[.topRight]?.bindings[.singleClick] = .init(kind: .chatGPT)
        value.corners[.bottomLeft]?.bindings[.singleClick] = .init(kind: .finder)
        value.corners[.bottomRight]?.bindings[.singleClick] = .init(kind: .activityMonitor)
        return value
    }
    public func action(for trigger: CornerTrigger) -> CornerAction { corners[trigger.corner]?.action(for: trigger.gesture) ?? .none }
    public func permits(displayID: String) -> Bool { enabledDisplayIDs.isEmpty || enabledDisplayIDs.contains(displayID) }
    public func validated() throws -> CornerSettings {
        guard schemaVersion == Self.currentSchemaVersion else { throw CornerActionError.invalid("This settings schema is not supported.") }
        guard cornerSize.isFinite, (4...128).contains(cornerSize) else { throw CornerActionError.invalid("Corner size must be 4–128 points.") }
        guard clickInterval.isFinite, (0.15...1).contains(clickInterval) else { throw CornerActionError.invalid("Click interval must be 0.15–1 seconds.") }
        guard dragThreshold.isFinite, (2...100).contains(dragThreshold) else { throw CornerActionError.invalid("Drag threshold must be 2–100 points.") }
        guard cooldown.isFinite, (0...5).contains(cooldown) else { throw CornerActionError.invalid("Cooldown must be 0–5 seconds.") }
        guard modifierRequirement.subtracting(.all).isEmpty else { throw CornerActionError.invalid("Settings contain an unknown modifier key.") }
        guard enabledDisplayIDs.count <= 32, enabledDisplayIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw CornerActionError.invalid("Choose at most 32 valid display identifiers.")
        }
        var result = self
        for corner in Corner.allCases {
            var configuration = result.corners[corner] ?? .init()
            for gesture in CornerGesture.allCases { configuration.bindings[gesture] = try configuration.action(for: gesture).validated() }
            result.corners[corner] = configuration
        }
        return result
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, enabled, corners, cornerSize, clickInterval, dragThreshold, cooldown, modifierRequirement, enabledDisplayIDs
    }
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try box.decode(Int.self, forKey: .schemaVersion)
        enabled = try box.decode(Bool.self, forKey: .enabled)
        let raw = try box.decode([String: CornerConfiguration].self, forKey: .corners)
        guard raw.keys.allSatisfy({ Corner(rawValue: $0) != nil }) else { throw CornerActionError.invalid("Settings contain an unknown screen corner.") }
        corners = Dictionary(uniqueKeysWithValues: Corner.allCases.map { ($0, raw[$0.rawValue] ?? .init()) })
        cornerSize = try box.decode(Double.self, forKey: .cornerSize)
        clickInterval = try box.decode(Double.self, forKey: .clickInterval)
        dragThreshold = try box.decode(Double.self, forKey: .dragThreshold)
        cooldown = try box.decode(Double.self, forKey: .cooldown)
        modifierRequirement = try box.decode(CornerModifiers.self, forKey: .modifierRequirement)
        enabledDisplayIDs = try box.decode(Set<String>.self, forKey: .enabledDisplayIDs)
        self = try validated()
    }
    public func encode(to encoder: any Encoder) throws {
        let valid = try validated()
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(valid.schemaVersion, forKey: .schemaVersion); try box.encode(valid.enabled, forKey: .enabled)
        try box.encode(Dictionary(uniqueKeysWithValues: Corner.allCases.map { ($0.rawValue, valid.corners[$0]!) }), forKey: .corners)
        try box.encode(valid.cornerSize, forKey: .cornerSize); try box.encode(valid.clickInterval, forKey: .clickInterval)
        try box.encode(valid.dragThreshold, forKey: .dragThreshold); try box.encode(valid.cooldown, forKey: .cooldown)
        try box.encode(valid.modifierRequirement, forKey: .modifierRequirement); try box.encode(valid.enabledDisplayIDs, forKey: .enabledDisplayIDs)
    }
}
public typealias CornerGlobalConfiguration = CornerSettings
