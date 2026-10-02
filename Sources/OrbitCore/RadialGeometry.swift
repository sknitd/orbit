import Foundation

/// Coordinates use AppKit's orientation: positive y points up. Angles are
/// clockwise from north, independent of display origins and Retina scale.
public struct RadialPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct RadialSize: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct RadialRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct RadialGeometry: Equatable, Sendable {
    public let primaryInnerRadius: Double
    public let primaryOuterRadius: Double
    public let optionInnerRadius: Double
    public let optionOuterRadius: Double
    public let slotCount: Int

    public init(primaryInnerRadius: Double = 62, primaryOuterRadius: Double = 113,
                optionInnerRadius: Double = 123, optionOuterRadius: Double = 187,
                slotCount: Int = 8) {
        self.primaryInnerRadius = primaryInnerRadius
        self.primaryOuterRadius = primaryOuterRadius
        self.optionInnerRadius = optionInnerRadius
        self.optionOuterRadius = optionOuterRadius
        self.slotCount = slotCount
    }

    public func primarySlot(at point: RadialPoint) -> Int? {
        guard isInAnnulus(point, inner: primaryInnerRadius, outer: primaryOuterRadius) else { return nil }
        return Self.sectorIndex(at: point, count: slotCount)
    }

    public func optionIndex(at point: RadialPoint, count: Int, anchorSlot: Int) -> Int? {
        guard isInAnnulus(point, inner: optionInnerRadius, outer: optionOuterRadius),
              slotCount > 0, (0..<slotCount).contains(anchorSlot) else { return nil }
        return Self.sectorIndex(at: point, count: count,
                                anchorAngle: Self.sectorCenterAngle(index: anchorSlot, count: slotCount))
    }

    public static func angle(at point: RadialPoint) -> Double {
        normalizedAngle(atan2(point.x, point.y))
    }

    public static func sectorCenterAngle(index: Int, count: Int, anchorAngle: Double = 0) -> Double {
        guard count > 0 else { return normalizedAngle(anchorAngle) }
        return normalizedAngle(anchorAngle + Double(index) * 2 * .pi / Double(count))
    }

    public static func point(radius: Double, angle: Double) -> RadialPoint {
        RadialPoint(x: sin(angle) * radius, y: cos(angle) * radius)
    }

    public static func sectorIndex(at point: RadialPoint, count: Int, anchorAngle: Double = 0) -> Int? {
        guard count > 0, point.x.isFinite, point.y.isFinite,
              point.x != 0 || point.y != 0 else { return nil }
        let step = 2 * Double.pi / Double(count)
        let relative = normalizedAngle(angle(at: point) - anchorAngle + step / 2)
        return min(count - 1, Int(floor(relative / step)))
    }

    public static func normalizedAngle(_ angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        let circle = 2 * Double.pi
        let result = angle.truncatingRemainder(dividingBy: circle)
        return result < 0 ? result + circle : result
    }

    /// Shrinks oversized panels before clamping, including screens with negative origins.
    public static func clampedFrame(center: RadialPoint, size: RadialSize,
                                    visibleFrame: RadialRect, margin: Double = 12) -> RadialRect {
        let safeMargin = max(0, min(margin, min(visibleFrame.width, visibleFrame.height) / 2))
        let width = max(0, min(size.width, visibleFrame.width - safeMargin * 2))
        let height = max(0, min(size.height, visibleFrame.height - safeMargin * 2))
        let x = max(visibleFrame.x + safeMargin,
                    min(center.x - width / 2, visibleFrame.x + visibleFrame.width - safeMargin - width))
        let y = max(visibleFrame.y + safeMargin,
                    min(center.y - height / 2, visibleFrame.y + visibleFrame.height - safeMargin - height))
        return RadialRect(x: x, y: y, width: width, height: height)
    }

    private func isInAnnulus(_ point: RadialPoint, inner: Double, outer: Double) -> Bool {
        guard point.x.isFinite, point.y.isFinite, inner >= 0, outer >= inner else { return false }
        let radius = hypot(point.x, point.y)
        return radius >= inner && radius <= outer
    }
}
