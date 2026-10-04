import Foundation

/// Deadline-based countdowns remain accurate when the app is hidden or the Mac sleeps.
public struct FocusTimer: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case idle, focus, rest }
    public private(set) var phase: Phase = .idle
    public private(set) var deadline: Date?
    public private(set) var pausedRemaining: TimeInterval?
    public private(set) var completedSessions = 0

    public init() {}
    public var isRunning: Bool { deadline != nil }
    public var isPaused: Bool { pausedRemaining != nil }

    public func remaining(at date: Date) -> TimeInterval {
        max(0, deadline.map { $0.timeIntervalSince(date) } ?? pausedRemaining ?? 0)
    }
    public mutating func start(minutes: Double, phase: Phase = .focus, at date: Date) {
        guard minutes.isFinite, minutes > 0, minutes <= 1_440, phase != .idle else { return }
        self.phase = phase
        deadline = date.addingTimeInterval(minutes * 60)
        pausedRemaining = nil
    }
    public mutating func pause(at date: Date) {
        guard isRunning else { return }
        pausedRemaining = remaining(at: date)
        deadline = nil
    }
    public mutating func resume(at date: Date) {
        guard let pausedRemaining else { return }
        deadline = date.addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
    }
    @discardableResult
    public mutating func finishIfDue(at date: Date) -> Phase? {
        guard let deadline, date >= deadline else { return nil }
        let completed = phase
        if completed == .focus { completedSessions += 1 }
        self.deadline = nil
        pausedRemaining = nil
        phase = .idle
        return completed
    }
    public mutating func cancel() {
        deadline = nil
        pausedRemaining = nil
        phase = .idle
    }
}
