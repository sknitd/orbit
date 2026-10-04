import Foundation

public enum CommandActivityError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let value) = self { value } else { nil } }
}
public struct CommandActivityMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case start, finish }
    public let version: Int
    public let kind: Kind
    public let id: UUID
    public let label: String
    public let at: Double
    public let exitCode: Int?
    public let duration: Double?
    public init(kind: Kind, id: UUID, label: String, at: Double, exitCode: Int? = nil, duration: Double? = nil) {
        version = 1; self.kind = kind; self.id = id; self.label = label; self.at = at; self.exitCode = exitCode; self.duration = duration
    }
    public static func decode(_ bytes: Data, now: Date = Date()) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 4_096,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "kind", "id", "label", "at", "exitCode", "duration"]) else {
            throw CommandActivityError.invalid("Command messages must be bounded activity metadata only.")
        }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        return try value.validated(now: now)
    }
    public func validated(now: Date = Date()) throws -> Self {
        guard version == 1, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.utf8.count <= 160, label.rangeOfCharacter(from: .controlCharacters) == nil,
              at.isFinite, at >= now.timeIntervalSince1970 - 86_400, at <= now.timeIntervalSince1970 + 300 else {
            throw CommandActivityError.invalid("Command activity metadata contains invalid fields or a stale timestamp.")
        }
        switch kind {
        case .start:
            guard exitCode == nil, duration == nil else { throw CommandActivityError.invalid("Start messages cannot claim an exit result.") }
        case .finish:
            guard let code = exitCode, (-255...255).contains(code), let duration,
                  duration.isFinite, (0...604_800).contains(duration) else {
                throw CommandActivityError.invalid("Finish messages need a valid exit code and measured duration.")
            }
        }
        return self
    }
}
public enum CommandActivityState: String, Sendable { case running, succeeded, failed, interrupted }
public struct CommandActivity: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let startedAt: Date
    public var state: CommandActivityState
    public var finishedAt: Date?
    public var exitCode: Int?
    public var duration: Double?
}
public struct CommandActivityTracker: Sendable {
    public private(set) var activities: [CommandActivity] = []
    public init() {}
    public mutating func accept(_ message: CommandActivityMessage, now: Date = Date()) throws {
        _ = try message.validated(now: now)
        switch message.kind {
        case .start:
            guard !activities.contains(where: { $0.id == message.id }), activities.filter({ $0.state == .running }).count < 32 else {
                throw CommandActivityError.invalid("Duplicate or excess running command activity.")
            }
            activities.insert(.init(id: message.id, label: message.label, startedAt: Date(timeIntervalSince1970: message.at),
                                    state: .running, finishedAt: nil, exitCode: nil, duration: nil), at: 0)
        case .finish:
            guard let index = activities.firstIndex(where: { $0.id == message.id && $0.state == .running }),
                  activities[index].label == message.label, message.at >= activities[index].startedAt.timeIntervalSince1970,
                  let code = message.exitCode, let duration = message.duration else {
                throw CommandActivityError.invalid("Finish must match an observed running activity.")
            }
            activities[index].state = code == 0 ? .succeeded : .failed
            activities[index].finishedAt = Date(timeIntervalSince1970: message.at)
            activities[index].exitCode = code; activities[index].duration = duration
        }
        if activities.count > 82 {
            let running = activities.filter { $0.state == .running }
            activities = running + Array(activities.filter { $0.state != .running }.prefix(50))
        }
    }
    public mutating func pause() {
        for index in activities.indices where activities[index].state == .running { activities[index].state = .interrupted }
    }
    public mutating func clearRetained() { activities.removeAll { $0.state != .running } }
}
