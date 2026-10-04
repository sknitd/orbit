import Foundation

public enum WorldClockError: Error, LocalizedError, Equatable, Sendable {
    case unknownZone, invalidWallTime, invalidPreferences
    public var errorDescription: String? {
        switch self {
        case .unknownZone: "Choose a valid IANA time zone."
        case .invalidWallTime: "That local time does not exist in this zone, possibly because the clocks move forward."
        case .invalidPreferences: "Saved time zones must be up to 12 unique, valid IANA identifiers. Original settings are preserved."
        }
    }
}

public struct WorldClockPreferences: Codable, Equatable, Sendable {
    public var zoneIDs: [String]
    public init(zoneIDs: [String] = [TimeZone.current.identifier]) {
        var seen = Set<String>()
        self.zoneIDs = Array(zoneIDs.filter { TimeZone(identifier: $0) != nil && seen.insert($0).inserted }.prefix(12))
    }
    public static func validated(_ zoneIDs: [String]) throws -> [String] {
        guard zoneIDs.count <= 12, WorldClockPreferences(zoneIDs: zoneIDs).zoneIDs == zoneIDs else { throw WorldClockError.invalidPreferences }
        return zoneIDs
    }
    private enum CodingKeys: String, CodingKey { case zoneIDs }
    public init(from decoder: Decoder) throws {
        self.init(zoneIDs: try decoder.container(keyedBy: CodingKeys.self).decode([String].self, forKey: .zoneIDs))
    }
}

/// One absolute meeting instant is displayed in each zone; a wall-clock input
/// is checked against DST normalization. A repeated fall-back time uses the
/// first occurrence, matching Calendar's documented default policy.
public enum WorldClockConversion {
    public static func components(for date: Date, zoneID: String) throws -> DateComponents {
        guard let zone = TimeZone(identifier: zoneID) else { throw WorldClockError.unknownZone }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
    }
    public static func date(components: DateComponents, zoneID: String) throws -> Date {
        guard let zone = TimeZone(identifier: zoneID) else { throw WorldClockError.unknownZone }
        guard let year = components.year, let month = components.month, let day = components.day,
              let hour = components.hour, let minute = components.minute else { throw WorldClockError.invalidWallTime }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let wanted = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: components.second ?? 0)
        guard let candidate = calendar.date(from: wanted) else { throw WorldClockError.invalidWallTime }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: candidate)
        guard actual.year == year, actual.month == month, actual.day == day,
              actual.hour == hour, actual.minute == minute, actual.second == wanted.second else { throw WorldClockError.invalidWallTime }
        return candidate
    }
    public static func offsetLabel(for date: Date, zoneID: String) throws -> String {
        guard let zone = TimeZone(identifier: zoneID) else { throw WorldClockError.unknownZone }
        let minutes = zone.secondsFromGMT(for: date) / 60
        return String(format: "UTC%@%02d:%02d", minutes < 0 ? "−" : "+", abs(minutes) / 60, abs(minutes) % 60)
    }
}
