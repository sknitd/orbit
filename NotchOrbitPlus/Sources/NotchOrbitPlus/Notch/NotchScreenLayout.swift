#if os(macOS)
import AppKit
import NotchCore

@MainActor
public enum NotchScreenLayout {
    public static func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
    public static func screenID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    public static func screen(id: UInt32) -> NSScreen? {
        NSScreen.screens.first { screenID(for: $0) == id }
    }
    public static func layout(for screen: NSScreen) -> NotchLayout {
        func rect(_ value: NSRect) -> NotchRect {
            NotchRect(x: value.minX, y: value.minY, width: value.width, height: value.height)
        }
        func topArea(_ value: NSRect?) -> NotchRect? {
            guard let value, value.width > 0, value.height > 0 else { return nil }
            func isScreenArea(_ area: NSRect) -> Bool {
                abs(area.maxY - screen.frame.maxY) <= 1 &&
                    area.minX >= screen.frame.minX - 1 && area.maxX <= screen.frame.maxX + 1
            }
            if isScreenArea(value) { return rect(value) }
            // Keep the portable contract global even if an SDK/window-server
            // reports the auxiliary area relative to this display's origin.
            let translated = value.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            return isScreenArea(translated) ? rect(translated) : nil
        }
        let metrics = NotchScreenMetrics(frame: rect(screen.frame), visibleFrame: rect(screen.visibleFrame),
                                         safeTopInset: screen.safeAreaInsets.top,
                                         auxiliaryLeftFrame: topArea(screen.auxiliaryTopLeftArea),
                                         auxiliaryRightFrame: topArea(screen.auxiliaryTopRightArea))
        return NotchLayout(metrics: metrics, screenID: screenID(for: screen))
    }
}
#endif
