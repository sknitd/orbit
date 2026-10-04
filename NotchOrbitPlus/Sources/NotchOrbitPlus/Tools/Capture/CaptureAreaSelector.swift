import AppKit
import NotchCore

@MainActor
final class CaptureAreaSelector: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<CaptureArea?, Never>?
    func choose(on screen: NSScreen) async -> CaptureArea? {
        cancel()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let window = CaptureSelectionWindow(contentRect: screen.frame, styleMask: .borderless,
                                                backing: .buffered, defer: false, screen: screen)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.level = .screenSaver; window.isOpaque = false; window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = CaptureSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size)) { [weak self] area in
                self?.finish(area)
            }
            window.contentView = view
            self.window = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        }
    }
    func cancel() { finish(nil) }
    func windowWillClose(_ notification: Notification) { finish(nil) }
    private func finish(_ area: CaptureArea?) {
        let pending = continuation; continuation = nil
        let old = window; window = nil; old?.delegate = nil; old?.close()
        pending?.resume(returning: area)
    }
}

@MainActor
private final class CaptureSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CaptureSelectionView: NSView {
    private var start: CGPoint?
    private var end: CGPoint?
    private let finished: (CaptureArea?) -> Void
    init(frame: NSRect, finished: @escaping (CaptureArea?) -> Void) {
        self.finished = finished; super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil); end = start; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        end = convert(event.locationInWindow, from: nil); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        if let area = try? CaptureGeometry.area(startX: start.x, startY: start.y, endX: end.x, endY: end.y,
                                                displayWidth: bounds.width, displayHeight: bounds.height) {
            finished(area)
        } else { self.start = nil; self.end = nil; needsDisplay = true; NSSound.beep() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finished(nil) } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.20).setFill(); bounds.fill()
        if let start, let end {
            let rectangle = NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                   width: abs(start.x - end.x), height: abs(start.y - end.y))
            NSColor.systemBlue.withAlphaComponent(0.12).setFill(); rectangle.fill()
            NSColor.white.setStroke(); let border = NSBezierPath(rect: rectangle); border.lineWidth = 2; border.stroke()
        }
        let text = "Drag to select an area · Escape cancels"
        text.draw(at: NSPoint(x: 24, y: max(24, bounds.height - 50)), withAttributes: [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white,
            .shadow: { let shadow = NSShadow(); shadow.shadowColor = NSColor.black; shadow.shadowBlurRadius = 3; return shadow }()
        ])
    }
}
