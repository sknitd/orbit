import Foundation

public struct CornerProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: CornerSettings
    public init(id: UUID = UUID(), name: String, settings: CornerSettings) {
        self.id = id; self.name = name; self.settings = settings; self.settings.enabled = false
    }
    public func validated() throws -> CornerProfile {
        var result = self
        result.name = try CornerProfileValidation.name(name)
        result.settings = try settings.validated(); result.settings.enabled = false
        return result
    }
    private enum CodingKeys: String, CodingKey { case id, name, settings }
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id); name = try box.decode(String.self, forKey: .name)
        settings = try box.decode(CornerSettings.self, forKey: .settings)
        self = try validated()
    }
    public func encode(to encoder: any Encoder) throws {
        let value = try validated(); var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(value.id, forKey: .id); try box.encode(value.name, forKey: .name); try box.encode(value.settings, forKey: .settings)
    }
}
public struct CornerProfileRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleID: String
    public var profileID: UUID
    public var enabled: Bool
    public init(id: UUID = UUID(), bundleID: String, profileID: UUID, enabled: Bool = false) {
        self.id = id; self.bundleID = bundleID; self.profileID = profileID; self.enabled = enabled
    }
    public func validated(profileIDs: Set<UUID>) throws -> CornerProfileRule {
        guard profileIDs.contains(profileID) else { throw CornerActionError.invalid("A profile rule refers to a missing profile.") }
        var value = self; value.bundleID = try CornerProfileValidation.bundleID(bundleID)
        guard value.bundleID != "com.sknitd.CornerOrbit" else { throw CornerActionError.invalid("CornerOrbit cannot switch profiles for its own settings app.") }
        return value
    }
}
public enum CornerProfileValidation {
    public static let maximumProfiles = 32
    public static let maximumRules = 64
    public static let maximumBytes = 2 * 1_024 * 1_024
    public static func name(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80, value.utf8.count <= 240,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CornerActionError.invalid("Use a profile name of 1–80 characters, without control characters.")
        }
        return value
    }
    public static func nameKey(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    public static func bundleID(_ raw: String) throws -> String {
        try CornerAction(kind: .openApplication, bundleID: raw).validated().bundleID!
    }
}
public struct CornerProfileDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profiles: [CornerProfile]
    public init(schemaVersion: Int = 1, profiles: [CornerProfile] = []) { self.schemaVersion = schemaVersion; self.profiles = profiles }
    public func validated() throws -> CornerProfileDocument {
        guard schemaVersion == 1 else { throw CornerActionError.invalid("This profile JSON schema is not supported.") }
        guard profiles.count <= CornerProfileValidation.maximumProfiles,
              Set(profiles.map(\.id)).count == profiles.count else { throw CornerActionError.invalid("Profile JSON must contain at most 32 profiles with unique identifiers.") }
        return .init(profiles: try profiles.map { try $0.validated() })
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(validated())
        guard bytes.count <= CornerProfileValidation.maximumBytes else { throw CornerActionError.invalid("Profile JSON exceeds 2 MiB.") }
        return bytes
    }
    public static func decode(_ bytes: Data) throws -> CornerProfileDocument {
        guard !bytes.isEmpty, bytes.count <= CornerProfileValidation.maximumBytes else { throw CornerActionError.invalid("Choose a profile JSON file of at most 2 MiB.") }
        return try JSONDecoder().decode(Self.self, from: bytes).validated()
    }
}
public struct CornerProfilesArchive: Codable, Equatable, Sendable {
    public static let defaults = CornerProfilesArchive()
    public var schemaVersion: Int
    public var profiles: [CornerProfile]
    public var activeProfileID: UUID?
    public var autoSwitchEnabled: Bool
    public var rules: [CornerProfileRule]
    public var excludedAppIDs: Set<String>
    public init(schemaVersion: Int = 1, profiles: [CornerProfile] = [], activeProfileID: UUID? = nil,
                autoSwitchEnabled: Bool = false, rules: [CornerProfileRule] = [], excludedAppIDs: Set<String> = []) {
        self.schemaVersion = schemaVersion; self.profiles = profiles; self.activeProfileID = activeProfileID
        self.autoSwitchEnabled = autoSwitchEnabled; self.rules = rules; self.excludedAppIDs = excludedAppIDs
    }
    public func validated() throws -> CornerProfilesArchive {
        guard schemaVersion == 1 else { throw CornerActionError.invalid("This saved profile schema is not supported.") }
        let document = try CornerProfileDocument(profiles: profiles).validated()
        let ids = Set(document.profiles.map(\.id))
        guard Set(document.profiles.map { CornerProfileValidation.nameKey($0.name) }).count == profiles.count,
              activeProfileID.map(ids.contains) ?? true else { throw CornerActionError.invalid("Saved profiles have duplicate names or a missing active profile.") }
        guard rules.count <= CornerProfileValidation.maximumRules, Set(rules.map(\.id)).count == rules.count else { throw CornerActionError.invalid("Use at most 64 profile rules with unique identifiers.") }
        guard excludedAppIDs.count <= 64 else { throw CornerActionError.invalid("Use at most 64 excluded applications.") }
        var result = self; result.profiles = document.profiles
        result.rules = try rules.map { try $0.validated(profileIDs: ids) }
        result.excludedAppIDs = try Set(excludedAppIDs.map { try CornerProfileValidation.bundleID($0) })
        guard !result.excludedAppIDs.contains("com.sknitd.CornerOrbit") else { throw CornerActionError.invalid("CornerOrbit ignores its own settings app; choose another app to exclude.") }
        return result
    }
    public func profile(matching bundleID: String) -> CornerProfile? {
        guard autoSwitchEnabled, bundleID != "com.sknitd.CornerOrbit",
              let rule = rules.first(where: { $0.enabled && $0.bundleID == bundleID }) else { return nil }
        return profiles.first { $0.id == rule.profileID }
    }
}
public struct CornerProfileImportPreview: Equatable, Sendable {
    public let importedProfiles: [CornerProfile]
    public let mergedProfiles: [CornerProfile]
    public let renamedProfiles: [String]
    public var count: Int { importedProfiles.count }
    public static func prepare(data: Data, existing: [CornerProfile], idGenerator: () -> UUID = UUID.init) throws -> CornerProfileImportPreview {
        let document = try CornerProfileDocument.decode(data)
        guard existing.count + document.profiles.count <= CornerProfileValidation.maximumProfiles else { throw CornerActionError.invalid("Import would exceed the 32-profile limit.") }
        var merged = try CornerProfilesArchive(profiles: existing).validated().profiles
        var ids = Set(merged.map(\.id)), names = Set(merged.map { CornerProfileValidation.nameKey($0.name) })
        var imported: [CornerProfile] = [], renamed: [String] = []
        for source in document.profiles {
            var profile = source
            if ids.contains(profile.id) {
                var candidate = idGenerator(), attempts = 0
                while ids.contains(candidate), attempts < 32 { candidate = idGenerator(); attempts += 1 }
                guard !ids.contains(candidate) else { throw CornerActionError.invalid("Could not allocate a unique imported profile identifier.") }
                profile.id = candidate
            }
            if names.contains(CornerProfileValidation.nameKey(profile.name)) {
                let original = profile.name
                var index = 2
                repeat {
                    let suffix = " (\(index))"
                    var base = original
                    while base.count + suffix.count > 80 || base.utf8.count + suffix.utf8.count > 240 { base.removeLast() }
                    profile.name = base + suffix; index += 1
                } while names.contains(CornerProfileValidation.nameKey(profile.name))
                renamed.append("\(original) → \(profile.name)")
            }
            ids.insert(profile.id); names.insert(CornerProfileValidation.nameKey(profile.name))
            imported.append(profile); merged.append(profile)
        }
        return .init(importedProfiles: imported, mergedProfiles: merged, renamedProfiles: renamed)
    }
}
