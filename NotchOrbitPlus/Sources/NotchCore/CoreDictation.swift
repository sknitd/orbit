import Foundation

public enum DictationShortcutKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case d = "D", r = "R", space = "Space"
    public var id: String { rawValue }
}
public enum DictationShortcutModifiers: String, CaseIterable, Identifiable, Codable, Sendable {
    case controlOption = "Control–Option", controlShift = "Control–Shift", commandOption = "Command–Option"
    public var id: String { rawValue }
}
public struct DictationShortcut: Codable, Equatable, Sendable {
    public var key: DictationShortcutKey
    public var modifiers: DictationShortcutModifiers
    public init(key: DictationShortcutKey = .d, modifiers: DictationShortcutModifiers = .controlOption) {
        self.key = key; self.modifiers = modifiers
    }
    public var title: String { modifiers.rawValue + "–" + key.rawValue }
}
public enum DictationEvent: Sendable {
    case transcript(String, isFinal: Bool)
    case level(Double)
    case failure(String)
}
public enum DictationText {
    public static let maximumBytes = 100_000
    public static func validated(_ text: String) throws -> String {
        guard text.utf8.count <= maximumBytes else { throw AssistantFileFailure.invalid("The transcript reached 100 KB. Send or copy the current text before starting another session.") }
        return text
    }
    /// RMS of actual normalized PCM samples; invalid samples contribute no measurement.
    public static func rms<S: Sequence>(_ samples: S) -> Double where S.Element == Float {
        var sum = 0.0; var count = 0
        for sample in samples where sample.isFinite { sum += Double(sample) * Double(sample); count += 1 }
        return count == 0 ? 0 : min(1, sqrt(sum / Double(count)))
    }
    public static func waveform(_ values: [Double], appending level: Double) -> [Double] {
        guard level.isFinite else { return values }
        return Array((values + [min(1, max(0, level))]).suffix(32))
    }
}
