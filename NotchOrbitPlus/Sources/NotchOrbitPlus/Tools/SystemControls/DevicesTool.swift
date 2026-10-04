import AppKit
import SwiftUI
import IOKit
import IOKit.ps
@preconcurrency import CoreBluetooth
@preconcurrency import IOBluetooth
import NotchCore

private struct SystemDeviceReading: Sendable {
    let devices: [SystemDeviceSnapshot]
    let errors: [String]
}
private enum SystemDeviceReader {
    static func read() throws -> SystemDeviceReading {
        try Task.checkCancellation()
        var devices: [SystemDeviceSnapshot] = []; var errors: [String] = []
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() {
            for (index, source) in (sources as NSArray).enumerated() {
                guard let values = IOPSGetPowerSourceDescription(info, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                      values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                let current = (values[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
                let maximum = (values[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
                let battery = current.flatMap { value in maximum.flatMap { SystemDeviceSnapshot.batteryPercent(current: value, maximum: $0) } }
                let charging = values[kIOPSIsChargingKey] as? Bool
                let power = values[kIOPSPowerSourceStateKey] as? String
                devices.append(.init(id: "internal-\(index)", name: values[kIOPSNameKey] as? String ?? "Internal battery",
                                     connection: "Mac", batteryPercent: battery,
                                     detail: charging == true ? "Charging" : power == kIOPSACPowerValue ? "Power adapter" : power == kIOPSBatteryPowerValue ? "Battery power" : nil))
            }
        } else { errors.append("macOS power-source information is unavailable.") }
        var iterator: io_iterator_t = 0
        let code = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator)
        if code == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while true {
                try Task.checkCancellation()
                let service = IOIteratorNext(iterator); if service == 0 { break }
                defer { IOObjectRelease(service) }
                var dictionary: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &dictionary, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let values = dictionary?.takeRetainedValue() as? [String: Any],
                      let number = values["BatteryPercent"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let percent = SystemDeviceSnapshot.validBatteryPercent(number.doubleValue) else { continue }
                var identifier: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else { continue }
                devices.append(.init(id: "hid-\(identifier)", name: values["Product"] as? String ?? "HID peripheral",
                                     connection: values["Transport"] as? String ?? "HID",
                                     connected: values["Connected"] as? Bool, batteryPercent: percent,
                                     detail: "BatteryPercent reported by this device's IORegistry entry."))
            }
        } else { errors.append("Published HID battery metadata is unavailable (\(code)).") }
        return SystemDeviceReading(devices: devices, errors: errors)
    }
}

@MainActor
final class DevicesService: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    static let shared = DevicesService()
    @Published private(set) var devices: [SystemDeviceSnapshot] = []
    @Published private(set) var bluetoothDevices: [SystemDeviceSnapshot] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var errors: [String] = []
    @Published private(set) var bluetoothStatus = "Not connected. Bluetooth is read only after you choose Connect."
    @Published private(set) var isSampling = false
    @Published var backgroundMonitoring = false { didSet { reconcile() } }
    private var visible = false
    private var requestedBluetooth = false
    private var central: CBCentralManager?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func resume() { visible = true; reconcile() }
    func stop() { visible = false; reconcile() }
    func shutdown() { backgroundMonitoring = false; visible = false; requestedBluetooth = false; reconcile() }
    func connectBluetooth() {
        requestedBluetooth = true
        guard visible || backgroundMonitoring else { bluetoothStatus = "Open Devices before connecting Bluetooth."; return }
        if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            bluetoothStatus = "Bluetooth access is denied or restricted. Enable it in System Settings → Privacy & Security → Bluetooth."; return
        }
        bluetoothStatus = "Connecting to macOS Bluetooth metadata…"
        if central == nil { central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
        else { updateBluetooth() }
    }
    func disconnectBluetooth() {
        requestedBluetooth = false; central?.delegate = nil; central = nil; bluetoothDevices = []
        bluetoothStatus = "Disconnected. Bluetooth metadata is no longer queried."
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { updateBluetooth() }
    private func updateBluetooth() {
        guard requestedBluetooth, visible || backgroundMonitoring, let central else { return }
        switch central.state {
        case .poweredOn:
            guard CBManager.authorization == .allowedAlways else {
                bluetoothStatus = "Bluetooth permission has not been granted."; bluetoothDevices = []; return
            }
            // This is the only IOBluetooth access path; explicit Connect and a
            // usable authorized controller are prerequisites. No scanning,
            // pairing, audio connection, or undocumented battery selector runs.
            guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
                bluetoothDevices = []; bluetoothStatus = "macOS did not provide a paired-device list."; return
            }
            bluetoothDevices = paired.compactMap { device in
                guard let address = device.addressString, !address.isEmpty else { return nil }
                return .init(id: "bluetooth-\(address)", name: device.name ?? address, connection: "Bluetooth",
                             connected: device.isConnected(), detail: "Battery is not exposed by this public Bluetooth API.")
            }
            bluetoothStatus = bluetoothDevices.isEmpty ? "No paired Bluetooth devices were reported." : "\(bluetoothDevices.count) paired device(s), read from macOS."
        case .poweredOff: bluetoothDevices = []; bluetoothStatus = "Bluetooth is powered off."
        case .unauthorized: bluetoothDevices = []; bluetoothStatus = "Bluetooth access was denied."
        case .unsupported: bluetoothDevices = []; bluetoothStatus = "This Mac does not expose a supported Bluetooth controller."
        case .resetting: bluetoothDevices = []; bluetoothStatus = "The Bluetooth controller is resetting."
        case .unknown: bluetoothDevices = []; bluetoothStatus = "Bluetooth controller state is not available yet."
        @unknown default: bluetoothDevices = []; bluetoothStatus = "Bluetooth state is unavailable."
        }
    }
    private func reconcile() {
        guard visible || backgroundMonitoring else {
            generation = UUID(); task?.cancel(); task = nil; isSampling = false
            central?.delegate = nil; central = nil; bluetoothDevices = []
            devices = []; updatedAt = nil
            return
        }
        if requestedBluetooth, central == nil, CBManager.authorization == .allowedAlways { connectBluetooth() }
        guard task == nil else { return }
        let token = UUID(); generation = token; isSampling = true
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let read = Task.detached { try SystemDeviceReader.read() }
                do {
                    let value = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
                    try Task.checkCancellation()
                    guard let self, self.generation == token else { return }
                    self.devices = value.devices; self.errors = value.errors; self.updatedAt = Date()
                    self.updateBluetooth()
                    try await Task.sleep(for: .seconds(10))
                } catch is CancellationError { return }
                catch {
                    guard let self, self.generation == token else { return }
                    self.errors = [error.localizedDescription]; self.task = nil; self.isSampling = false; return
                }
            }
        }
    }
}

@MainActor
struct DevicesToolView: View {
    @ObservedObject private var service = DevicesService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Devices", systemImage: "headphones").font(.headline)
            Toggle("Monitor devices while dashboard is closed", isOn: Binding(get: { service.backgroundMonitoring }, set: { service.backgroundMonitoring = $0 }))
            if service.devices.isEmpty { Text("No internal battery or public HID battery percentage was reported.").foregroundStyle(.secondary) }
            ForEach(service.devices) { device in row(device) }
            ForEach(service.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            Divider()
            HStack { Button("Connect Bluetooth", action: service.connectBluetooth); Button("Disconnect", action: service.disconnectBluetooth) }
            Text(service.bluetoothStatus).font(.caption).foregroundStyle(.secondary)
            ForEach(service.bluetoothDevices) { device in row(device) }
            if let date = service.updatedAt { Text("Read \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            Text("AirPods and other paired devices show actual name and connection metadata after Bluetooth permission. Battery values appear only when macOS publishes a validated percentage; missing left/right/case battery values are unavailable. No private Bluetooth battery APIs are used.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { service.resume() }.onDisappear { service.stop() }
            .background(OrbitNativeToolVisibility(onVisible: service.resume, onHidden: service.stop).frame(width: 0, height: 0))
    }
    private func row(_ device: SystemDeviceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(device.name).font(.callout.weight(.medium)); Spacer()
                Text(device.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "Battery unavailable")
            }
            Text(device.connection + (device.connected.map { $0 ? " · Connected" : " · Not connected" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            if let detail = device.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
