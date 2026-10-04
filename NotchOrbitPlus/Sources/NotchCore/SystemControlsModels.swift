import Foundation

public enum SystemControlKind: String, Codable, Sendable { case volume, brightness }
public enum SystemMediaKey: Int, CaseIterable, Sendable {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    public var kind: SystemControlKind {
        switch self { case .volumeUp, .volumeDown, .mute: .volume; case .brightnessUp, .brightnessDown: .brightness }
    }
}
public enum SystemMediaKeyPhase: Sendable { case pressed, released }
public struct SystemMediaKeyEvent: Sendable, Equatable {
    public let key: SystemMediaKey
    public let phase: SystemMediaKeyPhase
    public let isRepeat: Bool
    /// Public NSEvent systemDefined auxiliary-control encoding. Other subtypes,
    /// keys, and phases are not ours to suppress.
    public init?(subtype: Int, data1: Int) {
        guard subtype == 8 else { return nil }
        let bits = UInt32(truncatingIfNeeded: data1)
        guard let key = SystemMediaKey(rawValue: Int((bits >> 16) & 0xffff)) else { return nil }
        let state = (bits >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return nil }
        self.key = key; phase = state == 0x0a ? .pressed : .released
        isRepeat = bits & 1 != 0
    }
}
public enum SystemControlLevel {
    public static func valid(_ value: Double) -> Double? {
        value.isFinite && (0...1).contains(value) ? value : nil
    }
    public static func stepped(_ value: Double, increasing: Bool, step: Double = 1.0 / 16) -> Double? {
        guard let current = valid(value), step.isFinite, step > 0, step <= 1 else { return nil }
        return min(1, max(0, current + (increasing ? step : -step)))
    }
}
public struct SystemHUDSnapshot: Sendable, Equatable {
    public let kind: SystemControlKind
    public let level: Double
    public let muted: Bool
    public let date: Date
    public init?(kind: SystemControlKind, level: Double, muted: Bool = false, date: Date = Date()) {
        guard let value = SystemControlLevel.valid(level) else { return nil }
        self.kind = kind; self.level = value; self.muted = kind == .volume && muted; self.date = date
    }
    public var symbol: String { kind == .brightness ? "sun.max.fill" : muted || level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill" }
    public var label: String { kind == .brightness ? "Brightness" : muted ? "Muted" : "Volume" }
    public var percent: Int { Int((level * 100).rounded()) }
}
