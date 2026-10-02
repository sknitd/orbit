import AppKit
import CoreGraphics
import NotchCore
import os

/// A no-key presentation observer. Only NSDraggingDestination may accept and
/// execute an operation from the actual drop session; this monitor never does.
@MainActor
final class NotchDragMonitor {
    enum Status: Equatable {
        case stopped
        case listening
        case inputMonitoringRequired
        case eventTapUnavailable
    }

    private(set) var status: Status = .stopped

    /// Capture synchronously in onActivate, then check isCurrentActivation
    /// after asynchronous file inspection and before presenting the panel.
    var activationGeneration: UInt64? { tracker.current?.generation }

    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            finishDrag()
            if let registration {
                CGEvent.tapEnable(tap: registration.port, enable: !paused)
            }
        }
    }

    private let onActivate: ([URL], NotchLayout) -> Void
    private let onCancel: () -> Void
    private let zonesProvider: (() -> [NotchActivationZone])?
    private let pasteboard = NSPasteboard(name: .drag)
    private let logger = Logger(subsystem: "app.notchorbit", category: "drag")
    private var tracker = NotchActivationTracker()
    private var registration: NotchEventTapRegistration?
    private var mouseDownPasteboardCount: Int?
    private var cachedPayloadCount: Int?
    private var cachedURLs: [URL] = []
    private var releaseCleanup: Task<Void, Never>?

    init(
        onActivate: @escaping ([URL], NotchLayout) -> Void,
        onCancel: @escaping () -> Void,
        zonesProvider: (() -> [NotchActivationZone])? = nil
    ) {
        self.onActivate = onActivate
        self.onCancel = onCancel
        self.zonesProvider = zonesProvider
    }

    /// No permission prompt at launch. A failed listening grant must retain
    /// the normal file picker/drop-zone workflow in the application shell.
    func start() {
        guard registration == nil else { return }
        let context = NotchEventTapContext(monitor: self)
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { result, type in
            result | (CGEventMask(1) << type.rawValue)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo in
                NotchDragMonitor.receiveEvent(proxy, type, event, userInfo)
            },
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            status = CGPreflightListenEventAccess()
                ? .eventTapUnavailable : .inputMonitoringRequired
            logger.notice("Global drag observation is unavailable; file picker remains usable.")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            status = .eventTapUnavailable
            return
        }
        registration = NotchEventTapRegistration(port: port, source: source, context: context)
        // Common modes include AppKit drag tracking. The callback's only run
        // loop is the main run loop, which justifies assumeIsolated below.
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

    /// Call from an explicit setup/settings control. Input Monitoring is for
    /// listen-only input observation; Accessibility control is not used here.
    /// A macOS permission change can require quitting and relaunching the app.
    @discardableResult
    func requestInputMonitoringAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    func isCurrentActivation(_ generation: UInt64) -> Bool {
        guard !paused, tracker.isCurrent(generation) else { return false }
        // Content writes by the existing pasteboard owner can retain the same
        // change count. Before presenting inspected files, verify the live
        // representation still matches the candidate rather than trusting its
        // cached URLs. This runs only at the async presentation boundary.
        let liveCount = pasteboard.changeCount
        let liveURLs = Self.fileURLs(from: pasteboard)
        guard cachedPayloadCount == liveCount, pasteboard.changeCount == liveCount,
              NotchDragPayload.matches(observed: cachedURLs, dropped: liveURLs) else {
            finishDrag()
            return false
        }
        // Inspection can finish before the next queued pointer event. Recheck
        // live screen layout, pointer region, and pasteboard freshness before
        // allowing its result to create a panel at obsolete geometry.
        handleDrag()
        return tracker.isCurrent(generation)
    }

    /// Invoke from the destination's drop completion or cancellation. Does not
    /// execute an operation and does not grant authority to cached file URLs.
    func finishDrag() {
        releaseCleanup?.cancel()
        releaseCleanup = nil
        let transition = tracker.cancel()
        clearPayload()
        mouseDownPasteboardCount = nil
        if case .cancel = transition { onCancel() }
    }

    /// Shared public-API reader for native tests and drop destinations. The
    /// returned file-URL representation must be nonempty, local, unique, and
    /// stable. Other pasteboard representations are ignored by this reader.
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let count = pasteboard.changeCount
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options)
                as? [NSURL] else { return [] }
        let urls = objects.map { $0 as URL }
        guard pasteboard.changeCount == count,
              NotchDragPayload.matches(observed: urls, dropped: urls) else { return [] }
        return urls
    }

    private nonisolated static func receiveEvent(
        _ proxy: CGEventTapProxy,
        _ type: CGEventType,
        _ event: CGEvent,
        _ userInfo: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        if let userInfo {
            let context = Unmanaged<NotchEventTapContext>.fromOpaque(userInfo).takeUnretainedValue()
            // The borrowed CGEvent never crosses actor isolation. Copy only
            // primitive data. No characters, text, or modifier state is read.
            let eventType = type.rawValue
            let keyCode = type == .keyDown ? event.getIntegerValueField(.keyboardEventKeycode) : -1
            MainActor.assumeIsolated {
                context.monitor?.handle(eventType: eventType, keyCode: keyCode)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func handle(eventType: UInt32, keyCode: Int64) {
        guard let type = CGEventType(rawValue: eventType) else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            finishDrag()
            if let registration, !paused {
                CGEvent.tapEnable(tap: registration.port, enable: true)
            }
            logger.notice("Input observation was interrupted; drag presentation cancelled.")
            return
        }
        guard !paused else { return }
        switch type {
        case .leftMouseDown:
            finishDrag()
            let count = pasteboard.changeCount
            mouseDownPasteboardCount = count
            tracker.begin(pasteboardCount: count)
        case .leftMouseDragged:
            handleDrag()
        case .leftMouseUp:
            apply(tracker.release())
            if tracker.current == nil {
                clearPayload()
                mouseDownPasteboardCount = nil
            }
        case .keyDown:
            // Hardware Escape only; this is cancellation, never a trigger.
            if keyCode == 53 { finishDrag() }
        default:
            break
        }
    }

    private func handleDrag() {
        guard tracker.mouseIsDown, let mouseDownPasteboardCount else { return }
        let count = pasteboard.changeCount
        if cachedPayloadCount == nil, count != mouseDownPasteboardCount {
            let urls = Self.fileURLs(from: pasteboard)
            if !urls.isEmpty, pasteboard.changeCount == count {
                cachedURLs = urls
                cachedPayloadCount = count
            }
        }

        // AppKit supplies global points directly, including negative secondary
        // display origins and Retina scaling. Never flip per active display.
        let pointer = NSEvent.mouseLocation
        let zones = zonesProvider?() ?? Self.screenZones()
        let transition = tracker.dragged(
            at: NotchPoint(x: Double(pointer.x), y: Double(pointer.y)),
            pasteboardCount: count,
            hasFileURLs: !cachedURLs.isEmpty && cachedPayloadCount == count,
            zones: zones
        )
        apply(transition)
        if !tracker.mouseIsDown {
            clearPayload()
            self.mouseDownPasteboardCount = nil
        }
    }

    private func apply(_ transition: NotchActivationTransition) {
        switch transition {
        case .none:
            break
        case .activate(let activation):
            onActivate(cachedURLs, activation.zone.layout)
        case .cancel:
            releaseCleanup?.cancel()
            releaseCleanup = nil
            onCancel()
        case .releasePending(let activation):
            releaseCleanup?.cancel()
            // The tap sees mouse-up before AppKit sees its drop. Keep an
            // existing destination alive briefly; this task only cancels a
            // stranded panel. No operation is authorized by mouse release.
            releaseCleanup = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self, self.tracker.awaitingDrop,
                      self.tracker.current?.generation == activation.generation else { return }
                self.finishDrag()
            }
        }
    }

    private func clearPayload() {
        cachedPayloadCount = nil
        cachedURLs = []
    }

    private static func screenZones() -> [NotchActivationZone] {
        NSScreen.screens.compactMap { screen in
            let layout = NotchScreenLayout.layout(for: screen)
            guard let screenID = layout.screenID else { return nil }
            return NotchActivationZone(screenID: screenID, screenFrame: layout.screenFrame, layout: layout)
        }
    }
}

@MainActor
private final class NotchEventTapContext {
    weak var monitor: NotchDragMonitor?
    init(monitor: NotchDragMonitor) { self.monitor = monitor }
}

/// Owns the callback context until invalidation. Core Foundation run-loop
/// removal/port invalidation is thread safe, including during destruction.
private final class NotchEventTapRegistration: @unchecked Sendable {
    let port: CFMachPort
    let source: CFRunLoopSource
    private let context: NotchEventTapContext

    init(port: CFMachPort, source: CFRunLoopSource, context: NotchEventTapContext) {
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
