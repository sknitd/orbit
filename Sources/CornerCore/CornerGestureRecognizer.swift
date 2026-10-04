import Foundation

public enum CornerPointerEventKind: String, Codable, Sendable {
    case down, up, dragged, moved, modifiersChanged
    case rightDown, rightUp, rightDragged, middleDown, middleUp, middleDragged, scrollUp, scrollDown
}
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

/// Value-type recognizer supplied with actual mouse events and monotonic time.
/// No timer runs without a pending click, dwell, or mapped hold. Right clicks
/// have their own sequences; only left-button dragging can produce a drag action.
public struct CornerGestureRecognizer: Sendable {
    public private(set) var configuration: CornerSettings
    /// Runtime practice policy, never part of persisted action bindings.
    public let recognizeUnassigned: Bool
    private struct Key: Hashable, Sendable { let screenID: String; let corner: Corner }
    private enum Button: String, Hashable, Sendable { case left, right, middle }
    private struct ClickKey: Hashable, Sendable { let location: Key; let button: Button }
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
        /// Required destination modifiers must have remained held throughout
        /// an outside-origin drag, even when another corner permits no keys.
        var continuousModifiers: CornerModifiers
        var maximumDistance: Double = 0
        var sawDrag = false
        var holdEligible = true
        var consumed = false
        var key: Key? { corner.map { Key(screenID: screenID, corner: $0) } }
    }
    private struct HoverVisit: Sendable {
        let key: Key
        let enteredAt: Double
        var point: CornerPoint
        var consumed: Bool
    }
    private var sequences: [ClickKey: ClickSequence] = [:]
    private var lastTrigger: [Key: Double] = [:]
    private var presses: [Button: Press] = [:]
    private var hover: HoverVisit?
    private var latestTime: Double?
    private var latestModifiers: CornerModifiers = []
    /// Late timers after sleep or a stalled main loop never run stale actions.
    public static let maximumTimerLateness: Double = 1
    public init(configuration: CornerSettings = .defaults, recognizeUnassigned: Bool = false) throws {
        self.configuration = try configuration.validated(); self.recognizeUnassigned = recognizeUnassigned
    }
    public var isTrackingPress: Bool { !presses.isEmpty }
    public var nextDeadline: Double? {
        var values = sequences.compactMap { key, value -> Double? in
            presses[key.button]?.key == key.location ? nil : value.lastRelease + configuration.clickInterval
        }
        if let visit = hover, !visit.consumed { values.append(visit.enteredAt + configuration.hoverDelay) }
        if let press = presses[.left], holdIsPending(press) { values.append(press.timestamp + configuration.holdDelay) }
        return values.min()
    }
    public mutating func update(configuration: CornerSettings) throws {
        self.configuration = try configuration.validated(); reset()
    }
    public mutating func reset() {
        cancelPending(); lastTrigger.removeAll(); latestTime = nil; latestModifiers = []
    }
    public mutating func handle(_ event: CornerPointerEvent) -> [CornerTrigger] {
        guard validTime(event.timestamp), event.point.isFinite, !event.screenID.isEmpty else { reset(); return [] }
        guard latestTime.map({ event.timestamp >= $0 }) ?? true else { return [] }
        latestTime = event.timestamp; latestModifiers = event.modifiers
        guard configuration.enabled else { cancelPending(); return [] }
        cancelIneligiblePending()
        // Observe geometry before a deadline flush: exiting a zone exactly at
        // its dwell/hold deadline cancels instead of firing the old corner.
        if event.kind != .modifiersChanged { updatePosition(event) }
        var results = flushPending(at: event.timestamp)
        switch event.kind {
        case .modifiersChanged, .moved:
            break
        case .down, .rightDown, .middleDown:
            let button: Button = event.kind == .down ? .left : (event.kind == .rightDown ? .right : .middle)
            guard presses[button] == nil, configuration.permits(displayID: event.screenID) else { return results }
            if let corner = event.corner {
                let key = Key(screenID: event.screenID, corner: corner)
                let clickKey = ClickKey(location: key, button: button)
                let suppressedTail = sequences[clickKey]?.suppressed == true
                guard eligible(key), suppressedTail || !isCoolingDown(key, at: event.timestamp) else { return results }
            } else {
                guard button == .left, mayTrackOutsidePress() else { return results }
            }
            presses[button] = .init(screenID: event.screenID, corner: event.corner, point: event.point, timestamp: event.timestamp, continuousModifiers: event.modifiers)
        case .dragged, .rightDragged, .middleDragged:
            let button: Button = event.kind == .dragged ? .left : (event.kind == .rightDragged ? .right : .middle)
            if var press = presses[button] { press.sawDrag = true; presses[button] = press }
        case .up, .rightUp, .middleUp:
            let button: Button = event.kind == .up ? .left : (event.kind == .rightUp ? .right : .middle)
            guard let press = presses.removeValue(forKey: button), !press.consumed else { return results }
            if press.maximumDistance >= configuration.dragThreshold {
                if let key = press.key { sequences.removeValue(forKey: .init(location: key, button: button)) }
                guard button == .left, press.sawDrag else { return results }
                if let origin = press.corner {
                    guard event.screenID != press.screenID || event.corner != origin,
                          press.continuousModifiers.isSuperset(of: configuration.requiredModifiers(for: origin)) else { return results }
                    if let value = makeTrigger(key: .init(screenID: press.screenID, corner: origin), gesture: .dragOutOfCorner, at: event.timestamp, point: event.point) { results.append(value) }
                } else if let destination = event.corner {
                    guard press.continuousModifiers.isSuperset(of: configuration.requiredModifiers(for: destination)) else { return results }
                    if let value = makeTrigger(key: .init(screenID: event.screenID, corner: destination), gesture: .dragIntoCorner, at: event.timestamp, point: event.point) { results.append(value) }
                }
                return results
            }
            guard let corner = press.corner, event.screenID == press.screenID, event.corner == corner else { return results }
            let key = Key(screenID: press.screenID, corner: corner)
            if button == .middle {
                if let value = makeTrigger(key: key, gesture: .middleClick, at: event.timestamp, point: event.point) { results.append(value) }
                return results
            }
            let family: [CornerGesture] = button == .right ? [.rightClick, .rightDoubleClick, .rightTripleClick] : [.singleClick, .doubleClick, .tripleClick]
            guard family.contains(where: { mapped($0, at: key) }) else { return results }
            let clickKey = ClickKey(location: key, button: button)
            var sequence = sequences[clickKey] ?? .init(count: 0, lastRelease: event.timestamp, point: event.point, suppressed: false)
            if sequence.suppressed {
                sequence.lastRelease = event.timestamp; sequence.point = event.point; sequences[clickKey] = sequence
                return results
            }
            guard !isCoolingDown(key, at: event.timestamp) else { sequences.removeValue(forKey: clickKey); return results }
            // A held second/third press suspends its sequence's deadline.
            if press.timestamp > sequence.lastRelease + configuration.clickInterval { sequence.count = 0 }
            sequence.count += 1; sequence.lastRelease = event.timestamp; sequence.point = event.point
            if sequence.count == 3 {
                sequence.suppressed = true
                let gesture: CornerGesture = button == .right ? .rightTripleClick : .tripleClick
                if let value = makeTrigger(key: key, gesture: gesture, at: event.timestamp, point: event.point) { results.append(value) }
            }
            sequences[clickKey] = sequence
        case .scrollUp, .scrollDown:
            if let corner = event.corner {
                let gesture: CornerGesture = event.kind == .scrollUp ? .scrollUp : .scrollDown
                if let value = makeTrigger(key: .init(screenID: event.screenID, corner: corner), gesture: gesture, at: event.timestamp, point: event.point) { results.append(value) }
            }
        }
        return results
    }
    public mutating func flush(at timestamp: Double) -> [CornerTrigger] {
        guard validTime(timestamp), latestTime.map({ timestamp >= $0 }) ?? true else { return [] }
        latestTime = timestamp
        guard configuration.enabled else { cancelPending(); return [] }
        return flushPending(at: timestamp)
    }
    private mutating func updatePosition(_ event: CornerPointerEvent) {
        for button in Array(presses.keys) {
            guard var press = presses[button] else { continue }
            press.maximumDistance = max(press.maximumDistance, press.point.distance(to: event.point))
            if event.screenID != press.screenID || event.corner != press.corner || press.maximumDistance >= configuration.dragThreshold {
                press.holdEligible = false
            }
            if press.maximumDistance >= configuration.dragThreshold, let key = press.key {
                sequences.removeValue(forKey: .init(location: key, button: button))
            }
            presses[button] = press
        }
        guard let corner = event.corner else { hover = nil; return }
        let key = Key(screenID: event.screenID, corner: corner)
        guard configuration.permits(displayID: key.screenID), configuration.corners[corner]?.enabled == true,
              mapped(.hover, at: key) else { hover = nil; return }
        if hover?.key != key { hover = .init(key: key, enteredAt: event.timestamp, point: event.point, consumed: !eligible(key)) }
        hover?.point = event.point
        // Buttons, dragging, and scrolling consume this entry rather than
        // scheduling a surprise hover immediately after an intentional action.
        if !eligible(key) || event.kind != .moved || !presses.isEmpty { hover?.consumed = true }
    }
    private mutating func cancelIneligiblePending() {
        sequences = sequences.filter { eligible($0.key.location) }
        for button in Array(presses.keys) {
            guard var press = presses[button] else { continue }
            press.continuousModifiers.formIntersection(latestModifiers)
            let allowed = press.key.map(eligible) ?? mayTrackOutsidePress()
            if !allowed { presses.removeValue(forKey: button) }
            else { presses[button] = press }
        }
        // Modifier loss cancels a pending dwell but cannot create a new physical
        // entry or rearm a completed hover. Only leaving this corner resets it.
        if let visit = hover, !eligible(visit.key) { hover?.consumed = true }
    }
    private mutating func flushPending(at timestamp: Double) -> [CornerTrigger] {
        var results: [CornerTrigger] = []
        if let visit = hover, !visit.consumed, timestamp >= visit.enteredAt + configuration.hoverDelay {
            hover?.consumed = true
            if timestamp - (visit.enteredAt + configuration.hoverDelay) <= Self.maximumTimerLateness,
               let value = makeTrigger(key: visit.key, gesture: .hover, at: timestamp, point: visit.point) { results.append(value) }
        }
        if var press = presses[.left], holdIsPending(press), timestamp >= press.timestamp + configuration.holdDelay {
            press.holdEligible = false
            if timestamp - (press.timestamp + configuration.holdDelay) <= Self.maximumTimerLateness,
               let key = press.key, let value = makeTrigger(key: key, gesture: .longPress, at: timestamp, point: press.point) {
                press.consumed = true; sequences.removeValue(forKey: .init(location: key, button: .left)); results.append(value)
            } else {
                // A late mapped hold must not turn its release into a click.
                press.consumed = true
            }
            presses[.left] = press
        }
        let due = sequences.filter { key, value in presses[key.button]?.key != key.location && timestamp >= value.lastRelease + configuration.clickInterval }.sorted {
            if $0.value.lastRelease != $1.value.lastRelease { return $0.value.lastRelease < $1.value.lastRelease }
            if $0.key.location.screenID != $1.key.location.screenID { return $0.key.location.screenID < $1.key.location.screenID }
            if $0.key.location.corner != $1.key.location.corner { return $0.key.location.corner.rawValue < $1.key.location.corner.rawValue }
            return $0.key.button.rawValue < $1.key.button.rawValue
        }
        for (key, value) in due {
            sequences.removeValue(forKey: key)
            guard !value.suppressed, timestamp - (value.lastRelease + configuration.clickInterval) <= Self.maximumTimerLateness else { continue }
            let gesture: CornerGesture = key.button == .right ? (value.count == 1 ? .rightClick : .rightDoubleClick) : (value.count == 1 ? .singleClick : .doubleClick)
            if let trigger = makeTrigger(key: key.location, gesture: gesture, at: timestamp, point: value.point) { results.append(trigger) }
        }
        return results
    }
    private func holdIsPending(_ press: Press) -> Bool {
        !press.consumed && press.holdEligible && press.key.map { eligible($0) && mapped(.longPress, at: $0) } == true
    }
    private func eligible(_ key: Key) -> Bool {
        configuration.permits(displayID: key.screenID) && configuration.corners[key.corner]?.enabled == true && latestModifiers.isSuperset(of: configuration.requiredModifiers(for: key.corner))
    }
    private func mapped(_ gesture: CornerGesture, at key: Key) -> Bool { recognizeUnassigned || (configuration.corners[key.corner]?.action(for: gesture).kind ?? CornerActionKind.none) != .none }
    private func mayTrackOutsidePress() -> Bool {
        latestModifiers.isSuperset(of: configuration.modifierRequirement) || Corner.allCases.contains {
            configuration.corners[$0]?.enabled == true && (recognizeUnassigned || (configuration.corners[$0]?.action(for: .dragIntoCorner).kind ?? CornerActionKind.none) != .none) && latestModifiers.isSuperset(of: configuration.requiredModifiers(for: $0))
        }
    }
    private mutating func makeTrigger(key: Key, gesture: CornerGesture, at timestamp: Double, point: CornerPoint) -> CornerTrigger? {
        guard eligible(key), mapped(gesture, at: key), !isCoolingDown(key, at: timestamp) else { return nil }
        lastTrigger[key] = timestamp
        return .init(corner: key.corner, gesture: gesture, screenID: key.screenID, timestamp: timestamp, point: point)
    }
    private func isCoolingDown(_ key: Key, at timestamp: Double) -> Bool { lastTrigger[key].map { timestamp - $0 < configuration.cooldown } ?? false }
    private mutating func cancelPending() { sequences.removeAll(); presses.removeAll(); hover = nil }
    private func validTime(_ value: Double) -> Bool { value.isFinite && value >= 0 }
}
