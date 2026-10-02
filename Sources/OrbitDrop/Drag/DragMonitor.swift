import AppKit
import CoreGraphics
import OrbitCore
import os

/// Observes a possible external file drag. A destination must still validate the
/// actual `NSDraggingInfo` and is the only component allowed to execute an action.
@MainActor
final class DragMonitor {
    enum Status: Equatable {
        case stopped
        case listening
        case inputMonitoringRequired
        case eventTapUnavailable
    }

    private(set) var status: Status = .stopped

    /// Empty or unsupported modifier combinations behave as Shift.
    var trigger: NSEvent.ModifierFlags = .shift {
        didSet {
            hidePresentation()
            evaluateActivation()
        }
    }

    /// Zero gives immediate activation. The delay runs only during a valid drag.
    var activationDelay: TimeInterval = 0.06

    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            finishDrag()
            if let registration {
                CGEvent.tapEnable(tap: registration.port, enable: !paused)
            }
        }
    }

    private struct Session {
        let id = UUID()
        let initialPasteboardCount: Int
        var payloadPasteboardCount: Int?
        var urls: [URL]?
        var mouseIsDown = true
        var receivedDragEvent = false
    }

    private struct Presentation {
        let anchor: NSPoint
        var advanced: Bool
    }

    private let onActivate: ([URL], NSPoint, Bool) -> Void
    private let onCancel: () -> Void
    private let dragPasteboard = NSPasteboard(name: .drag)
    private let logger = Logger(subsystem: "app.orbitdrop", category: "drag")
    private var registration: EventTapRegistration?
    private var session: Session?
    private var presentation: Presentation?
    private var modifiers: NSEvent.ModifierFlags = []
    private var pendingActivation: Task<Void, Never>?
    private var pendingReleaseCleanup: Task<Void, Never>?

    init(
        onActivate: @escaping ([URL], NSPoint, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onActivate = onActivate
        self.onCancel = onCancel
    }

    /// Starts without requesting a permission dialog. Tap creation, rather than
    /// the presence of a token or an Accessibility grant, establishes readiness.
    func start() {
        guard registration == nil else { return }
        let context = EventTapContext(monitor: self)
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown
        ]
        let mask = types.reduce(CGEventMask(0)) { result, type in
            result | (CGEventMask(1) << type.rawValue)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.receiveEvent,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            status = CGPreflightListenEventAccess()
                ? .eventTapUnavailable : .inputMonitoringRequired
            logger.notice("Global drag observation is unavailable.")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            status = .eventTapUnavailable
            return
        }

        let registration = EventTapRegistration(port: port, source: source, context: context)
        self.registration = registration
        // The source is serviced only by the main run loop, including AppKit's
        // drag tracking mode. That is the isolation guarantee in receiveEvent.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: !paused)
        status = .listening
    }

    func stop() {
        finishDrag()
        registration?.invalidate()
        registration = nil
        status = .stopped
    }

    /// Call from an explicit permission control; macOS may require a relaunch
    /// after the user changes Privacy & Security → Input Monitoring.
    @discardableResult
    func requestInputMonitoringAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    /// Use after the destination accepts or cancels the drag. No file operation
    /// is performed here, including when this method follows a mouse release.
    func finishDrag() {
        pendingReleaseCleanup?.cancel()
        pendingReleaseCleanup = nil
        session = nil
        hidePresentation()
    }

    private var requiredModifiers: NSEvent.ModifierFlags {
        let supported: NSEvent.ModifierFlags = [.shift, .option, .control, .command]
        let selected = trigger.intersection(supported)
        return selected.isEmpty ? .shift : selected
    }

    private var triggerIsHeld: Bool {
        modifiers.intersection(requiredModifiers) == requiredModifiers
    }

    private nonisolated static func receiveEvent(
        _ proxy: CGEventTapProxy,
        _ type: CGEventType,
        _ event: CGEvent,
        _ userInfo: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        if let userInfo {
            let context = Unmanaged<EventTapContext>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated {
                context.monitor?.handle(type, event: event)
            }
        }
        // A listen-only tap always leaves the original event untouched.
        return Unmanaged.passUnretained(event)
    }

    private func handle(_ type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            finishDrag()
            if let registration, !paused {
                CGEvent.tapEnable(tap: registration.port, enable: true)
            }
            logger.notice("Drag observation was interrupted; the current gesture was cancelled.")
            return
        }
        guard !paused else { return }

        switch type {
        case .leftMouseDown:
            finishDrag()
            modifiers = Self.modifierFlags(from: event.flags)
            // The previous drag's payload can remain indefinitely on .drag.
            // Only a pasteboard written after this mouse-down is eligible.
            session = Session(initialPasteboardCount: dragPasteboard.changeCount)
        case .leftMouseDragged:
            guard var session, session.mouseIsDown else { return }
            session.receivedDragEvent = true
            self.session = session
            modifiers = Self.modifierFlags(from: event.flags)
            evaluateActivation()
        case .flagsChanged:
            modifiers = Self.modifierFlags(from: event.flags)
            // A flags change after mouse-up must not close the destination
            // before AppKit has delivered its authoritative drop callback.
            if session?.mouseIsDown == true {
                evaluateActivation()
            }
        case .leftMouseUp:
            mouseReleased()
        case .keyDown:
            // Read one hardware key code only. Never inspect characters, text,
            // application contents, or any other keyboard input.
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                finishDrag()
            }
        default:
            break
        }
    }

    private func evaluateActivation() {
        guard !paused, var session, session.mouseIsDown,
              session.receivedDragEvent, triggerIsHeld else {
            hidePresentation()
            return
        }

        let currentCount = dragPasteboard.changeCount
        guard currentCount != session.initialPasteboardCount else { return }
        if let payloadCount = session.payloadPasteboardCount, payloadCount != currentCount {
            // A second writer invalidates this candidate session. A fresh
            // mouse-down is necessary; do not substitute another payload.
            finishDrag()
            return
        }
        if session.urls == nil {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            guard let values = dragPasteboard.readObjects(
                forClasses: [NSURL.self], options: options
            ) as? [NSURL] else { return }
            var seen = Set<URL>()
            let urls = values.compactMap { value -> URL? in
                let url = value as URL
                guard url.isFileURL, !url.path.isEmpty, seen.insert(url).inserted else { return nil }
                return url
            }
            guard !urls.isEmpty else { return }
            // Lazy pasteboard providers may run while readObjects is reading.
            // Reject a payload if its board changed during that read.
            guard dragPasteboard.changeCount == currentCount else { return }
            session.urls = urls
            session.payloadPasteboardCount = currentCount
            self.session = session
        }

        if var presentation {
            let advanced = modifiers.contains(.option)
            if presentation.advanced != advanced, let urls = session.urls {
                presentation.advanced = advanced
                self.presentation = presentation
                onActivate(urls, presentation.anchor, advanced)
            }
            return
        }
        guard pendingActivation == nil else { return }
        let sessionID = session.id
        let delay = activationDelay.isFinite ? min(max(activationDelay, 0), 2) : 0
        if delay == 0 {
            presentIfEligible(sessionID: sessionID)
            return
        }
        pendingActivation = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            self.pendingActivation = nil
            self.presentIfEligible(sessionID: sessionID)
        }
    }

    private func presentIfEligible(sessionID: UUID) {
        guard !paused, let session, session.id == sessionID,
              session.mouseIsDown, session.receivedDragEvent, triggerIsHeld,
              let urls = session.urls,
              session.payloadPasteboardCount == dragPasteboard.changeCount else { return }
        // AppKit global points have a lower-left origin on the primary display.
        // NSEvent.mouseLocation already handles negative display coordinates
        // and Retina point scaling. Do not flip relative to an active display.
        let anchor = NSEvent.mouseLocation
        let advanced = modifiers.contains(.option)
        presentation = Presentation(anchor: anchor, advanced: advanced)
        onActivate(urls, anchor, advanced)
    }

    private func mouseReleased() {
        pendingActivation?.cancel()
        pendingActivation = nil
        guard var session else { return }
        session.mouseIsDown = false
        self.session = session
        guard presentation != nil else {
            finishDrag()
            return
        }
        let sessionID = session.id
        pendingReleaseCleanup?.cancel()
        // The event tap sees mouse-up before NSDraggingDestination sees the
        // drop. Give AppKit that turn; the destination normally finishes and
        // hides synchronously. This one-shot task only cancels a stranded wheel.
        pendingReleaseCleanup = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, self.session?.id == sessionID else { return }
            self.finishDrag()
        }
    }

    private func hidePresentation() {
        pendingActivation?.cancel()
        pendingActivation = nil
        guard presentation != nil else { return }
        presentation = nil
        onCancel()
    }

    private nonisolated static func modifierFlags(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }
}

@MainActor
private final class EventTapContext {
    weak var monitor: DragMonitor?
    init(monitor: DragMonitor) { self.monitor = monitor }
}

/// Core Foundation invalidation is thread safe. Owning the registration in a
/// separate lifetime object also invalidates the C callback if a controller is
/// released without explicitly calling stop(). The callback holds no controller.
private final class EventTapRegistration: @unchecked Sendable {
    let port: CFMachPort
    let source: CFRunLoopSource
    private let context: EventTapContext

    init(port: CFMachPort, source: CFRunLoopSource, context: EventTapContext) {
        self.port = port
        self.source = source
        self.context = context
    }

    func invalidate() {
        if CFMachPortIsValid(port) {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit { invalidate() }
}
