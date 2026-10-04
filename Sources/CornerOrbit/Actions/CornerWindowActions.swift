import AppKit
import ApplicationServices
import Foundation
import Darwin
import CornerCore

struct CornerWindowHandle: Hashable, Sendable {
    let id: UUID
    let processID: Int32
}
struct CornerWindowApplication: Hashable, Sendable {
    let processID: Int32
    let launchDate: Date
    let name: String
    let isRegular: Bool
    let isHidden: Bool
}
enum CornerWindowFlag: Sendable, Equatable { case minimized, fullscreen }
enum CornerWindowFailure: LocalizedError, Sendable {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let message) = self { message } else { nil } }
}

@MainActor
protocol CornerWindowProviding {
    func requestAccessibility() -> Bool
    func focusedWindow() async throws -> CornerWindowHandle
    func frame(of window: CornerWindowHandle) async throws -> CornerRect
    func setPosition(_ point: CornerPoint, of window: CornerWindowHandle) async throws
    func setSize(width: Double, height: Double, of window: CornerWindowHandle) async throws
    func flag(_ flag: CornerWindowFlag, of window: CornerWindowHandle) async throws -> Bool
    func setFlag(_ flag: CornerWindowFlag, value: Bool, of window: CornerWindowHandle) async throws
    func displays() -> [CornerWindowDisplay]
    func runningApplications() -> [CornerWindowApplication]
    func hide(_ application: CornerWindowApplication) async -> Bool
    func unhide(_ application: CornerWindowApplication) async -> Bool
}

