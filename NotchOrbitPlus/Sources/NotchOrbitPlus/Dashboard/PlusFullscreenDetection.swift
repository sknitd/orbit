import AppKit
import ApplicationServices
import NotchCore

@MainActor
enum PlusFullscreenDetection {
    static func requestAccess() {
        // The documented option's literal avoids importing a mutable C global
        // into Swift 6's strict concurrency checks.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    static func shouldHide(on screen: NSScreen, enabled: Bool) -> Bool {
        guard enabled, AXIsProcessTrusted(), let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let window = value as! AXUIElement
        var fullscreen: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreen) == .success,
              fullscreen as? Bool == true else { return false }
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return false }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return false }
        let bounds = CGRect(origin: position, size: size)
        let display = NSScreen.screens.compactMap { candidate -> (UInt32, CGFloat)? in
            guard let id = NotchScreenLayout.screenID(for: candidate) else { return nil }
            let intersection = CGDisplayBounds(id).intersection(bounds)
            return (id, intersection.isNull ? 0 : intersection.width * intersection.height)
        }.max { $0.1 < $1.1 }
        return DashboardBehavior.shouldHideFullscreen(enabled: enabled, accessibilityAvailable: true,
            isFullscreen: true, windowDisplayID: display.flatMap { $0.1 > 0 ? $0.0 : nil },
            panelDisplayID: NotchScreenLayout.screenID(for: screen))
    }
}
