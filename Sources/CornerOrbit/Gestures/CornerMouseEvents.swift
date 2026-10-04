import AppKit
import CoreGraphics
import CornerCore

struct CornerMouseSample: Sendable {
    enum Kind: Equatable, Sendable { case down, up, dragged, moved, interrupted
        case rightDown, rightUp, rightDragged, middleDown, middleUp, middleDragged, scrollUp, scrollDown }
    let kind: Kind
    let timestamp: Double
    let point: CornerPoint
    let modifiers: CornerModifiers
    init(kind: Kind, timestamp: Double, point: CornerPoint, modifiers: CornerModifiers = []) {
        self.kind = kind; self.timestamp = timestamp; self.point = point; self.modifiers = modifiers
    }
}

@MainActor
protocol CornerMouseEventSource: AnyObject {
    func stop()
}

@MainActor
struct CornerMonitorDependencies {
    typealias Receiver = @MainActor (CornerMouseSample) -> Void
    var preflightAccess: () -> Bool
    var requestAccess: () -> Bool
    var screens: () -> [CornerScreen]
    var installMouseEvents: (@escaping Receiver) -> (any CornerMouseEventSource)?
    var now: () -> Double
    var modifiers: () -> CornerModifiers
    var sessionActive: () -> Bool
    var observeSystemEvents: Bool

    init(preflightAccess: @escaping () -> Bool, requestAccess: @escaping () -> Bool,
         screens: @escaping () -> [CornerScreen],
         installMouseEvents: @escaping (@escaping Receiver) -> (any CornerMouseEventSource)?,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         modifiers: @escaping () -> CornerModifiers = { [] }, sessionActive: @escaping () -> Bool = { true },
         observeSystemEvents: Bool = false) {
        self.preflightAccess = preflightAccess; self.requestAccess = requestAccess; self.screens = screens
        self.installMouseEvents = installMouseEvents; self.now = now; self.modifiers = modifiers
        self.sessionActive = sessionActive; self.observeSystemEvents = observeSystemEvents
    }

    static var live: Self {
        Self(preflightAccess: { CGPreflightListenEventAccess() }, requestAccess: { CGRequestListenEventAccess() },
             screens: CornerNativeScreenGeometry.screens, installMouseEvents: CornerLiveMouseSource.install,
             modifiers: { CornerMouseModifiers.appKit(NSEvent.modifierFlags) }, sessionActive: {
                 guard let values = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
                 return (values[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue == true
             }, observeSystemEvents: true)
    }
}

enum CornerMouseModifiers {
    static func appKit(_ flags: NSEvent.ModifierFlags) -> CornerModifiers {
        var result: CornerModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
    static func quartz(_ flags: CGEventFlags) -> CornerModifiers {
        var result: CornerModifiers = []
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }
}

/// Production event-mask/decoder boundary. Fixtures construct CGEvents but
/// never post them, install a global tap, or request an input permission.
@MainActor
enum CornerMouseEventDecoder {
    static let observedTypes: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
        .otherMouseDragged, .mouseMoved, .scrollWheel]
    static func kind(for type: CGEventType, event: CGEvent) -> CornerMouseSample.Kind? {
        switch type {
        case .leftMouseDown: return .down
        case .leftMouseUp: return .up
        case .leftMouseDragged: return .dragged
        case .rightMouseDown: return .rightDown
        case .rightMouseUp: return .rightUp
        case .rightMouseDragged: return .rightDragged
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            // Button 2 is the middle button; side buttons retain
            // their normal OS/application behavior without mappings.
            guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else { return nil }
            return type == .otherMouseDown ? .middleDown : (type == .otherMouseUp ? .middleUp : .middleDragged)
        case .scrollWheel:
            // Horizontal-only/zero packets and inertial momentum do
            // not manufacture repeated intentional corner scrolls.
            guard event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return nil }
            let delta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let fallback = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            guard delta.isFinite, delta != 0 || fallback != 0 else { return nil }
            return (delta == 0 ? Double(fallback) : delta) > 0 ? .scrollUp : .scrollDown
        case .mouseMoved: return .moved
        case .tapDisabledByTimeout, .tapDisabledByUserInput: return .interrupted
        default: return nil
        }
    }
}

@MainActor
private final class CornerTapContext {
    let receiver: CornerMonitorDependencies.Receiver
    init(receiver: @escaping CornerMonitorDependencies.Receiver) { self.receiver = receiver }
}

/// Owns the C callback context through run-loop removal and tap invalidation.
/// CoreFoundation invalidation/removal is thread-safe; explicit stop is main-
/// actor isolated, and deallocation also safely releases the native resource.
private final class CornerTapLifetime: @unchecked Sendable {
    let port: CFMachPort
    let source: CFRunLoopSource
    let context: CornerTapContext
    private let lock = NSLock()
    private var stopped = false
    init(port: CFMachPort, source: CFRunLoopSource, context: CornerTapContext) {
        self.port = port; self.source = source; self.context = context
    }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; stopped = true
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(port)
    }
    deinit { invalidate() }
}

@MainActor
private final class CornerLiveMouseSource: CornerMouseEventSource {
    private let lifetime: CornerTapLifetime
    private init(lifetime: CornerTapLifetime) { self.lifetime = lifetime }
    func stop() { lifetime.invalidate() }
    static func install(_ receiver: @escaping CornerMonitorDependencies.Receiver) -> (any CornerMouseEventSource)? {
        let context = CornerTapContext(receiver: receiver)
        let types = CornerMouseEventDecoder.observedTypes
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                         eventsOfInterest: mask, callback: { _, type, event, opaque in
            if let opaque {
                let context = Unmanaged<CornerTapContext>.fromOpaque(opaque).takeUnretainedValue()
                // This source is registered only on CFRunLoopGetMain(). The
                // borrowed CGEvent stays within the callback; only copied
                // position/time/modifier primitives reach the recognizer.
                MainActor.assumeIsolated {
                    guard let kind = CornerMouseEventDecoder.kind(for: type, event: event) else { return }
                    if case .interrupted = kind {
                        context.receiver(.init(kind: kind, timestamp: Double(event.timestamp) / 1_000_000_000,
                                               point: .init(x: 0, y: 0)))
                        return
                    }
                    guard let primary = NSScreen.screens.first else { return }
                    context.receiver(CornerMouseSample(kind: kind, timestamp: Double(event.timestamp) / 1_000_000_000,
                        point: CornerNativeScreenGeometry.appKitPoint(fromQuartz: event.location, primaryFrame: primary.frame),
                        modifiers: CornerMouseModifiers.quartz(event.flags)))
                }
            }
            // Listen-only observation neither consumes nor changes OS events.
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(context).toOpaque()) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port); return nil
        }
        let lifetime = CornerTapLifetime(port: port, source: source, context: context)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return CornerLiveMouseSource(lifetime: lifetime)
    }
}
