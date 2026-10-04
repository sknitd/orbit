import Foundation

public struct NotchPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct NotchRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public func contains(_ point: NotchPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && width > 0 && height > 0 &&
            point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
    public func intersects(_ rect: NotchRect) -> Bool {
        width > 0 && height > 0 && rect.width > 0 && rect.height > 0 &&
            minX < rect.maxX && maxX > rect.minX && minY < rect.maxY && maxY > rect.minY
    }
    public func expanded(by margin: Double) -> NotchRect {
        let amount = max(0, margin.isFinite ? margin : 0)
        return NotchRect(x: x - amount, y: y - amount, width: width + amount * 2, height: height + amount * 2)
    }
}

public struct NotchScreenMetrics: Equatable, Sendable {
    public let frame: NotchRect
    public let visibleFrame: NotchRect
    public let safeTopInset: Double
    public let auxiliaryLeftFrame: NotchRect?
    public let auxiliaryRightFrame: NotchRect?
    public init(frame: NotchRect, visibleFrame: NotchRect, safeTopInset: Double = 0,
                auxiliaryLeftFrame: NotchRect? = nil, auxiliaryRightFrame: NotchRect? = nil) {
        self.frame = frame; self.visibleFrame = visibleFrame; self.safeTopInset = safeTopInset
        self.auxiliaryLeftFrame = auxiliaryLeftFrame; self.auxiliaryRightFrame = auxiliaryRightFrame
    }
}

/// AppKit point coordinates: x points right, y up. Only the lower semicircle
/// is selectable; angles run from left (0) through down (pi/2) to right (pi).
public struct NotchGeometry: Equatable, Sendable {
    public let primaryInnerRadius: Double
    public let primaryOuterRadius: Double
    public let optionInnerRadius: Double
    public let optionOuterRadius: Double
    public let slotCount: Int
    public let angularGap: Double
    public init(primaryInnerRadius: Double = 108, primaryOuterRadius: Double = 170,
                optionInnerRadius: Double = 182, optionOuterRadius: Double = 280,
                slotCount: Int = 8, angularGap: Double = 0.022) {
        self.primaryInnerRadius = primaryInnerRadius; self.primaryOuterRadius = primaryOuterRadius
        self.optionInnerRadius = optionInnerRadius; self.optionOuterRadius = optionOuterRadius
        self.slotCount = slotCount; self.angularGap = angularGap
    }
    public func primarySlot(at point: NotchPoint) -> Int? {
        guard inBand(point, inner: primaryInnerRadius, outer: primaryOuterRadius) else { return nil }
        return Self.sectorIndex(at: point, count: slotCount, gap: angularGap)
    }
    public func optionIndex(at point: NotchPoint, count: Int) -> Int? {
        guard inBand(point, inner: optionInnerRadius, outer: optionOuterRadius) else { return nil }
        return Self.sectorIndex(at: point, count: count, gap: angularGap)
    }
    public static func point(radius: Double, angle: Double) -> NotchPoint {
        NotchPoint(x: -cos(angle) * radius, y: -sin(angle) * radius)
    }
    public static func sectorCenterAngle(index: Int, count: Int) -> Double {
        guard count > 0 else { return .pi / 2 }
        return (Double(index) + 0.5) * .pi / Double(count)
    }
    public static func sectorIndex(at point: NotchPoint, count: Int, gap: Double = 0.022) -> Int? {
        guard count > 0, point.x.isFinite, point.y.isFinite, point.y < 0 else { return nil }
        let angle = atan2(-point.y, -point.x)
        guard angle > 0, angle < .pi else { return nil }
        let step = Double.pi / Double(count)
        let index = min(count - 1, Int(floor(angle / step)))
        let offset = angle - Double(index) * step
        let separator = min(step / 2, max(0, gap.isFinite ? gap : 0) / 2)
        guard offset > separator, offset < step - separator else { return nil }
        return index
    }
    private func inBand(_ point: NotchPoint, inner: Double, outer: Double) -> Bool {
        guard point.x.isFinite, point.y.isFinite, point.y < 0,
              inner.isFinite, outer.isFinite, inner > 0, outer > inner else { return false }
        let radius = hypot(point.x, point.y)
        return radius >= inner && radius <= outer
    }
}

/// Shared layout is the authority for activation, the transport corridor, and
/// panel placement. The panel never covers the hardware notch or menu bar.
public struct NotchLayout: Equatable, Sendable {
    public let screenID: UInt32?
    public let screenFrame: NotchRect
    public let visibleFrame: NotchRect
    public let notchRect: NotchRect?
    public let frame: NotchRect
    public let anchor: NotchPoint
    public let activationRegion: NotchRect
    public let activeRegion: NotchRect
    public let scale: Double
    public let geometry: NotchGeometry

    public init(metrics: NotchScreenMetrics, screenID: UInt32? = nil) {
        self.screenID = screenID
        screenFrame = metrics.frame
        visibleFrame = metrics.visibleFrame
        let inset = min(max(0, metrics.safeTopInset.isFinite ? metrics.safeTopInset : 0), max(0, metrics.frame.height))
        if inset > 0 {
            let left = metrics.auxiliaryLeftFrame?.maxX ?? metrics.frame.midX - 90
            let right = metrics.auxiliaryRightFrame?.minX ?? metrics.frame.midX + 90
            let width = max(0, right - left)
            notchRect = NotchRect(x: left, y: metrics.frame.maxY - inset, width: width, height: inset)
        } else { notchRect = nil }

        let top = min(metrics.visibleFrame.maxY, metrics.frame.maxY - inset) - 6
        let availableWidth = max(0, metrics.visibleFrame.width - 24)
        let availableHeight = max(0, top - metrics.visibleFrame.minY - 12)
        scale = max(0, min(1, min(availableWidth / 620, availableHeight / 310)))
        let width = 620 * scale
        let height = 310 * scale
        let intendedCenter = notchRect?.midX ?? metrics.frame.midX
        let x = max(metrics.visibleFrame.minX + 12,
                    min(intendedCenter - width / 2, metrics.visibleFrame.maxX - 12 - width))
        frame = NotchRect(x: x, y: top - height, width: width, height: height)
        anchor = NotchPoint(x: frame.midX, y: top)
        let targetWidth = min(metrics.frame.width, max(240, (notchRect?.width ?? 120) + 100))
        let targetBottom = max(metrics.frame.minY, top - 68)
        activationRegion = NotchRect(x: intendedCenter - targetWidth / 2, y: targetBottom,
                                     width: targetWidth, height: max(0, metrics.frame.maxY - targetBottom))
        let expandedPanel = frame.expanded(by: 30)
        activeRegion = NotchRect(x: min(expandedPanel.minX, activationRegion.minX), y: expandedPanel.minY,
                                width: max(expandedPanel.maxX, activationRegion.maxX) - min(expandedPanel.minX, activationRegion.minX),
                                height: metrics.frame.maxY - expandedPanel.minY)
        geometry = NotchGeometry(primaryInnerRadius: 108 * scale, primaryOuterRadius: 170 * scale,
                                 optionInnerRadius: 182 * scale, optionOuterRadius: 280 * scale)
    }

    public func relativePoint(_ global: NotchPoint) -> NotchPoint {
        NotchPoint(x: global.x - anchor.x, y: global.y - anchor.y)
    }
}
