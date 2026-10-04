import Foundation

public struct ProviderSportsTeam: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let country: String?
    public func validate() throws {
        guard id > 0, !name.isEmpty, name.utf8.count <= 300 else { throw OnlineDataError.invalid("Invalid API-FOOTBALL team.") }
    }
}
public struct ProviderSportsGame: Identifiable, Equatable, Sendable {
    public let id: Int
    public let home: ProviderSportsTeam
    public let away: ProviderSportsTeam
    public let homeScore: Int?
    public let awayScore: Int?
    public let status: String
    public let statusLabel: String
    public let elapsed: Int?
    public let start: Date
    public var isInProgress: Bool { ["1H", "HT", "2H", "ET", "BT", "P", "LIVE"].contains(status) }
    public var scoreText: String { "\(homeScore.map(String.init) ?? "—")–\(awayScore.map(String.init) ?? "—")" }
}
public enum APIFootballData {
    private static func integer(_ raw: Any?, minimum: Int = 1, maximum: Int = Int.max) throws -> Int {
        let decimal = try OnlineServiceDecoding.decimal(raw)
        guard let value = Int(NSDecimalNumber(decimal: decimal).stringValue), (minimum...maximum).contains(value) else {
            throw OnlineDataError.invalid("Invalid API-FOOTBALL numeric field.")
        }
        return value
    }
    private static func rows(_ data: Data, limit: Int) throws -> [[String: Any]] {
        let root = try OnlineServiceDecoding.object(data)
        if let errors = root["errors"] as? [String: Any], !errors.isEmpty { throw OnlineDataError.invalid("API-FOOTBALL rejected the request. Check key, subscription and rate limit.") }
        if let errors = root["errors"] as? [Any], !errors.isEmpty { throw OnlineDataError.invalid("API-FOOTBALL rejected the request.") }
        guard let rows = root["response"] as? [[String: Any]], rows.count <= limit else { throw OnlineDataError.invalid("API-FOOTBALL returned an unsupported or oversized response.") }
        return rows
    }
    public static func teams(_ data: Data) throws -> [ProviderSportsTeam] {
        try rows(data, limit: 100).map { row in
            guard let values = row["team"] as? [String: Any], let name = values["name"] as? String else {
                throw OnlineDataError.invalid("Invalid API-FOOTBALL team search result.")
            }
            let team = ProviderSportsTeam(id: try integer(values["id"]), name: name, country: values["country"] as? String); try team.validate(); return team
        }
    }
    public static func games(_ data: Data) throws -> [ProviderSportsGame] {
        try rows(data, limit: 500).map { row in
            guard let fixture = row["fixture"] as? [String: Any],
                  let status = fixture["status"] as? [String: Any], let short = status["short"] as? String, let long = status["long"] as? String,
                  let sides = row["teams"] as? [String: [String: Any]], let home = sides["home"], let away = sides["away"],
                  let homeName = home["name"] as? String, let awayName = away["name"] as? String,
                  let goals = row["goals"] as? [String: Any] else { throw OnlineDataError.invalid("Invalid API-FOOTBALL fixture.") }
            let homeTeam = ProviderSportsTeam(id: try integer(home["id"]), name: homeName, country: nil), awayTeam = ProviderSportsTeam(id: try integer(away["id"]), name: awayName, country: nil)
            try homeTeam.validate(); try awayTeam.validate()
            func score(_ raw: Any?) throws -> Int? {
                guard let raw, !(raw is NSNull) else { return nil }
                let value = try OnlineServiceDecoding.decimal(raw)
                guard let integer = Int(NSDecimalNumber(decimal: value).stringValue), (0...100).contains(integer) else { throw OnlineDataError.invalid("Invalid football score.") }
                return integer
            }
            let elapsed = try status["elapsed"].flatMap { raw -> Int? in raw is NSNull ? nil : try integer(raw, minimum: 0, maximum: 300) }
            return ProviderSportsGame(id: try integer(fixture["id"]), home: homeTeam, away: awayTeam, homeScore: try score(goals["home"]), awayScore: try score(goals["away"]),
                                      status: short, statusLabel: String(long.prefix(200)), elapsed: elapsed,
                                      start: try OnlineServiceDecoding.date(fixture["date"]))
        }
    }
}
