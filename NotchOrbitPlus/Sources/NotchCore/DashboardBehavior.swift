import Foundation

public enum DashboardSpaceBehavior: String, Codable, CaseIterable, Sendable, Identifiable {
    case allSpaces, currentSpace
    public var id: String { rawValue }
    public var title: String { self == .allSpaces ? "All Spaces" : "Current Space" }
}

public struct DashboardDisplayRule: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var width: Double?
    public init(enabled: Bool = true, width: Double? = nil) { self.enabled = enabled; self.width = width }
    public func validated() throws -> Self {
        if let width, !width.isFinite || !(560...800).contains(width) {
            throw DashboardBehaviorFailure.invalid("Display widths must be between 560 and 800 points.")
        }
        return self
    }
}

public enum DashboardBehaviorFailure: LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public enum DashboardBehavior {
    public static func validate(_ rules: [String: DashboardDisplayRule]) throws {
        guard rules.count <= 32 else { throw DashboardBehaviorFailure.invalid("At most 32 display rules can be saved.") }
        for (id, rule) in rules {
            guard let numeric = UInt32(id), numeric > 0, String(numeric) == id else {
                throw DashboardBehaviorFailure.invalid("A saved display identifier is invalid.")
            }
            _ = try rule.validated()
        }
    }
    /// Never infer fullscreen from a large window or conceal a different display.
    public static func shouldHideFullscreen(enabled: Bool, accessibilityAvailable: Bool,
                                            isFullscreen: Bool, windowDisplayID: UInt32?, panelDisplayID: UInt32?) -> Bool {
        enabled && accessibilityAvailable && isFullscreen && windowDisplayID != nil
            && windowDisplayID == panelDisplayID
    }
    public static func neighboringTool(current: String?, orderedVisibleIDs: [String], offset: Int) -> String? {
        guard !orderedVisibleIDs.isEmpty, offset == 1 || offset == -1 else { return nil }
        let currentIndex = current.flatMap { orderedVisibleIDs.firstIndex(of: $0) } ?? 0
        let index = (currentIndex + offset + orderedVisibleIDs.count) % orderedVisibleIDs.count
        return orderedVisibleIDs[index]
    }
}
