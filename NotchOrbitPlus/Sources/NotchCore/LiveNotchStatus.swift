import Foundation

public enum LiveNotchKind: String, Codable, Sendable, CaseIterable, Hashable {
    case processing, meeting, focus, music, hud, devices, status
    case downloads, command, dictation, verificationCode, package, travel, sports, weather
    public static let defaultOrder: [Self] = [.processing, .hud, .dictation, .verificationCode, .meeting, .travel, .focus, .command, .downloads, .music, .package, .sports, .weather, .devices, .status]
    public var priority: Int {
        Self.defaultOrder.count - (Self.defaultOrder.firstIndex(of: self) ?? Self.defaultOrder.count)
    }
    public var title: String {
        switch self {
        case .processing: "File processing"
        case .meeting: "Meetings"
        case .focus: "Focus timer"
        case .music: "Now playing"
        case .hud: "Volume and brightness"
        case .devices: "Devices and connections"
        case .status: "General status"
        case .downloads: "Downloads"
        case .command: "Commands and builds"
        case .dictation: "Dictation"
        case .verificationCode: "Verification codes"
        case .package: "Packages"
        case .travel: "Travel departures"
        case .sports: "Sports scores"
        case .weather: "Weather alerts"
        }
    }
    public var symbol: String {
        switch self {
        case .processing: "arrow.triangle.2.circlepath"
        case .meeting: "calendar"
        case .focus: "timer"
        case .music: "music.note"
        case .hud: "slider.horizontal.3"
        case .devices: "headphones"
        case .status: "info.circle"
        case .downloads: "arrow.down.circle"
        case .command: "terminal"
        case .dictation: "waveform"
        case .verificationCode: "key"
        case .package: "shippingbox"
        case .travel: "airplane"
        case .sports: "sportscourt"
        case .weather: "cloud.rain"
        }
    }
}

public struct LiveNotchPriorityConfiguration: Codable, Equatable, Sendable {
    public var order: [LiveNotchKind]
    public init(order: [LiveNotchKind] = LiveNotchKind.defaultOrder) { self.order = order }
    private enum CodingKeys: String, CodingKey { case order }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try values.decode([LiveNotchKind].self, forKey: .order)
        let legacy: Set<LiveNotchKind> = [.processing, .meeting, .focus, .music, .hud, .devices, .status]
        // Only a complete valid former schema is migrated. Partial/duplicate
        // orders remain errors, preserving the original corrupt bytes.
        order = saved.count == legacy.count && Set(saved) == legacy
            ? saved + LiveNotchKind.defaultOrder.filter { !legacy.contains($0) } : saved
    }
    public func validate() throws {
        guard order.count == LiveNotchKind.allCases.count, Set(order) == Set(LiveNotchKind.allCases) else {
            throw SyncFailure.invalid("Use every live-status kind exactly once in the priority order.")
        }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4_096 else { throw SyncFailure.invalid("Live-status priority settings exceed their size limit.") }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
    public func encoded() throws -> Data { try validate(); return try JSONEncoder().encode(self) }
}

public enum LiveNotchAction: Sendable, Equatable { case revealFile, copyVerificationCode }

public struct LiveNotchStatus: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: LiveNotchKind
    public let title: String
    public let detail: String
    public let toolID: String
    public let progress: Double?
    public let waveform: [Double]
    public let action: LiveNotchAction?
    public init(id: String, kind: LiveNotchKind, title: String, detail: String = "", toolID: String, progress: Double? = nil, waveform: [Double] = [], action: LiveNotchAction? = nil) {
        self.id = id; self.kind = kind; self.title = String(title.prefix(300)); self.detail = String(detail.prefix(300))
        self.toolID = toolID
        self.action = action
        self.waveform = Array(waveform.filter(\.isFinite).prefix(32)).map { min(1, max(0, $0)) }
        self.progress = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    }
}

public enum LiveNotchSelection {
    /// A stable priority keeps processing visible while retaining secondary activity indicators.
    public static func ordered(_ statuses: [LiveNotchStatus], priorityOrder: [LiveNotchKind] = LiveNotchKind.defaultOrder) -> [LiveNotchStatus] {
        let order = (try? LiveNotchPriorityConfiguration(order: priorityOrder).validate()) != nil ? priorityOrder : LiveNotchKind.defaultOrder
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        var seen = Set<String>()
        return statuses.enumerated().filter {
            !$0.element.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.element.id).inserted
        }.sorted {
            rank[$0.element.kind] == rank[$1.element.kind]
                ? $0.offset < $1.offset : rank[$0.element.kind, default: order.count] < rank[$1.element.kind, default: order.count]
        }.map(\.element)
    }
}
