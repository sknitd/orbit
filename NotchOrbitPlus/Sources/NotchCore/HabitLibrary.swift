import Foundation

public struct CoreHabit: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var checkedDays: [String]
    public init(id: UUID = UUID(), name: String, checkedDays: [String] = []) { self.id = id; self.name = name; self.checkedDays = checkedDays }
}

public struct CoreHabitDay: Equatable, Sendable, Identifiable {
    public let id: String
    public let checked: Bool
}

public struct CoreHabitLibrary: Codable, Equatable, Sendable {
    public static let maximumBytes = 524_288
    public var schemaVersion = 1
    public var habits: [CoreHabit]
    public init(habits: [CoreHabit] = []) { self.habits = habits }
    public func validate() throws {
        guard schemaVersion == 1, habits.count <= 100, Set(habits.map(\.id)).count == habits.count,
              habits.reduce(0, { $0 + $1.checkedDays.count }) <= 20_000 else { throw SyncFailure.invalid("Habits support 100 unique habits and 20,000 daily checkoffs.") }
        for habit in habits {
            guard !habit.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, habit.name.count <= 120,
                  habit.name.rangeOfCharacter(from: .controlCharacters) == nil,
                  habit.checkedDays.count <= 3_660, Set(habit.checkedDays).count == habit.checkedDays.count,
                  habit.checkedDays.allSatisfy({ CoreHabitCalendar.date($0) != nil }) else { throw SyncFailure.invalid("Invalid habit name or calendar date. Original data was retained.") }
        }
    }
    public func encoded() throws -> Data {
        try validate(); let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw SyncFailure.invalid("Habit history exceeds 512 KB.") }; return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw SyncFailure.invalid("Habit history exceeds 512 KB; its original is retained.") }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
    public mutating func toggle(_ habitID: UUID, day: String) throws {
        guard CoreHabitCalendar.date(day) != nil, let index = habits.firstIndex(where: { $0.id == habitID }) else { throw SyncFailure.invalid("The habit or date is unavailable.") }
        var next = self
        if let old = next.habits[index].checkedDays.firstIndex(of: day) { next.habits[index].checkedDays.remove(at: old) }
        else { next.habits[index].checkedDays.append(day); next.habits[index].checkedDays.sort() }
        try next.validate(); self = next
    }
}

public enum CoreHabitCalendar {
    private static var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    public static func key(for date: Date, timeZone: TimeZone = .current) -> String {
        var local = calendar; local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    public static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard key.utf8.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              key.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let year = Int(parts[0]), (1900...9999).contains(year), let month = Int(parts[1]), let day = Int(parts[2]),
              let result = calendar.date(from: DateComponents(year: year, month: month, day: day)), Self.key(for: result, timeZone: calendar.timeZone) == key else { return nil }
        return result
    }
    public static func streak(_ habit: CoreHabit, today: String) -> Int {
        guard var cursor = date(today) else { return 0 }
        let checked = Set(habit.checkedDays)
        // Today is still available until midnight; yesterday's streak remains visible until checked today.
        if !checked.contains(today) { guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }; cursor = yesterday }
        var count = 0
        while checked.contains(key(for: cursor, timeZone: calendar.timeZone)) {
            count += 1; guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }; cursor = previous
        }
        return count
    }
    public static func heatmap(_ habit: CoreHabit, through today: String) -> [CoreHabitDay] {
        guard let last = date(today) else { return [] }; let checked = Set(habit.checkedDays)
        return (-48...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: last) else { return nil }
            let key = key(for: date, timeZone: calendar.timeZone); return CoreHabitDay(id: key, checked: checked.contains(key))
        }
    }
}
