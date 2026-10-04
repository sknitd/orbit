import Foundation

public enum LiveNotchKind: String, Sendable, Equatable {
    case processing, meeting, focus, music
    public var priority: Int {
        switch self { case .processing: 4; case .meeting: 3; case .focus: 2; case .music: 1 }
    }
    public var symbol: String {
        switch self {
        case .processing: "arrow.triangle.2.circlepath"
        case .meeting: "calendar"
        case .focus: "timer"
        case .music: "music.note"
        }
    }
}

public struct LiveNotchStatus: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: LiveNotchKind
    public let title: String
    public let detail: String
    public let toolID: String
    public let progress: Double?
    public init(id: String, kind: LiveNotchKind, title: String, detail: String = "", toolID: String, progress: Double? = nil) {
        self.id = id; self.kind = kind; self.title = String(title.prefix(300)); self.detail = String(detail.prefix(300))
        self.toolID = toolID
        self.progress = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    }
}

public enum LiveNotchSelection {
    /// A stable priority keeps processing visible while retaining secondary activity indicators.
    public static func ordered(_ statuses: [LiveNotchStatus]) -> [LiveNotchStatus] {
        var seen = Set<String>()
        return statuses.enumerated().filter {
            !$0.element.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.element.id).inserted
        }.sorted {
            $0.element.kind.priority == $1.element.kind.priority
                ? $0.offset < $1.offset : $0.element.kind.priority > $1.element.kind.priority
        }.map(\.element)
    }
}
