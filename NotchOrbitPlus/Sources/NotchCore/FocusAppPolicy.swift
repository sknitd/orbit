import Foundation

public struct FocusAppConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var bundleIDs: [String]
    public init(enabled: Bool = false, bundleIDs: [String] = []) {
        self.enabled = enabled; self.bundleIDs = bundleIDs
    }
    public func validate() throws {
        guard bundleIDs.count <= 32, Set(bundleIDs).count == bundleIDs.count,
              bundleIDs.allSatisfy({ $0.count <= 200 && $0.contains(".") &&
                  $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_" )).contains($0) } }) else {
            throw SyncFailure.invalid("Choose at most 32 unique applications with valid bundle identifiers.")
        }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384 else { throw SyncFailure.invalid("Focus application settings exceed their size limit.") }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
}

public struct FocusAppSnapshot: Codable, Equatable, Sendable {
    public let processID: Int32
    public let bundleID: String
    public let hidden: Bool
    public let launchDate: Date?
    public init(processID: Int32, bundleID: String, hidden: Bool, launchDate: Date? = nil) {
        self.processID = processID; self.bundleID = bundleID; self.hidden = hidden; self.launchDate = launchDate
    }
}

public enum FocusAppPolicy {
    /// Already-hidden apps and the current process are never owned by this session.
    public static func hideCandidates(configuration: FocusAppConfiguration, running: [FocusAppSnapshot], ownProcessID: Int32) -> [FocusAppSnapshot] {
        guard configuration.enabled, (try? configuration.validate()) != nil else { return [] }
        var seen = Set<Int32>()
        return running.filter { $0.processID != ownProcessID && !$0.hidden && $0.launchDate != nil &&
            configuration.bundleIDs.contains($0.bundleID) && seen.insert($0.processID).inserted }
    }
    /// A reused PID does not authorize unhiding a different application.
    public static func restoreCandidates(owned: [FocusAppSnapshot], running: [FocusAppSnapshot]) -> [FocusAppSnapshot] {
        running.filter { app in app.hidden && owned.contains { $0.processID == app.processID && $0.bundleID == app.bundleID && $0.launchDate != nil && $0.launchDate == app.launchDate } }
    }
}

public enum LauncherDropPolicy {
    public static func validate(kind: PlusLauncherKind, urls: [URL]) throws {
        guard kind == .application, !urls.isEmpty, urls.count <= 100,
              Set(urls).count == urls.count, urls.allSatisfy(\.isFileURL) else {
            throw SyncFailure.invalid("Drop up to 100 distinct local files onto an application pin.")
        }
    }
}
