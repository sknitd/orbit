import AppKit
import Carbon

/// Carbon hotkeys listen only for the registered chord, without observing typing.
@MainActor
final class GlobalNotchShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?
    private static let signature: OSType = 0x4E4F504C

    func configure(enabled: Bool, action: @escaping @MainActor () -> Void) {
        self.action = action
        if !enabled { stop(); return }
        guard hotKey == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, raw in
            guard let event, let raw else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x4E4F504C, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let owner = Unmanaged<GlobalNotchShortcut>.fromOpaque(raw).takeUnretainedValue()
            Task { @MainActor [weak owner] in owner?.action?() }
            return noErr
        }, 1, &type, context, &handler)
        guard installed == noErr else { return }
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | controlKey), identifier,
                                              GetApplicationEventTarget(), 0, &hotKey)
        if registered != noErr { stop() }
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil
    }
}
