import Foundation

public enum SyncPortableSection: String, CaseIterable, Sendable { case launcher, workflows, palettes, snippets, habits, shelves }

/// Logical launch targets are portable. Filesystem paths and security-scoped bookmarks are never encoded here.
public struct SyncLauncherPin: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var label: String
    public let kind: PlusLauncherKind
    public let targetIdentifier: String
    public init(id: UUID, label: String, kind: PlusLauncherKind, targetIdentifier: String) {
        self.id = id; self.label = label; self.kind = kind; self.targetIdentifier = targetIdentifier
    }
    public func validate() throws {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 120,
              label.rangeOfCharacter(from: .controlCharacters) == nil else { throw SyncFailure.invalid("Invalid portable launcher label.") }
        switch kind {
        case .application:
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
            guard targetIdentifier.count <= 255, targetIdentifier.contains("."), !targetIdentifier.hasPrefix("."),
                  !targetIdentifier.hasSuffix("."), !targetIdentifier.contains(".."),
                  targetIdentifier.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw SyncFailure.invalid("A synced application needs a bundle identifier, never a file path.")
            }
        case .folder:
            guard UUID(uuidString: targetIdentifier) == id else { throw SyncFailure.invalid("A synced folder must use its logical pin identity and be resolved separately on each Mac.") }
        case .shortcut:
            guard UUID(uuidString: targetIdentifier) != nil else { throw SyncFailure.invalid("A synced shortcut needs a Shortcuts identifier.") }
        }
    }
    public static func validate(_ pins: [Self]) throws {
        let targets = pins.map { $0.kind.rawValue + ":" + $0.targetIdentifier.lowercased() }
        guard pins.count <= 256, Set(pins.map(\.id)).count == pins.count, Set(targets).count == pins.count else {
            throw SyncFailure.invalid("Portable launcher pins exceed 256 items or duplicate targets/identities.")
        }
        for pin in pins { try pin.validate() }
    }
}

public struct SyncPortableLibrary: Codable, Equatable, Sendable {
    public var launcherPins: [SyncLauncherPin]
    public var workflows: [WorkflowPreset]
    public var palettes: CoreColorPaletteLibrary
    public var snippets: CoreSnippetLibrary
    public var habits: CoreHabitLibrary
    public var shelves: CoreShelfConfiguration
    public init(launcherPins: [SyncLauncherPin] = [], workflows: [WorkflowPreset] = [], palettes: CoreColorPaletteLibrary? = nil,
                snippets: CoreSnippetLibrary = .init(), habits: CoreHabitLibrary = .init(), shelves: CoreShelfConfiguration = .init()) {
        self.launcherPins = launcherPins; self.workflows = workflows
        self.palettes = palettes ?? (try! CoreColorPaletteLibrary())
        self.snippets = snippets; self.habits = habits; self.shelves = shelves
    }
    private enum CodingKeys: String, CodingKey { case launcherPins, workflows, palettes, snippets, habits, shelves }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(launcherPins: try values.decode([SyncLauncherPin].self, forKey: .launcherPins),
                  workflows: try values.decode([WorkflowPreset].self, forKey: .workflows),
                  palettes: try values.decode(CoreColorPaletteLibrary.self, forKey: .palettes),
                  snippets: try values.decodeIfPresent(CoreSnippetLibrary.self, forKey: .snippets) ?? .init(),
                  habits: try values.decodeIfPresent(CoreHabitLibrary.self, forKey: .habits) ?? .init(),
                  shelves: try values.decodeIfPresent(CoreShelfConfiguration.self, forKey: .shelves) ?? .init())
    }
    public func validate() throws {
        try SyncLauncherPin.validate(launcherPins)
        guard workflows.count <= 24, Set(workflows.map(\.id)).count == workflows.count else { throw SyncFailure.invalid("Use at most 24 unique workflow presets.") }
        for preset in workflows { _ = try preset.validated() }
        _ = try palettes.encoded()
        _ = try snippets.encoded(); _ = try habits.encoded(); _ = try shelves.encoded()
        guard snippets.snippets.allSatisfy(\.allowsSync) else { throw SyncFailure.invalid("Local-only snippets must be excluded from portable sync.") }
    }
}