@MainActor
final class CornerWindowActionRunner: CornerWindowActionRunning {
    private let provider: any CornerWindowProviding
    private let ownProcessID: Int32
    private var frames: [UUID: [CornerRect]] = [:]
    private var order: [UUID] = []
    private var hidden: [CornerWindowApplication] = []
    private var busy = false
    init(provider: (any CornerWindowProviding)? = nil, ownProcessID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.provider = provider ?? CornerNativeWindowProvider(); self.ownProcessID = ownProcessID
    }
    func run(_ kind: CornerActionKind) async throws -> String {
        try Task.checkCancellation()
        guard !busy else { throw CornerWindowFailure.unavailable("Another window action is still running.") }
        busy = true; defer { busy = false }
        if kind == .hideOtherApps { return try await hideOthers() }
        if kind == .restoreHiddenApps { return try await restoreApps() }
        let placement: CornerWindowPlacement?
        switch kind {
        case .windowLeft: placement = .left
        case .windowRight: placement = .right
        case .windowMaximize: placement = .maximize
        case .windowCenter: placement = .center
        case .windowNextDisplay: placement = .nextDisplay
        case .windowRestore, .windowMinimize, .windowFullscreen: placement = nil
        default: throw CornerWindowFailure.unavailable("This is not a window action.")
        }
        try Task.checkCancellation()
        guard provider.requestAccessibility() else {
            throw CornerWindowFailure.unavailable("Allow CornerOrbit in System Settings → Privacy & Security → Accessibility, then explicitly run the window action again.")
        }
        try Task.checkCancellation()
        let window = try await provider.focusedWindow()
        guard window.processID != ownProcessID else {
            throw CornerWindowFailure.unavailable("Switch to another application's window before running this action. CornerOrbit does not control its own windows.")
        }
        try Task.checkCancellation()
        if kind == .windowMinimize || kind == .windowFullscreen {
            let flag: CornerWindowFlag = kind == .windowMinimize ? .minimized : .fullscreen
            let previous = try await provider.flag(flag, of: window)
            let target = kind == .windowMinimize ? true : !previous
            guard target != previous else { return "The focused window is already minimized." }
            try Task.checkCancellation()
            do {
                try await provider.setFlag(flag, value: target, of: window)
                for _ in 0..<20 {
                    try Task.checkCancellation()
                    let actual = try await provider.flag(flag, of: window)
                    try Task.checkCancellation()
                    if actual == target { return kind.title }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw CornerWindowFailure.unavailable("The application did not confirm the requested window state.")
            } catch {
                // Run recovery outside the canceled task so its permission-free
                // captured-window cleanup can still execute.
                _ = await Task { @MainActor [provider] in try? await provider.setFlag(flag, value: previous, of: window) }.value
                throw error
            }
        }
        guard !(try await provider.flag(.fullscreen, of: window)), !(try await provider.flag(.minimized, of: window)) else {
            throw CornerWindowFailure.unavailable("Leave fullscreen and restore the minimized window before changing its frame.")
        }
        let previous = try await provider.frame(of: window)
        let target: CornerRect
        if kind == .windowRestore {
            guard let saved = frames[window.id]?.last else { throw CornerWindowFailure.unavailable("No previous frame is retained for this window.") }
            target = saved
        } else {
            let screens = provider.displays()
            guard let primary = screens.first?.frame else { throw CornerWindowFailure.unavailable("No display is available.") }
            let global = try CornerWindowLayout.globalRect(fromAccessibility: previous, primary: primary)
            target = try CornerWindowLayout.accessibilityRect(fromGlobal: CornerWindowLayout.target(placement!, window: global, displays: screens), primary: primary)
        }
        try Task.checkCancellation()
        if CornerWindowLayout.approximatelyEqual(previous, target) {
            if kind == .windowRestore { frames[window.id]?.removeLast() }
            return "The window already has the requested frame."
        }
        let oldFrames = frames
        let oldOrder = order
        if kind != .windowRestore { remember(previous, for: window.id) }
        do {
            try await provider.setSize(width: target.width, height: target.height, of: window)
            try Task.checkCancellation()
            try await provider.setPosition(.init(x: target.x, y: target.y), of: window)
            try Task.checkCancellation()
            let actual = try await provider.frame(of: window)
            try Task.checkCancellation()
            guard CornerWindowLayout.approximatelyEqual(actual, target) else {
                throw CornerWindowFailure.unavailable("The application constrained the window; the requested frame was not applied.")
            }
            if kind == .windowRestore { frames[window.id]?.removeLast() }
            return kind.title
        } catch {
            let restored = await rollback(previous, window: window)
            if restored { frames = oldFrames; order = oldOrder }
            if error is CancellationError { throw error }
            throw CornerWindowFailure.unavailable("\(error.localizedDescription) \(restored ? "The previous frame was restored." : "Recovery could not restore the full frame; its saved frame remains available for Restore.")")
        }
    }
    private func remember(_ frame: CornerRect, for id: UUID) {
        order.removeAll { $0 == id }; order.append(id)
        if order.count > 16 { frames.removeValue(forKey: order.removeFirst()) }
        var stack = frames[id] ?? []
        if stack.last != frame { stack.append(frame) }
        // Preserve the original frame plus the seven most recent frames.
        if stack.count > 8 { stack.remove(at: 1) }
        frames[id] = stack
    }
    private func rollback(_ frame: CornerRect, window: CornerWindowHandle) async -> Bool {
        await Task { @MainActor [provider] in
            try? await provider.setSize(width: frame.width, height: frame.height, of: window)
            try? await provider.setPosition(.init(x: frame.x, y: frame.y), of: window)
            guard let actual = try? await provider.frame(of: window) else { return false }
            return CornerWindowLayout.approximatelyEqual(actual, frame)
        }.value
    }
    private func hideOthers() async throws -> String {
        let current = provider.runningApplications()
        // Process birth dates prevent restoring an unrelated reused PID.
        hidden.removeAll { saved in !current.contains { $0.processID == saved.processID && $0.launchDate == saved.launchDate } }
        let candidates = current.filter { $0.isRegular && !$0.isHidden && $0.processID != ownProcessID }
        var added: [CornerWindowApplication] = [], changed: [CornerWindowApplication] = []
        var failed = 0, skipped = 0
        do {
            for app in candidates {
                try Task.checkCancellation()
                let alreadyOwned = hidden.contains { $0.processID == app.processID && $0.launchDate == app.launchDate }
                guard alreadyOwned || hidden.count < 128 else { skipped += 1; continue }
                if await provider.hide(app) {
                    changed.append(app)
                    if !alreadyOwned { hidden.append(app); added.append(app) }
                } else { failed += 1 }
            }
            try Task.checkCancellation()
        } catch {
            await Task { @MainActor [weak self] in
                guard let self else { return }
                for app in changed {
                    if await self.provider.unhide(app), added.contains(app) { self.hidden.removeAll { $0 == app } }
                }
            }.value
            throw error
        }
        return "Hidden \(changed.count) other app(s)." + (failed > 0 ? " \(failed) app(s) could not be hidden." : "") + (skipped > 0 ? " \(skipped) app(s) exceeded the 128-app restore limit." : "")
    }
    private func restoreApps() async throws -> String {
        let current = provider.runningApplications()
        var restored = 0, failed = 0
        for app in hidden {
            try Task.checkCancellation()
            guard current.contains(where: { $0.processID == app.processID && $0.launchDate == app.launchDate }) else {
                hidden.removeAll { $0 == app }; continue
            }
            if await provider.unhide(app) { hidden.removeAll { $0 == app }; restored += 1 }
            else { failed += 1 }
        }
        return "Restored \(restored) app(s) hidden by CornerOrbit." + (failed > 0 ? " \(failed) could not be restored; run Restore again." : "")
    }
}

@MainActor
final class CornerNativeWindowProvider: CornerWindowProviding {
    private let accessibility = CornerAXWindowSession()
    func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    func focusedWindow() async throws -> CornerWindowHandle {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw CornerWindowFailure.unavailable("Switch to another application's window first.")
        }
        return try await accessibility.focusedWindow(processID: app.processIdentifier)
    }
    func frame(of window: CornerWindowHandle) async throws -> CornerRect { try await accessibility.frame(window) }
    func setPosition(_ point: CornerPoint, of window: CornerWindowHandle) async throws { try await accessibility.setPosition(point, window: window) }
    func setSize(width: Double, height: Double, of window: CornerWindowHandle) async throws { try await accessibility.setSize(width: width, height: height, window: window) }
    func flag(_ flag: CornerWindowFlag, of window: CornerWindowHandle) async throws -> Bool { try await accessibility.flag(flag, window: window) }
    func setFlag(_ flag: CornerWindowFlag, value: Bool, of window: CornerWindowHandle) async throws { try await accessibility.setFlag(flag, value: value, window: window) }
    func displays() -> [CornerWindowDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            func rect(_ frame: NSRect) -> CornerRect { .init(x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width), height: Double(frame.height)) }
            return .init(id: number.stringValue, frame: rect(screen.frame), visibleFrame: rect(screen.visibleFrame))
        }
    }
    func runningApplications() -> [CornerWindowApplication] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let launched = app.launchDate else { return nil }
            return .init(processID: app.processIdentifier, launchDate: launched, name: app.localizedName ?? "Application", isRegular: app.activationPolicy == .regular, isHidden: app.isHidden)
        }
    }
    private func resolve(_ value: CornerWindowApplication) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: value.processID), !app.isTerminated,
              app.launchDate == value.launchDate, app.activationPolicy == .regular else { return nil }
        return app
    }
    func hide(_ application: CornerWindowApplication) async -> Bool {
        guard let app = resolve(application), !app.isHidden else { return false }
        return app.hide()
    }
    func unhide(_ application: CornerWindowApplication) async -> Bool {
        guard let app = resolve(application) else { return false }
        if !app.isHidden { return true }
        guard app.unhide() else { return false }
        for _ in 0..<5 {
            if !app.isHidden { return true }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return !app.isHidden }
        }
        return !app.isHidden
    }
}

