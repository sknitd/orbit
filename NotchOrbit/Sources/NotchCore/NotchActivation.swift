import Foundation

/// All rectangles use AppKit global points: x right, y up, including negative
/// coordinates on secondary displays. The UI's shared layout defines both the
/// small activation target and the expanded panel's safe transport corridor.
public struct NotchActivationZone: Equatable, Sendable {
    public let screenID: UInt32
    public let screenFrame: NotchRect
    public let layout: NotchLayout

    public init(screenID: UInt32, screenFrame: NotchRect, layout: NotchLayout) {
        self.screenID = screenID
        self.screenFrame = screenFrame
        self.layout = layout
    }
}

public struct NotchActivation: Equatable, Sendable {
    public let generation: UInt64
    public let zone: NotchActivationZone

    public init(generation: UInt64, zone: NotchActivationZone) {
        self.generation = generation
        self.zone = zone
    }
}

/// These effects only govern presentation. In particular, releasePending is
/// not an instruction to execute an action. A real drop destination owns that.
public enum NotchActivationTransition: Equatable, Sendable {
    case none
    case activate(NotchActivation)
    case cancel
    case releasePending(NotchActivation)
}

/// Portable drag presentation state. A fresh mouse-down, an actual drag event,
/// and a new file-URL pasteboard are all required. No timer or key state is used.
public struct NotchActivationTracker: Sendable {
    public private(set) var current: NotchActivation?
    public private(set) var mouseIsDown = false
    public private(set) var awaitingDrop = false
    private var generation: UInt64 = 0
    private var initialPasteboardCount: Int?
    private var payloadPasteboardCount: Int?

    public init() {}

    @discardableResult
    public mutating func begin(pasteboardCount: Int) -> NotchActivationTransition {
        let transition = cancel()
        initialPasteboardCount = pasteboardCount
        mouseIsDown = true
        return transition
    }

    @discardableResult
    public mutating func dragged(
        at point: NotchPoint,
        pasteboardCount: Int,
        hasFileURLs: Bool,
        zones: [NotchActivationZone]
    ) -> NotchActivationTransition {
        guard mouseIsDown, let initialPasteboardCount else { return .none }
        guard pasteboardCount != initialPasteboardCount else {
            return current == nil ? .none : cancel()
        }
        if let payloadPasteboardCount, payloadPasteboardCount != pasteboardCount {
            // Once this gesture has a payload, another writer invalidates it.
            // Re-entering the target cannot adopt a different file session.
            return cancel()
        }
        guard hasFileURLs else {
            return current == nil ? .none : cancel()
        }
        payloadPasteboardCount = pasteboardCount

        if let current {
            // A same-ID display can change resolution, safe area, or usable
            // bounds. The existing panel and async inspector are valid only
            // for the exact layout that originally activated this generation.
            let zoneStillMatches = zones.contains { $0 == current.zone }
            guard zoneStillMatches, current.zone.screenFrame.contains(point),
                  current.zone.layout.activeRegion.contains(point) else {
                // Keep this physical drag eligible for a later deliberate
                // re-entry, but give that presentation a different generation.
                self.current = nil
                generation += 1
                return .cancel
            }
            return .none
        }

        // Selecting the screen before its target prevents a neighboring
        // display's top-center geometry from activating on this display.
        guard let zone = zones.first(where: {
            $0.screenFrame.contains(point) && $0.layout.scale > 0 &&
                $0.layout.activationRegion.contains(point)
        }) else { return .none }
        generation += 1
        let activation = NotchActivation(generation: generation, zone: zone)
        current = activation
        awaitingDrop = false
        return .activate(activation)
    }

    @discardableResult
    public mutating func release() -> NotchActivationTransition {
        guard mouseIsDown else { return .none }
        mouseIsDown = false
        guard let current else {
            initialPasteboardCount = nil
            payloadPasteboardCount = nil
            return .none
        }
        awaitingDrop = true
        return .releasePending(current)
    }

    @discardableResult
    public mutating func cancel() -> NotchActivationTransition {
        let wasPresenting = current != nil
        generation += 1
        current = nil
        mouseIsDown = false
        awaitingDrop = false
        initialPasteboardCount = nil
        payloadPasteboardCount = nil
        return wasPresenting ? .cancel : .none
    }

    /// An inspector must recheck this after every await. Even during the drop
    /// grace period, release must not allow a late first presentation to appear.
    public func isCurrent(_ generation: UInt64) -> Bool {
        mouseIsDown && !awaitingDrop && current?.generation == generation
    }
}

/// Candidate payload equality without filesystem IO. The real destination
/// additionally checks existence, readability, action support, and its wedge.
public enum NotchDragPayload {
    public static func matches(observed: [URL], dropped: [URL]) -> Bool {
        guard !observed.isEmpty, observed.count == dropped.count,
              let source = canonicalLocalPaths(observed),
              let destination = canonicalLocalPaths(dropped) else { return false }
        return source == destination
    }

    private static func canonicalLocalPaths(_ urls: [URL]) -> Set<String>? {
        var paths = Set<String>()
        for url in urls {
            let host = (url.host ?? "").lowercased()
            guard url.isFileURL, host.isEmpty || host == "localhost",
                  url.path.hasPrefix("/"), url.query == nil, url.fragment == nil,
                  paths.insert(url.standardizedFileURL.path).inserted else { return nil }
        }
        return paths
    }
}
