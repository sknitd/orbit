import Foundation

public struct TravelCalendarReference: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case flight, train }
    public let id: String
    public let title: String
    public let code: String
    public let kind: Kind
    public let departure: Date
    public init?(eventID: String, title: String, location: String? = nil, departure: Date, isAllDay: Bool = false) {
        guard !isAllDay else { return nil }
        let text = String((title + " " + (location ?? "")).prefix(4_000))
        func match(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern), let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(result.range(at: 1), in: text) else { return nil }
            return String(text[range]).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "").uppercased()
        }
        if let code = match(#"(?i)\b((?:ICE|TGV|AVE|EUROSTAR|IC|EC|RE|RJ)\s?-?\d{1,5})\b"#) {
            kind = .train; self.code = code
        } else if let code = match(#"\b([A-Z0-9]{2}\s?-?\d{1,4}[A-Z]?)\b"#), AviationstackData.validFlightCode(code) {
            kind = .flight; self.code = code
        } else { return nil }
        id = eventID; self.title = String(title.prefix(300)); self.departure = departure
    }
}

public struct ProviderFlight: Identifiable, Equatable, Sendable {
    public var id: String { code + "-" + String(departure.timeIntervalSince1970) }
    public let code: String
    public let status: String
    public let origin: String
    public let destination: String
    public let departure: Date
    public let estimatedDeparture: Date?
    public let arrival: Date?
    public let terminal: String?
    public let gate: String?
}
public struct ProviderFlightPage: Sendable { public let flights: [ProviderFlight]; public let limited: Bool }

public enum AviationstackData {
    public static func validFlightCode(_ code: String) -> Bool {
        code.range(of: #"^(?=.*[A-Z])[A-Z0-9]{2}[0-9]{1,4}[A-Z]?$"#, options: .regularExpression) != nil
    }
    public static func decode(_ data: Data, requested: String) throws -> ProviderFlightPage {
        guard validFlightCode(requested) else { throw OnlineDataError.invalid("Invalid requested IATA flight code.") }
        let root = try OnlineServiceDecoding.object(data)
        guard root["error"] == nil, let rows = root["data"] as? [[String: Any]], rows.count <= 100 else {
            throw OnlineDataError.invalid("Aviationstack returned no flight data. Check key, HTTPS and flight-data plan entitlements.")
        }
        let flights = try rows.map { row -> ProviderFlight in
            guard let flight = row["flight"] as? [String: Any], let code = flight["iata"] as? String,
                  validFlightCode(code), code == requested, let status = row["flight_status"] as? String, !status.isEmpty, status.utf8.count <= 80,
                  let departure = row["departure"] as? [String: Any], let arrival = row["arrival"] as? [String: Any],
                  let origin = departure["iata"] as? String, let destination = arrival["iata"] as? String,
                  origin.utf8.count <= 100, destination.utf8.count <= 100 else { throw OnlineDataError.invalid("Aviationstack returned an invalid or mismatched flight.") }
            let scheduled = try OnlineServiceDecoding.date(departure["scheduled"])
            let estimated = try (departure["estimated"] as? String).map { try OnlineServiceDecoding.date($0) }
            let arrivalDate = try (arrival["scheduled"] as? String).map { try OnlineServiceDecoding.date($0) }
            return ProviderFlight(code: code, status: status, origin: origin, destination: destination, departure: scheduled,
                                  estimatedDeparture: estimated, arrival: arrivalDate, terminal: (departure["terminal"] as? String).map { String($0.prefix(100)) }, gate: (departure["gate"] as? String).map { String($0.prefix(100)) })
        }
        let pagination = root["pagination"] as? [String: Any]
        let total = (pagination?["total"] as? NSNumber)?.intValue ?? flights.count
        return ProviderFlightPage(flights: flights, limited: total > flights.count)
    }
}