/// AX objects stay in one executor; UI receives only Sendable handles/values.
/// Messaging timeouts bound unresponsive applications without blocking MainActor.
private actor CornerAXWindowSession {
    private struct Entry { let handle: CornerWindowHandle; let hash: CFHashCode; let element: AXUIElement }
    private var entries: [Entry] = []
    func focusedWindow(processID: Int32) throws -> CornerWindowHandle {
        try Task.checkCancellation()
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.75)
        var value: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &value), operation: "Read focused window")
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw CornerWindowFailure.unavailable("This application has no accessible focused window.") }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.75)
        let hash = CFHash(element)
        if let index = entries.firstIndex(where: { $0.handle.processID == processID && $0.hash == hash && CFEqual($0.element, element) }) {
            let entry = entries.remove(at: index); entries.append(entry); return entry.handle
        }
        let handle = CornerWindowHandle(id: UUID(), processID: processID)
        entries.append(.init(handle: handle, hash: hash, element: element))
        if entries.count > 32 { entries.removeFirst() }
        return handle
    }
    private func element(_ handle: CornerWindowHandle) throws -> AXUIElement {
        guard let element = entries.first(where: { $0.handle == handle })?.element else { throw CornerWindowFailure.unavailable("The retained window is no longer available.") }
        var pid: pid_t = 0
        try check(AXUIElementGetPid(element, &pid), operation: "Verify window ownership")
        guard pid == handle.processID, pid != ProcessInfo.processInfo.processIdentifier else { throw CornerWindowFailure.unavailable("The window owner changed or belongs to CornerOrbit.") }
        return element
    }
    func frame(_ handle: CornerWindowHandle) throws -> CornerRect {
        try Task.checkCancellation()
        let element = try element(handle)
        var position: CFTypeRef?, size: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &position), operation: "Read window position")
        try check(AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &size), operation: "Read window size")
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { throw CornerWindowFailure.unavailable("The focused window does not report a readable frame.") }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { throw CornerWindowFailure.unavailable("The window frame has an unsupported format.") }
        let frame = CornerRect(x: Double(point.x), y: Double(point.y), width: Double(dimensions.width), height: Double(dimensions.height))
        guard frame.isValid else { throw CornerWindowFailure.unavailable("The application returned an invalid window frame.") }
        return frame
    }
    func setPosition(_ point: CornerPoint, window: CornerWindowHandle) throws {
        try Task.checkCancellation()
        guard point.isFinite else { throw CornerWindowFailure.unavailable("The target position is invalid.") }
        var value = CGPoint(x: point.x, y: point.y)
        guard let wrapped = AXValueCreate(.cgPoint, &value) else { throw CornerWindowFailure.unavailable("The position could not be encoded.") }
        try write(wrapped, attribute: "AXPosition" as CFString, window: window)
    }
    func setSize(width: Double, height: Double, window: CornerWindowHandle) throws {
        try Task.checkCancellation()
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw CornerWindowFailure.unavailable("The target size is invalid.") }
        var value = CGSize(width: width, height: height)
        guard let wrapped = AXValueCreate(.cgSize, &value) else { throw CornerWindowFailure.unavailable("The size could not be encoded.") }
        try write(wrapped, attribute: "AXSize" as CFString, window: window)
    }
    func flag(_ flag: CornerWindowFlag, window: CornerWindowHandle) throws -> Bool {
        try Task.checkCancellation()
        var value: CFTypeRef?
        try check(AXUIElementCopyAttributeValue(try element(window), attribute(flag), &value), operation: "Read window state")
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID(), let boolean = value as? Bool else { throw CornerWindowFailure.unavailable("The focused window does not expose this state.") }
        return boolean
    }
    func setFlag(_ flag: CornerWindowFlag, value: Bool, window: CornerWindowHandle) throws {
        try Task.checkCancellation()
        try write(NSNumber(value: value), attribute: attribute(flag), window: window)
    }
    private func attribute(_ flag: CornerWindowFlag) -> CFString { (flag == .minimized ? "AXMinimized" : "AXFullScreen") as CFString }
    private func write(_ value: CFTypeRef, attribute: CFString, window: CornerWindowHandle) throws {
        let element = try element(window)
        var settable: DarwinBoolean = false
        try check(AXUIElementIsAttributeSettable(element, attribute, &settable), operation: "Check window control support")
        guard settable.boolValue else { throw CornerWindowFailure.unavailable("The application does not allow this window change.") }
        try check(AXUIElementSetAttributeValue(element, attribute, value), operation: "Change focused window")
    }
    private func check(_ result: AXError, operation: String) throws {
        guard result == .success else { throw CornerWindowFailure.unavailable("\(operation) failed (Accessibility error \(result.rawValue)). The application may not support this operation or access may have been revoked.") }
    }
}
