import Foundation

public enum CoreUpdateError: Error, LocalizedError, Equatable, Sendable {
    case invalidVersion, invalidManifest, invalidArchiveURL, invalidChecksum, incompatibleSystem
    public var errorDescription: String? {
        switch self {
        case .invalidVersion: "The update version is not a stable three-part version."
        case .invalidManifest: "The update feed has invalid product or provenance information."
        case .invalidArchiveURL: "The update download is outside the published NotchOrbitPlus channel."
        case .invalidChecksum: "The downloaded update does not match its published SHA-256 checksum."
        case .incompatibleSystem: "This update requires a newer version of macOS."
        }
    }
}

public struct CoreUpdateVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public init(_ string: String) throws {
        let fields = string.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ field in
            !field.isEmpty && field.utf8.allSatisfy { (48...57).contains($0) } &&
            (field.count == 1 || field.first != "0") && field.count <= 6
        }), let major = Int(fields[0]), let minor = Int(fields[1]), let patch = Int(fields[2]) else {
            throw CoreUpdateError.invalidVersion
        }
        self.major = major; self.minor = minor; self.patch = patch
    }
    public var description: String { "\(major).\(minor).\(patch)" }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// TLS authenticates this public GitHub origin; installation additionally verifies Apple signatures.
public struct CoreUpdateFeed: Decodable, Equatable, Sendable {
    public static let channelURL = URL(string: "https://raw.githubusercontent.com/sknitd/orbit/codex/notch-plus-updates/stable.json")!
    public static let maximumArchiveBytes = 128 * 1_024 * 1_024
    public struct Signing: Decodable, Equatable, Sendable {
        public let kind: String
        public let teamIdentifier: String?
        public let notarized: Bool
        enum CodingKeys: String, CodingKey {
            case kind, notarized
            case teamIdentifier = "team_identifier"
        }
    }
    public let schemaVersion: Int
    public let product: String
    public let bundleIdentifier: String
    public let version: String
    public let minimumMacOS: String
    public let sourceCommit: String
    public let archiveURL: URL
    public let archiveSHA256: String
    public let archiveBytes: Int
    public let releaseNotesURL: URL
    public let publishedAt: String
    public let signing: Signing
    enum CodingKeys: String, CodingKey {
        case product, version, signing
        case schemaVersion = "schema_version", bundleIdentifier = "bundle_identifier"
        case minimumMacOS = "minimum_macos", sourceCommit = "source_commit"
        case archiveURL = "archive_url", archiveSHA256 = "archive_sha256", archiveBytes = "archive_bytes"
        case releaseNotesURL = "release_notes_url", publishedAt = "published_at"
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 128 * 1_024 else { throw CoreUpdateError.invalidManifest }
        let feed = try JSONDecoder().decode(Self.self, from: data)
        _ = try CoreUpdateVersion(feed.version)
        guard feed.schemaVersion == 1, feed.product == "NotchOrbitPlus",
              feed.bundleIdentifier == "com.sknitd.NotchOrbitPlus",
              hexadecimal(feed.sourceCommit, count: 40), hexadecimal(feed.archiveSHA256, count: 64),
              (1...maximumArchiveBytes).contains(feed.archiveBytes),
              validMinimum(feed.minimumMacOS),
              feed.signing.kind == "adhoc" || feed.signing.kind == "developer-id" else {
            throw CoreUpdateError.invalidManifest
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: feed.publishedAt)
        formatter.formatOptions = [.withInternetDateTime]
        guard fractional != nil || formatter.date(from: feed.publishedAt) != nil else { throw CoreUpdateError.invalidManifest }
        if feed.signing.kind == "adhoc" {
            guard !feed.signing.notarized, feed.signing.teamIdentifier == nil else { throw CoreUpdateError.invalidManifest }
        } else {
            guard let team = feed.signing.teamIdentifier, team.count == 10,
                  team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else {
                throw CoreUpdateError.invalidManifest
            }
        }
        let archive = "https://raw.githubusercontent.com/sknitd/orbit/codex/notch-plus-updates/packages/\(feed.version)/\(feed.sourceCommit)/NotchOrbitPlus.app.zip"
        guard feed.archiveURL.absoluteString == archive,
              feed.releaseNotesURL.absoluteString == "https://github.com/sknitd/orbit/tree/\(feed.sourceCommit)/NotchOrbitPlus" else {
            throw CoreUpdateError.invalidArchiveURL
        }
        return feed
    }

    public func isNewer(than current: String) throws -> Bool {
        try CoreUpdateVersion(version) > CoreUpdateVersion(current)
    }
    public func supportsMacOS(major: Int, minor: Int, patch: Int = 0) -> Bool {
        let fields = minimumMacOS.split(separator: ".").compactMap { Int($0) }
        guard fields.count == 2 || fields.count == 3 else { return false }
        let minimum = fields + Array(repeating: 0, count: 3 - fields.count)
        let actual = [major, minor, patch]
        for index in 0..<3 where actual[index] != minimum[index] { return actual[index] > minimum[index] }
        return true
    }
    public func verifySHA256(_ actual: String, bytes: Int) throws {
        guard bytes == archiveBytes, actual.lowercased() == archiveSHA256.lowercased() else {
            throw CoreUpdateError.invalidChecksum
        }
    }
    private static func hexadecimal(_ string: String, count: Int) -> Bool {
        string.utf8.count == count && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validMinimum(_ value: String) -> Bool {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        return (2...3).contains(fields.count) && fields.allSatisfy { field in
            !field.isEmpty && field.count <= 6 && (field.count == 1 || field.first != "0") &&
                field.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
}
