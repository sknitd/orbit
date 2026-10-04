import Foundation

/// AppKit global screen coordinates: x increases right, y increases upward.
public struct CornerPoint: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isFinite: Bool { x.isFinite && y.isFinite }
    public func distance(to other: CornerPoint) -> Double { hypot(x - other.x, y - other.y) }
}
public struct CornerRect: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isValid: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0 && maxX.isFinite && maxY.isFinite }
    public func contains(_ point: CornerPoint) -> Bool { isValid && point.isFinite && point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY }
}
public struct CornerScreen: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let frame: CornerRect
    public init(id: String, frame: CornerRect) { self.id = id; self.frame = frame }
}
public enum CornerGeometry {
    public static func region(for corner: Corner, in frame: CornerRect, size: Double) -> CornerRect? {
        guard frame.isValid, size.isFinite, size > 0 else { return nil }
        let edge = min(size, min(frame.width, frame.height) / 2)
        switch corner {
        case .topLeft: return .init(x: frame.minX, y: frame.maxY - edge, width: edge, height: edge)
        case .topRight: return .init(x: frame.maxX - edge, y: frame.maxY - edge, width: edge, height: edge)
        case .bottomLeft: return .init(x: frame.minX, y: frame.minY, width: edge, height: edge)
        case .bottomRight: return .init(x: frame.maxX - edge, y: frame.minY, width: edge, height: edge)
        }
    }
    public static func corner(at point: CornerPoint, in frame: CornerRect, size: Double) -> Corner? {
        guard frame.contains(point), size.isFinite, size > 0 else { return nil }
        // At a shared boundary on a very small display, choose the closest physical
        // corner with a stable enum-order tie break rather than emitting two corners.
        return Corner.allCases.filter { region(for: $0, in: frame, size: size)?.contains(point) == true }.min {
            distance(point, to: $0, in: frame) < distance(point, to: $1, in: frame)
        }
    }
    public static func screen(at point: CornerPoint, among screens: [CornerScreen]) -> CornerScreen? {
        screens.filter { $0.frame.contains(point) }.sorted { $0.id < $1.id }.first
    }
    private static func distance(_ point: CornerPoint, to corner: Corner, in frame: CornerRect) -> Double {
        let x = (corner == .topLeft || corner == .bottomLeft) ? frame.minX : frame.maxX
        let y = (corner == .topLeft || corner == .topRight) ? frame.maxY : frame.minY
        return point.distance(to: .init(x: x, y: y))
    }
}
