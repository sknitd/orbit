import Foundation

public enum ContextTrigger: String, Codable, CaseIterable, Sendable {
    case frontmostApp, runningApp, meetingActive, musicPlaying, finderDrag
    public var title: String {
        switch self {
        case .frontmostApp: "Frontmost app"
        case .runningApp: "Running app"
        case .meetingActive: "Meeting activity"
        case .musicPlaying: "Music playing"
        case .finderDrag: "Finder file drag"
        }
    }
}
public struct ContextRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var trigger: ContextTrigger
    public var appBundleID: String
    public var toolID: String
    public var showExpanded: Bool
    public init(id: UUID = UUID(), name: String, enabled: Bool = true, trigger: ContextTrigger,
                appBundleID: String = "", toolID: String, showExpanded: Bool = true) {
        self.id = id; self.name = name; self.enabled = enabled; self.trigger = trigger
        self.appBundleID = appBundleID; self.toolID = toolID; self.showExpanded = showExpanded
    }
    public func validated() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.appBundleID = appBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let controls = CharacterSet.controlCharacters
        guard !value.name.isEmpty, value.name.utf8.count <= 120, value.name.rangeOfCharacter(from: controls) == nil,
              !toolID.isEmpty, toolID.utf8.count <= 80, toolID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }),
              ![.frontmostApp, .runningApp].contains(trigger) || (!value.appBundleID.isEmpty && value.appBundleID.utf8.count <= 200 && value.appBundleID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" })) else {
            throw ContextRuleError.invalid("Use a short rule name, valid tool ID, and an app bundle ID for app rules.")
        }
        return value
    }
    public static var defaults: [Self] {
        [.init(name: "Meeting app", enabled: false, trigger: .meetingActive, toolID: "teleprompter"),
         .init(name: "Zoom", enabled: false, trigger: .frontmostApp, appBundleID: "us.zoom.xos", toolID: "teleprompter"),
         .init(name: "Microsoft Teams", enabled: false, trigger: .frontmostApp, appBundleID: "com.microsoft.teams2", toolID: "teleprompter"),
         .init(name: "FaceTime", enabled: false, trigger: .frontmostApp, appBundleID: "com.apple.FaceTime", toolID: "teleprompter"),
         .init(name: "Music playing", enabled: false, trigger: .musicPlaying, toolID: "nowPlaying", showExpanded: false),
         .init(name: "Finder file drag", enabled: false, trigger: .finderDrag, toolID: "workflows")]
    }
}
public enum ContextRuleError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let value) = self { value } else { nil } }
}
public struct ContextSignals: Equatable, Sendable {
    public var meetingActive: Bool
    public var musicPlaying: Bool
    public var finderDrag: Bool
    public init(meetingActive: Bool = false, musicPlaying: Bool = false, finderDrag: Bool = false) {
        self.meetingActive = meetingActive; self.musicPlaying = musicPlaying; self.finderDrag = finderDrag
    }
}
public struct ContextObservation: Equatable, Sendable {
    public var frontmostApp: String?
    public var runningApps: Set<String>
    public var signals: ContextSignals
    public init(frontmostApp: String?, runningApps: Set<String>, signals: ContextSignals = .init()) {
        self.frontmostApp = frontmostApp; self.runningApps = runningApps; self.signals = signals
    }
}
public struct ContextProposal: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let ruleName: String
    public let toolID: String
    public let showExpanded: Bool
}
public enum ContextRuleSelection {
    public static func proposal(rules: [ContextRule], observation: ContextObservation, visibleToolIDs: Set<String>) -> ContextProposal? {
        for rule in rules where rule.enabled && visibleToolIDs.contains(rule.toolID) {
            guard (try? rule.validated()) != nil else { continue }
            let matches = switch rule.trigger {
            case .frontmostApp: observation.frontmostApp == rule.appBundleID
            case .runningApp: observation.runningApps.contains(rule.appBundleID)
            case .meetingActive: observation.signals.meetingActive
            case .musicPlaying: observation.signals.musicPlaying
            case .finderDrag: observation.signals.finderDrag
            }
            if matches { return .init(id: rule.id, ruleName: rule.name, toolID: rule.toolID, showExpanded: rule.showExpanded) }
        }
        return nil
    }
}
