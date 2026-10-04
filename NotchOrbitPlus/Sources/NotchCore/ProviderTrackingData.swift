import Foundation

public enum ProviderBrowserLink {
    public static func validated(_ text: String) throws -> URL {
        guard text.utf8.count <= 2_048, let url = URL(string: text), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host.contains("."),
              host.range(of: #"^[a-z0-9-]+(?:\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil,
              host.range(of: #"[a-z]"#, options: .regularExpression) != nil,
              ![".local", ".internal", ".localhost"].contains(where: host.hasSuffix) else {
            throw OnlineDataError.invalid("Use an HTTPS tracking/status page on a public domain, without embedded credentials.")
        }
        return url
    }
}

public struct PackageReference: Identifiable, Codable, Equatable, Sendable {
    public var id: String { number }
    public let number: String
    public let pageURL: URL?
    public init(number: String, pageURL: URL? = nil) throws {
        guard number.range(of: #"^[A-Za-z0-9-]{3,100}$"#, options: .regularExpression) != nil else { throw OnlineDataError.invalid("Enter a tracking number with 3–100 letters, digits or hyphens.") }
        if let pageURL { _ = try ProviderBrowserLink.validated(pageURL.absoluteString) }
        self.number = number; self.pageURL = pageURL
    }
    public func validate() throws { _ = try Self(number: number, pageURL: pageURL) }
}

public struct PackageTracking: Identifiable, Equatable, Sendable {
    public let id: String
    public let number: String
    public let carrier: String
    public let status: String
    public let estimatedDelivery: String?
    public let checkpoint: String?
    public let updatedAt: Date?
    public var isActive: Bool { ["InTransit", "OutForDelivery", "AvailableForPickup", "AttemptFail", "Exception"].contains(status) }
}

public struct PackageTrackingPage: Sendable {
    public let trackings: [PackageTracking]
    public let nextCursor: String?
}

public enum AfterShipTrackingData {
    public static let version = "2026-07"
    public static func decode(_ data: Data) throws -> PackageTrackingPage {
        let root = try OnlineServiceDecoding.object(data)
        guard let meta = root["meta"] as? [String: Any], (meta["code"] as? NSNumber)?.intValue == 200,
              let values = root["data"] as? [String: Any], let rows = values["trackings"] as? [[String: Any]], rows.count <= 100 else {
            throw OnlineDataError.invalid("AfterShip returned no supported tracking page. Check your key and tracking-account access.")
        }
        var seen = Set<String>()
        let trackings = try rows.map { row -> PackageTracking in
            guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 200, seen.insert(id).inserted,
                  let number = row["tracking_number"] as? String, let carrier = row["slug"] as? String,
                  let status = row["tag"] as? String, !status.isEmpty, status.utf8.count <= 100 else {
                throw OnlineDataError.invalid("AfterShip returned an invalid tracking record.")
            }
            _ = try PackageReference(number: number)
            guard carrier.utf8.count <= 200 else { throw OnlineDataError.invalid("Invalid carrier code.") }
            var estimated: String?
            if let latest = row["latest_estimated_delivery"] as? [String: Any] {
                estimated = (latest["date"] as? String) ?? (latest["datetime"] as? String)
            }
            if estimated == nil, let courier = row["courier_estimated_delivery_date"] as? [String: Any] {
                estimated = courier["estimated_delivery_date"] as? String
            }
            if let estimated {
                guard estimated.range(of: #"^\d{4}-\d{2}-\d{2}(?:T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,6})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)?)?$"#, options: .regularExpression) != nil else {
                    throw OnlineDataError.invalid("Invalid carrier delivery estimate.")
                }
                _ = try OnlineServiceDecoding.calendarDate(String(estimated.prefix(10)))
            }
            let checkpoint = (row["checkpoints"] as? [[String: Any]])?.last?["message"] as? String
            let updated = try (row["updated_at"] as? String).map { try OnlineServiceDecoding.date($0) }
            return PackageTracking(id: id, number: number, carrier: carrier, status: status, estimatedDelivery: estimated,
                                   checkpoint: checkpoint.map { String($0.prefix(500)) }, updatedAt: updated)
        }
        let pagination = values["pagination"] as? [String: Any]
        var cursor: String?
        if pagination?["has_next_page"] as? Bool == true {
            guard let next = pagination?["next_cursor"] as? String, !next.isEmpty, next.utf8.count <= 2_048 else {
                throw OnlineDataError.invalid("AfterShip omitted its next-page cursor.")
            }
            cursor = next
        }
        return PackageTrackingPage(trackings: trackings, nextCursor: cursor)
    }
}
