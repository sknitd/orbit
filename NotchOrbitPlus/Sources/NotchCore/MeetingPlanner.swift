import Foundation

public struct OrbitMeeting: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let joinURL: URL?
    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, joinURL: URL? = nil) {
        self.id = id; self.title = String(title.prefix(300)); self.start = start; self.end = end
        self.isAllDay = isAllDay; self.joinURL = joinURL
    }
    public func countdown(at now: Date) -> String {
        guard start > now else { return end > now ? "Now" : "Ended" }
        let seconds = Int(min(86_400, max(0, start.timeIntervalSince(now))))
        if seconds < 60 { return "in \(seconds)s" }
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return "in \(minutes)m" }
        return "in \(minutes / 60)h \(minutes % 60)m"
    }
}

public enum MeetingPlanner {
    public static func upcoming(_ meetings: [OrbitMeeting], at now: Date, horizon: TimeInterval = 86_400) -> [OrbitMeeting] {
        guard now.timeIntervalSince1970.isFinite, horizon.isFinite, horizon > 0 else { return [] }
        return meetings.filter {
            !$0.isAllDay && $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite
                && $0.end > $0.start && $0.end > now && $0.start <= now.addingTimeInterval(min(horizon, 7 * 86_400))
        }.sorted {
            let leftStarted = $0.start <= now, rightStarted = $1.start <= now
            if leftStarted != rightStarted { return leftStarted }
            let leftDate = leftStarted ? $0.end : $0.start
            let rightDate = rightStarted ? $1.end : $1.start
            return leftDate != rightDate ? leftDate < rightDate : $0.id < $1.id
        }
    }
}

/// Only recognized HTTPS conferencing links can become a one-click Join action.
public enum MeetingLinkResolver {
    private static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "teams.cloud.microsoft", "webex.com", "whereby.com", "meet.jit.si", "gotomeet.me",
        "gotomeeting.com", "app.chime.aws", "v.ringcentral.com"]

    public static func validated(_ url: URL?) -> URL? {
        guard let url, url.absoluteString.utf8.count <= 4_096,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(),
              hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              !components.path.isEmpty, components.path != "/" else { return nil }
        return components.url
    }

    public static func find(eventURL: URL?, location: String?, notes: String?) -> URL? {
        if let direct = validated(eventURL) { return direct }
        guard let expression = try? NSRegularExpression(pattern: "https://[^\\s<>\\\"\\[\\]()]+", options: .caseInsensitive) else { return nil }
        for value in [location, notes].compactMap({ $0 }) {
            let bounded = String(value.prefix(65_536))
            let range = NSRange(bounded.startIndex..<bounded.endIndex, in: bounded)
            for match in expression.matches(in: bounded, range: range) {
                guard let matchRange = Range(match.range, in: bounded) else { continue }
                let text = String(bounded[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
                if let link = validated(URL(string: text)) { return link }
            }
        }
        return nil
    }
}
