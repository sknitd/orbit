import Foundation

public struct FocusCompletion: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let finishedAt: Date
    public let duration: TimeInterval
    public init(id: UUID = UUID(), finishedAt: Date, duration: TimeInterval) {
        self.id = id; self.finishedAt = finishedAt; self.duration = duration
    }
}

public struct FocusDayTotal: Identifiable, Equatable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let sessions: Int
    public let seconds: TimeInterval
}

public enum FocusHistory {
    public static let maximumRecords = 5_000
    public static func week(containing date: Date, records: [FocusCompletion], calendar: Calendar = .current) -> [FocusDayTotal] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: interval.start),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let matches = records.filter { $0.finishedAt >= day && $0.finishedAt < next && $0.duration.isFinite && $0.duration > 0 }
            return FocusDayTotal(date: day, sessions: matches.count, seconds: matches.reduce(0) { $0 + $1.duration })
        }
    }
}
