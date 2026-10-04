import Foundation

public enum CornerPointerEventKind: String, Codable, Sendable { case down, up, dragged, moved, modifiersChanged }
public struct CornerPointerEvent: Equatable, Sendable {
    public let kind: CornerPointerEventKind
    public let screenID: String
    public let corner: Corner?
    public let point: CornerPoint
    /// A monotonic clock shared by pointer events and flush calls, in seconds.
    public let timestamp: Double
    public let modifiers: CornerModifiers
    public init(kind: CornerPointerEventKind, screenID: String, corner: Corner?, point: CornerPoint, timestamp: Double, modifiers: CornerModifiers = []) {
        self.kind = kind; self.screenID = screenID; self.corner = corner
        self.point = point; self.timestamp = timestamp; self.modifiers = modifiers
    }
}
public struct CornerTrigger: Equatable, Sendable {
    public let corner: Corner
    public let gesture: CornerGesture
    public let screenID: String
    public let timestamp: Double
    public let point: CornerPoint
    public init(corner: Corner, gesture: CornerGesture, screenID: String, timestamp: Double, point: CornerPoint) {
        self.corner = corner; self.gesture = gesture; self.screenID = screenID; self.timestamp = timestamp; self.point = point
    }
}

/// Value-type recognizer. The native adapter supplies actual left-button events,
/// current screen/corner geometry, monotonic time and modifier snapshots.
public struct CornerGestureRecognizer: Sendable {
    public private(set) var configuration: CornerSettings
    private struct Key: Hashable, Sendable { let screenID: String; let corner: Corner }
    private struct ClickSequence: Sendable {
        var count: Int
        var lastRelease: Double
        var point: CornerPoint
        var suppressed: Bool
    }
    private struct Press: Sendable {
        let screenID: String
        let corner: Corner?
        let point: CornerPoint
        let timestamp: Double
        var maximumDistance: Double = 0
        var sawDrag = false
        var key: Key? { corner.map { Key(screenID: screenID, corner: $0) } }
    }
    private var sequences: [Key: ClickSequence] = [:]
    private var lastTrigger: [Key: Double] = [:]
    private var press: Press?
    private var latestTime: Double?
    /// Late timers after sleep or a stalled main loop do not run stale actions.
    public static let maximumTimerLateness: Double = 1
    public init(configuration: CornerSettings = .defaults) throws { self.configuration = try configuration.validated() }
    public var isTrackingPress: Bool { press != nil }
    public var nextDeadline: Double? {
        sequences.filter { $0.key != press?.key }.map { $0.value.lastRelease + configuration.clickInterval }.min()
    }
    public mutating func update(configuration: CornerSettings) throws {
        let valid = try configuration.validated()
        self.configuration = valid; reset()
    }
    public mutating func reset() {
        sequences.removeAll(); lastTrigger.removeAll(); press = nil; latestTime = nil
    }
    public mutating func handle(_ event: CornerPointerEvent) -> [CornerTrigger] {
        guard validTime(event.timestamp), event.point.isFinite, !event.screenID.isEmpty else { reset(); return [] }
        guard latestTime.map({ event.timestamp >= $0 }) ?? true else { return [] }
        latestTime = event.timestamp
        guard configuration.enabled, event.modifiers.isSuperset(of: configuration.modifierRequirement) else {
            cancelPending(); return []
        }
        var results = flushPending(at: event.timestamp)
        switch event.kind {
        case .modifiersChanged:
            break
        case .down:
            // Duplicate down events do not restart a held press or repeat a click.
            guard press == nil else { return results }
            guard configuration.permits(displayID: event.screenID) else { return results }
            if let corner = event.corner {
                let key = Key(screenID: event.screenID, corner: corner)
                // A triple tail must keep extending its quiet window even while
                // cooldown blocks actions; otherwise a held fourth click could
                // let the fifth become an unexpected fresh single.
                let suppressedTail = sequences[key]?.suppressed == true
                guard configuration.corners[corner]?.enabled == true,
                      suppressedTail || !isCoolingDown(key, at: event.timestamp) else { return results }
            }
            press = .init(screenID: event.screenID, corner: event.corner, point: event.point, timestamp: event.timestamp)
        case .moved, .dragged:
            guard var current = press else { return results }
            current.maximumDistance = max(current.maximumDistance, current.point.distance(to: event.point))
            current.sawDrag = current.sawDrag || event.kind == .dragged
            if current.maximumDistance >= configuration.dragThreshold, let key = current.key { sequences.removeValue(forKey: key) }
            press = current
        case .up:
            guard var current = press else { return results }
            current.maximumDistance = max(current.maximumDistance, current.point.distance(to: event.point))
            press = nil
            if current.maximumDistance >= configuration.dragThreshold {
                if let key = current.key { sequences.removeValue(forKey: key) }
                guard current.sawDrag else { return results }
                if let origin = current.corner {
                    // One release has one meaning: leaving an origin corner is out,
                    // even if it lands in another display/corner.
                    guard event.screenID != current.screenID || event.corner != origin else { return results }
                    if let trigger = makeTrigger(key: .init(screenID: current.screenID, corner: origin), gesture: .dragOutOfCorner, at: event.timestamp, point: event.point) { results.append(trigger) }
                } else if let destination = event.corner {
                    if let trigger = makeTrigger(key: .init(screenID: event.screenID, corner: destination), gesture: .dragIntoCorner, at: event.timestamp, point: event.point) { results.append(trigger) }
                }
                return results
            }
            guard let corner = current.corner, event.screenID == current.screenID, event.corner == corner else { return results }
            let key = Key(screenID: current.screenID, corner: corner)
            var sequence = sequences[key] ?? .init(count: 0, lastRelease: event.timestamp, point: event.point, suppressed: false)
            if sequence.suppressed {
                sequence.lastRelease = event.timestamp; sequence.point = event.point; sequences[key] = sequence
                return results
            }
            guard !isCoolingDown(key, at: event.timestamp) else { sequences.removeValue(forKey: key); return results }
            // A down within the pending window can complete after that window;
            // while held, its deadline is suspended instead of firing a single.
            if current.timestamp > sequence.lastRelease + configuration.clickInterval { sequence.count = 0 }
            sequence.count += 1; sequence.lastRelease = event.timestamp; sequence.point = event.point
            if sequence.count == 3 {
                sequence.suppressed = true
                if let trigger = makeTrigger(key: key, gesture: .tripleClick, at: event.timestamp, point: event.point) { results.append(trigger) }
            }
            sequences[key] = sequence
        }
        return results
    }
    public mutating func flush(at timestamp: Double) -> [CornerTrigger] {
        guard validTime(timestamp), latestTime.map({ timestamp >= $0 }) ?? true else { return [] }
        latestTime = timestamp
        guard configuration.enabled else { cancelPending(); return [] }
        // The native adapter refreshes required modifier flags before flushing;
        // a missing mask is delivered as a modifiersChanged event to cancel.
        return flushPending(at: timestamp)
    }
    private mutating func flushPending(at timestamp: Double) -> [CornerTrigger] {
        var results: [CornerTrigger] = []
        let due = sequences.filter { key, value in key != press?.key && timestamp >= value.lastRelease + configuration.clickInterval }.sorted {
            let left = $0.value.lastRelease + configuration.clickInterval
            let right = $1.value.lastRelease + configuration.clickInterval
            if left != right { return left < right }
            if $0.key.screenID != $1.key.screenID { return $0.key.screenID < $1.key.screenID }
            return $0.key.corner.rawValue < $1.key.corner.rawValue
        }
        for (key, value) in due {
            sequences.removeValue(forKey: key)
            let deadline = value.lastRelease + configuration.clickInterval
            guard !value.suppressed, timestamp - deadline <= Self.maximumTimerLateness else { continue }
            let gesture: CornerGesture = value.count == 1 ? .singleClick : .doubleClick
            if let trigger = makeTrigger(key: key, gesture: gesture, at: timestamp, point: value.point) { results.append(trigger) }
        }
        return results
    }
    private mutating func makeTrigger(key: Key, gesture: CornerGesture, at timestamp: Double, point: CornerPoint) -> CornerTrigger? {
        guard configuration.permits(displayID: key.screenID), let corner = configuration.corners[key.corner], corner.enabled,
              corner.action(for: gesture).kind != .none, !isCoolingDown(key, at: timestamp) else { return nil }
        lastTrigger[key] = timestamp
        return .init(corner: key.corner, gesture: gesture, screenID: key.screenID, timestamp: timestamp, point: point)
    }
    private func isCoolingDown(_ key: Key, at timestamp: Double) -> Bool { lastTrigger[key].map { timestamp - $0 < configuration.cooldown } ?? false }
    private mutating func cancelPending() { sequences.removeAll(); press = nil }
    private func validTime(_ value: Double) -> Bool { value.isFinite && value >= 0 }
}
