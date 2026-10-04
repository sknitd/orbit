import Foundation

public struct CornerWindowDisplay: Equatable, Sendable {
    public let id: String
    public let frame: CornerRect
    public let visibleFrame: CornerRect
    public init(id: String, frame: CornerRect, visibleFrame: CornerRect) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame
    }
}

public enum CornerWindowPlacement: Sendable { case left, right, maximize, center, nextDisplay }

public enum CornerWindowLayout {
    /// AX uses top-left coordinates anchored to the primary display. AppKit uses
    /// global bottom-left coordinates. Both APIs use points, including on Retina.
    public static func accessibilityRect(fromGlobal rect: CornerRect, primary: CornerRect) throws -> CornerRect {
        guard rect.isValid, primary.isValid else { throw CornerActionError.invalid("The window or display frame is invalid.") }
        let result = CornerRect(x: rect.x - primary.x, y: primary.maxY - rect.maxY, width: rect.width, height: rect.height)
        guard result.isValid else { throw CornerActionError.invalid("The coordinate conversion exceeds the supported range.") }
        return result
    }
    public static func globalRect(fromAccessibility rect: CornerRect, primary: CornerRect) throws -> CornerRect {
        guard rect.isValid, primary.isValid else { throw CornerActionError.invalid("The window or display frame is invalid.") }
        let result = CornerRect(x: rect.x + primary.x, y: primary.maxY - rect.maxY, width: rect.width, height: rect.height)
        guard result.isValid else { throw CornerActionError.invalid("The coordinate conversion exceeds the supported range.") }
        return result
    }
    public static func display(for window: CornerRect, among displays: [CornerWindowDisplay]) throws -> CornerWindowDisplay {
        guard window.isValid, !displays.isEmpty, displays.count <= 32,
              Set(displays.map(\.id)).count == displays.count,
              displays.allSatisfy({ !$0.id.isEmpty && $0.frame.isValid && $0.visibleFrame.isValid }) else {
            throw CornerActionError.invalid("Valid connected display geometry is unavailable.")
        }
        return displays.sorted {
            let a = intersectionArea(window, $0.frame), b = intersectionArea(window, $1.frame)
            if a != b { return a > b }
            let aDistance = distance(window, $0.frame), bDistance = distance(window, $1.frame)
            if aDistance != bDistance { return aDistance < bDistance }
            return $0.id < $1.id
        }[0]
    }
    public static func target(_ placement: CornerWindowPlacement, window: CornerRect,
                              displays: [CornerWindowDisplay]) throws -> CornerRect {
        let current = try display(for: window, among: displays)
        let visible = current.visibleFrame
        switch placement {
        case .left: return .init(x: visible.x, y: visible.y, width: visible.width / 2, height: visible.height)
        case .right: return .init(x: visible.x + visible.width / 2, y: visible.y, width: visible.width / 2, height: visible.height)
        case .maximize: return visible
        case .center:
            return centered(window, in: visible)
        case .nextDisplay:
            guard displays.count > 1 else { throw CornerActionError.invalid("Connect another display before moving the window.") }
            // Native order begins with the primary screen; keeping that order
            // makes repeated next-display actions cycle predictably.
            let index = displays.firstIndex(where: { $0.id == current.id })!
            let destination = displays[(index + 1) % displays.count].visibleFrame
            let relativeX = min(1, max(0, (window.x + window.width / 2 - visible.x) / visible.width))
            let relativeY = min(1, max(0, (window.y + window.height / 2 - visible.y) / visible.height))
            let x = destination.x + destination.width * relativeX - window.width / 2
            let y = destination.y + destination.height * relativeY - window.height / 2
            return .init(x: window.width <= destination.width ? min(destination.maxX - window.width, max(destination.x, x)) : destination.x + (destination.width - window.width) / 2,
                         y: window.height <= destination.height ? min(destination.maxY - window.height, max(destination.y, y)) : destination.y + (destination.height - window.height) / 2,
                         width: window.width, height: window.height)
        }
    }
    public static func approximatelyEqual(_ a: CornerRect, _ b: CornerRect, tolerance: Double = 1) -> Bool {
        a.isValid && b.isValid && tolerance.isFinite && tolerance >= 0 &&
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
    private static func centered(_ window: CornerRect, in visible: CornerRect) -> CornerRect {
        .init(x: visible.x + (visible.width - window.width) / 2, y: visible.y + (visible.height - window.height) / 2,
              width: window.width, height: window.height)
    }
    private static func intersectionArea(_ a: CornerRect, _ b: CornerRect) -> Double {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) * max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }
    private static func distance(_ a: CornerRect, _ b: CornerRect) -> Double {
        hypot((a.x + a.width / 2) - (b.x + b.width / 2), (a.y + a.height / 2) - (b.y + b.height / 2))
    }
}
