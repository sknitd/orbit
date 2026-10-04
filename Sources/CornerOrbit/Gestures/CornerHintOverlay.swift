import AppKit
import CornerCore

@MainActor
private final class CornerHintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CornerHintDrawing: NSView {
    let corner: Corner
    init(corner: Corner, size: CGFloat) {
        self.corner = corner
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }
    required init?(coder: NSCoder) { return nil }
    override func draw(_ dirtyRect: NSRect) {
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let x = left ? CGFloat(3) : bounds.width - 3
        let y = top ? bounds.height - 3 : CGFloat(3)
        let length = max(3, bounds.width - 7)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y + (top ? -length : length)))
        path.line(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x + (left ? length : -length), y: y))
        path.lineWidth = 2; path.lineCapStyle = .round; path.lineJoinStyle = .round
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        path.stroke()
    }
}

/// Optional static hints. No animation, timers, event capture, or activation;
/// static drawing also respects Reduce Motion without extra observation.
@MainActor
final class CornerHintOverlay {
    private var panels: [NSPanel] = []
    func show(screens: [CornerScreen], enabledCorners: Set<Corner>, size: Double) {
        hide()
        let length = CGFloat(max(8, min(24, size)))
        for screen in screens {
            for corner in Corner.allCases where enabledCorners.contains(corner) {
                let left = corner == .topLeft || corner == .bottomLeft
                let top = corner == .topLeft || corner == .topRight
                let x = left ? screen.frame.x : screen.frame.x + screen.frame.width - Double(length)
                let y = top ? screen.frame.y + screen.frame.height - Double(length) : screen.frame.y
                let panel = CornerHintPanel(contentRect: NSRect(x: x, y: y, width: Double(length), height: Double(length)),
                                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.isOpaque = false
                panel.backgroundColor = .clear; panel.hasShadow = false
                panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
                panel.level = .statusBar
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
                panel.contentView = CornerHintDrawing(corner: corner, size: length)
                panel.orderFrontRegardless()
                panels.append(panel)
            }
        }
    }
    func hide() { panels.forEach { $0.orderOut(nil); $0.close() }; panels = [] }
}
