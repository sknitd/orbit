import AppKit
import CoreAudio
import CoreGraphics
import IOKit
import Darwin
import NotchCore

enum SystemHardwareError: Error, LocalizedError {
    case unavailable(String)
    var errorDescription: String? { switch self { case .unavailable(let value): value } }
}

enum SystemAudioHardware {
    static func defaultDevice(input: Bool) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioObjectID = 0; var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let code = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard code == noErr, device != 0 else { throw SystemHardwareError.unavailable("No default \(input ? "input" : "output") audio device is available (\(code)).") }
        return device
    }
    static func name(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString?; var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value as String?
    }
    static func inputDeviceActivity() -> (String?, Bool?) {
        guard let device = try? defaultDevice(input: true) else { return (nil, nil) }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &address), AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else {
            return (name(device), nil)
        }
        return (name(device), running != 0)
    }
    static func adjust(_ key: SystemMediaKey) throws -> SystemHUDSnapshot {
        let device = try defaultDevice(input: false)
        var volume = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                               mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var current: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &volume), AudioObjectGetPropertyData(device, &volume, 0, nil, &size, &current) == noErr,
              let level = SystemControlLevel.valid(Double(current)) else {
            throw SystemHardwareError.unavailable("The current output has no readable master volume. macOS keeps handling its media keys.")
        }
        var mute = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0; var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectHasProperty(device, &mute) && AudioObjectGetPropertyData(device, &mute, 0, nil, &muteSize, &muted) == noErr
        if key == .mute {
            var settable: DarwinBoolean = false
            guard hasMute, AudioObjectIsPropertySettable(device, &mute, &settable) == noErr, settable.boolValue else {
                throw SystemHardwareError.unavailable("The current output has no writable mute control. macOS keeps handling Mute.")
            }
            var requested: UInt32 = muted == 0 ? 1 : 0
            guard AudioObjectSetPropertyData(device, &mute, 0, nil, muteSize, &requested) == noErr else {
                throw SystemHardwareError.unavailable("macOS did not accept the mute change.")
            }
            var actual: UInt32 = 0
            guard AudioObjectGetPropertyData(device, &mute, 0, nil, &muteSize, &actual) == noErr, actual == requested else {
                _ = AudioObjectSetPropertyData(device, &mute, 0, nil, muteSize, &muted)
                throw SystemHardwareError.unavailable("The mute change could not be confirmed.")
            }
            return SystemHUDSnapshot(kind: .volume, level: level, muted: actual != 0)!
        }
        guard key == .volumeUp || key == .volumeDown,
              let next = SystemControlLevel.stepped(level, increasing: key == .volumeUp) else {
            throw SystemHardwareError.unavailable("This is not a supported volume key.")
        }
        guard !hasMute || muted == 0 else {
            throw SystemHardwareError.unavailable("The output is muted; macOS handles volume keys to preserve its normal unmute behavior.")
        }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &volume, &settable) == noErr, settable.boolValue else {
            throw SystemHardwareError.unavailable("The current output volume is fixed. macOS keeps handling its media keys.")
        }
        var requested = Float32(next)
        guard AudioObjectSetPropertyData(device, &volume, 0, nil, size, &requested) == noErr else {
            throw SystemHardwareError.unavailable("macOS did not accept the volume change.")
        }
        var actual: Float32 = 0
        guard AudioObjectGetPropertyData(device, &volume, 0, nil, &size, &actual) == noErr,
              abs(Double(actual) - next) < 0.015, SystemControlLevel.valid(Double(actual)) != nil else {
            _ = AudioObjectSetPropertyData(device, &volume, 0, nil, size, &current)
            throw SystemHardwareError.unavailable("The volume change could not be confirmed.")
        }
        return SystemHUDSnapshot(kind: .volume, level: Double(actual), muted: hasMute && muted != 0)!
    }
}

/// Dynamically resolves public, deprecated display APIs. No private display
/// framework is loaded; hardware without these controls falls through to macOS.
@MainActor
final class SystemDisplayHardware {
    private typealias DisplayPort = @convention(c) (UInt32) -> UInt32
    private typealias ReadBrightness = @convention(c) (UInt32, UInt32, CFString, UnsafeMutablePointer<Float>) -> Int32
    private typealias WriteBrightness = @convention(c) (UInt32, UInt32, CFString, Float) -> Int32
    private let graphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL)
    private let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL)
    func adjust(increasing: Bool, displayID: CGDirectDisplayID = CGMainDisplayID()) throws -> SystemHUDSnapshot {
        guard let graphics, let ioKit,
              let portSymbol = dlsym(graphics, "CGDisplayIOServicePort"),
              let getSymbol = dlsym(ioKit, "IODisplayGetFloatParameter"),
              let setSymbol = dlsym(ioKit, "IODisplaySetFloatParameter") else {
            throw SystemHardwareError.unavailable("Public display brightness controls are unavailable on this Mac.")
        }
        let displayPort = unsafeBitCast(portSymbol, to: DisplayPort.self)
        let get = unsafeBitCast(getSymbol, to: ReadBrightness.self)
        let set = unsafeBitCast(setSymbol, to: WriteBrightness.self)
        let root = displayPort(displayID)
        guard root != 0 else { throw SystemHardwareError.unavailable("This display does not expose a public brightness control.") }
        let key = "brightness" as CFString
        var services = [root]; var iterator: io_iterator_t = 0
        if IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while true { let service = IOIteratorNext(iterator); if service == 0 { break }; services.append(service) }
        }
        defer { for service in services.dropFirst() { IOObjectRelease(service) } }
        var matches: [(io_service_t, Float)] = []
        for service in services {
            var value: Float = 0
            if get(service, 0, key, &value) == KERN_SUCCESS, SystemControlLevel.valid(Double(value)) != nil { matches.append((service, value)) }
        }
        guard let first = matches.first else { throw SystemHardwareError.unavailable("The selected display's brightness is not available through public IOKit controls.") }
        let next = SystemControlLevel.stepped(Double(first.1), increasing: increasing)!
        guard set(first.0, 0, key, Float(next)) == KERN_SUCCESS else { throw SystemHardwareError.unavailable("The display rejected its brightness change.") }
        var actual: Float = 0
        guard get(first.0, 0, key, &actual) == KERN_SUCCESS, abs(Double(actual) - next) < 0.015,
              let snapshot = SystemHUDSnapshot(kind: .brightness, level: Double(actual)) else {
            _ = set(first.0, 0, key, first.1)
            throw SystemHardwareError.unavailable("The display brightness change could not be confirmed.")
        }
        return snapshot
    }
}
