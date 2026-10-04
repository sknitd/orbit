import AppKit
import Carbon
import NotchCore

@MainActor
final class DictationHoldShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (@MainActor (Bool) -> Void)?
    func configure(_ shortcut: DictationShortcut, action: @escaping @MainActor (Bool) -> Void) -> Bool {
        stop(); self.action = action
        let types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = types.withUnsafeBufferPointer { pointer in
            InstallEventHandler(GetApplicationEventTarget(), { _, event, raw in
                guard let event, let raw else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard result == noErr, identifier.signature == 0x44494354, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                let owner = Unmanaged<DictationHoldShortcut>.fromOpaque(raw).takeUnretainedValue()
                Task { @MainActor [weak owner] in owner?.action?(pressed) }
                return noErr
            }, UInt32(types.count), pointer.baseAddress, context, &handler)
        }
        guard installed == noErr else { stop(); return false }
        let code: UInt32
        switch shortcut.key { case .d: code = UInt32(kVK_ANSI_D); case .r: code = UInt32(kVK_ANSI_R); case .space: code = UInt32(kVK_Space) }
        let modifiers: UInt32
        switch shortcut.modifiers {
        case .controlOption: modifiers = UInt32(controlKey | optionKey)
        case .controlShift: modifiers = UInt32(controlKey | shiftKey)
        case .commandOption: modifiers = UInt32(cmdKey | optionKey)
        }
        let identifier = EventHotKeyID(signature: 0x44494354, id: 1)
        let registered = RegisterEventHotKey(code, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else { stop(); return false }
        return true
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil; action = nil
    }
}
