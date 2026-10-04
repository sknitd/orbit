import Foundation

public enum CornerHistorySource: String, Codable, Sendable { case recent, chrome }
public struct CornerHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let title: String
    public let lastVisited: Date
    public let visitCount: Int
    public let source: CornerHistorySource
    public init(url: URL, title: String, lastVisited: Date, visitCount: Int = 1, source: CornerHistorySource = .recent) {
        self.url = url; self.title = title; self.lastVisited = lastVisited; self.visitCount = visitCount; self.source = source
    }
    public func validated() throws -> CornerHistoryEntry {
        let address = try CornerURLValidation.webURL(url.absoluteString)
        guard title.utf8.count <= 4_096, !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              visitCount >= 0, lastVisited.timeIntervalSince1970.isFinite,
              lastVisited.timeIntervalSince1970 >= -11_644_473_600,
              lastVisited.timeIntervalSinceNow <= 86_400 else { throw CornerActionError.invalid("This history record is not valid.") }
        return .init(url: address, title: title.trimmingCharacters(in: .whitespacesAndNewlines), lastVisited: lastVisited, visitCount: visitCount, source: source)
    }
}
public enum CornerHistorySanitizer {
    public static let maximumCount = 200
    /// Preserve legitimate query strings. Fragments and default ports are omitted
    /// only for deduplication, so page anchors do not flood the recent list.
    public static func sanitize(_ entries: [CornerHistoryEntry], limit: Int = 100) -> [CornerHistoryEntry] {
        guard limit > 0 else { return [] }
        var unique: [String: CornerHistoryEntry] = [:]
        for entry in entries {
            guard let clean = try? entry.validated(), let key = key(for: clean.url) else { continue }
            if let prior = unique[key] {
                if prior.lastVisited > clean.lastVisited { continue }
                if prior.lastVisited == clean.lastVisited {
                    let oldTie = prior.url.absoluteString + "\n" + prior.title + "\n" + prior.source.rawValue
                    let newTie = clean.url.absoluteString + "\n" + clean.title + "\n" + clean.source.rawValue
                    if oldTie <= newTie { continue }
                }
            }
            unique[key] = clean
        }
        return Array(unique.values.sorted {
            if $0.lastVisited != $1.lastVisited { return $0.lastVisited > $1.lastVisited }
            return $0.url.absoluteString < $1.url.absoluteString
        }.prefix(min(limit, maximumCount)))
    }
    public static func chromeVisitDate(microsecondsSince1601 value: Int64) -> Date? {
        guard value >= 0 else { return nil }
        let seconds = Double(value) / 1_000_000 - 11_644_473_600
        guard seconds.isFinite, seconds <= Date().timeIntervalSince1970 + 86_400 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    private static func key(for url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = nil
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.url?.absoluteString
    }
}
