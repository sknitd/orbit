import AppKit
import SwiftUI
import ApplicationServices
import CoreGraphics
import NotchCore

@MainActor
final class SystemControlsService: ObservableObject {
    static let shared = SystemControlsService()
    @Published private(set) var enabled = false
    @Published private(set) var hud: SystemHUDSnapshot?
    @Published private(set) var status = "Off. macOS handles all volume and brightness keys."
    @Published private(set) var error: String?
    var onHUD: (@MainActor (SystemHUDSnapshot?) -> Void)?
    /// The host can fail open when its replacement HUD cannot be displayed.
    var canPresentHUD: (@MainActor () -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var context: SystemHUDTapContext?
    private var dismissTask: Task<Void, Never>?
    private var handledPresses = Set<SystemMediaKey>()
    private let display = SystemDisplayHardware()

    /// Explicit user control only: launch, view appearance and visibility never
    /// invoke this method. Enabled interception is the user's background opt-in.
    func enable() {
        guard tap == nil else { return }
        error = nil
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else {
            status = "Accessibility permission required. Enable it in System Settings, then try again."
            return
        }
        let context = SystemHUDTapContext(owner: self)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1) << 14, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let value = Unmanaged<SystemHUDTapContext>.fromOpaque(pointer).takeUnretainedValue()
            let eventType = type.rawValue
            let native = NSEvent(cgEvent: event)
            let key = native.flatMap { $0.type == .systemDefined ? SystemMediaKeyEvent(subtype: Int($0.subtype.rawValue), data1: $0.data1) : nil }
            let modified = native.map { !$0.modifierFlags.intersection([.option, .shift, .control, .command]).isEmpty } ?? false
            // The sole registered run loop is main; perform hardware changes
            // synchronously before deciding whether the event may be consumed.
            let consume = MainActor.assumeIsolated {
                value.owner?.receive(eventType: eventType, key: key, modified: modified) ?? false
            }
            return consume ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(context).toOpaque()) else {
            status = "The media-key event tap is unavailable. macOS continues handling every key."
            error = "macOS may also require Input Monitoring for this event tap. No keys were intercepted."
            return
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port); status = "Could not register the event tap; macOS handles every key."; return
        }
        self.context = context; tap = port; source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        enabled = true; status = "On. Unsupported controls and failed hardware changes pass through to macOS."
    }
    func disable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); CFRunLoopSourceInvalidate(source) }
        tap = nil; source = nil; context = nil; enabled = false; handledPresses.removeAll()
        dismissTask?.cancel(); dismissTask = nil; hud = nil; onHUD?(nil)
        status = "Off. macOS handles all volume and brightness keys."
    }
    private func receive(eventType: UInt32, key: SystemMediaKeyEvent?, modified: Bool) -> Bool {
        guard let type = CGEventType(rawValue: eventType) else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A disabled tap fails open. Require another explicit enable rather
            // than silently restoring global interception after revocation.
            disable(); error = "macOS disabled the media-key tap. All keys pass through until you enable it again."
            return false
        }
        guard enabled, let key else { return false }
        guard !modified else { handledPresses.remove(key.key); return false }
        guard canPresentHUD?() ?? true else { handledPresses.remove(key.key); return false }
        guard AXIsProcessTrusted() else {
            disable(); error = "Accessibility permission was revoked. macOS handles every media key."; return false
        }
        if key.phase == .released {
            return handledPresses.remove(key.key) != nil
        }
        do {
            let value = try key.key.kind == .volume ? SystemAudioHardware.adjust(key.key) : display.adjust(increasing: key.key == .brightnessUp)
            handledPresses.insert(key.key); error = nil; publish(value)
            return true
        } catch {
            handledPresses.remove(key.key); self.error = error.localizedDescription
            return false
        }
    }
    private func publish(_ value: SystemHUDSnapshot) {
        hud = value; onHUD?(value); dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
            self?.hud = nil; self?.onHUD?(nil); self?.dismissTask = nil
        }
    }
}

private final class SystemHUDTapContext {
    weak var owner: SystemControlsService?
    init(owner: SystemControlsService) { self.owner = owner }
}

@MainActor
struct HUDToolView: View {
    @ObservedObject private var service = SystemControlsService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Volume & Brightness HUD", systemImage: "slider.horizontal.3").font(.headline)
            Text(service.status).foregroundStyle(.secondary)
            HStack {
                Button("Enable HUD", action: service.enable).disabled(service.enabled)
                Button("Disable", action: service.disable).disabled(!service.enabled)
            }
            if let hud = service.hud {
                SystemHUDCompactView(snapshot: hud)
            }
            if let error = service.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("Enabling requests Accessibility access to intercept supported media keys. The hardware must accept and confirm each adjustment; otherwise the key passes through to the system HUD. Display brightness uses public IOKit controls and can be unavailable on Apple Silicon or external displays. This explicit opt-in continues while the dashboard is closed; Disable removes the event tap.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct SystemHUDCompactView: View {
    let snapshot: SystemHUDSnapshot
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.symbol)
            Text(snapshot.label).font(.caption.weight(.medium))
            ProgressView(value: snapshot.muted ? 0 : snapshot.level).frame(width: 72)
            Text("\(snapshot.percent)%").font(.caption.monospacedDigit())
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(snapshot.label), \(snapshot.percent) percent")
    }
}
