import AppKit
import CoreGraphics
import CornerCore

struct CornerDisplayChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// Coordinates are global AppKit points, independent of backing pixel scale.
@MainActor
enum CornerScreenGeometry {
    static func identifier(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
        }
        // The fallback explicitly identifies a current-session display number.
        // Numeric CGDirectDisplayIDs are not claimed stable across reboots.
        return "display-\(number.uint32Value)"
    }
    static func currentScreens() -> [CornerScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = identifier(for: screen) else { return nil }
            let frame = screen.frame
            return CornerScreen(id: id,
                                frame: CornerRect(x: Double(frame.minX), y: Double(frame.minY),
                                                  width: Double(frame.width), height: Double(frame.height)))
        }
    }
    static func screens() -> [CornerScreen] { currentScreens() }
    static func availableDisplays() -> [CornerDisplayChoice] {
        NSScreen.screens.compactMap { screen in
            guard let id = identifier(for: screen) else { return nil }
            let label = id.hasPrefix("display-") ? screen.localizedName + " (current session)" : screen.localizedName
            return CornerDisplayChoice(id: id, name: label)
        }
    }

    /// Quartz has a top-left origin on the primary display. Flip once around
    /// that display, never around the screen under the pointer. This preserves
    /// negative secondary-display origins and avoids Retina pixel conversion.
    static func appKitPoint(fromQuartz point: CGPoint, primaryFrame: CGRect) -> CornerPoint {
        CornerPoint(x: Double(point.x), y: Double(primaryFrame.maxY - point.y))
    }

    static func screen(at point: CornerPoint, in screens: [CornerScreen]) -> CornerScreen? {
        // Match Core's stable-ID tie break at shared display boundaries.
        // Never choose a nearest display for points in arrangement gaps.
        CornerGeometry.screen(at: point, among: screens)
    }
}

typealias CornerNativeScreenGeometry = CornerScreenGeometry
