import AppKit
import SwiftUI
@preconcurrency import AVFoundation
@preconcurrency import Intents
import NotchCore

private enum SystemStatusReader {
    static func read() throws -> SystemStatusSnapshot {
        try Task.checkCancellation()
        let input = SystemAudioHardware.inputDeviceActivity()
        let camera: Bool?; let description: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified)
            let cameras = discovery.devices
            if cameras.isEmpty { camera = nil; description = "No authorized camera device was reported." }
            else {
                camera = cameras.contains { $0.isInUseByAnotherApplication }
                description = "Public camera-device activity in another application; this does not include Mirror in this app."
            }
        case .denied, .restricted: camera = nil; description = "Camera access is denied or restricted; camera activity is unavailable."
        case .notDetermined: camera = nil; description = "Camera permission has not been granted. Status does not request access or start a camera."
        @unknown default: camera = nil; description = "Camera authorization is unavailable."
        }
        try Task.checkCancellation()
        return .init(inputDeviceName: input.0, inputDeviceIsRunning: input.1,
                     cameraInUseByAnotherApplication: camera, cameraStatus: description)
    }
}

@MainActor
final class StatusService: ObservableObject {
    static let shared = StatusService()
    @Published private(set) var snapshot: SystemStatusSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isSampling = false
    @Published private(set) var focus = SystemFocusSnapshot(authorization: .notConnected)
    @Published private(set) var requestingFocus = false
    @Published private(set) var focusConnected = false
    @Published var backgroundMonitoring = false { didSet { reconcile() } }
    private var visible = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var focusGeneration = UUID()
    func resume() { visible = true; reconcile() }
    func stop() { visible = false; reconcile() }
    func shutdown() { disconnectFocus(); visible = false; backgroundMonitoring = false; reconcile() }
    // Only this explicit user action can request Focus authorization. Sampling never requests it.
    func connectFocus() {
        guard !requestingFocus else { return }
        focusConnected = true
        guard NSClassFromString("INFocusStatusCenter") != nil else {
            focus = .init(authorization: .unavailable); return
        }
        let center = INFocusStatusCenter.default
        focus = focusReading(from: center, includeValue: visible || backgroundMonitoring)
        guard center.authorizationStatus == .notDetermined else { publishFocus(); return }
        requestingFocus = true
        let token = UUID(); focusGeneration = token
        let owner = self
        center.requestAuthorization { status in
            let code = status.rawValue
            Task { @MainActor [owner] in
                guard owner.focusConnected, owner.focusGeneration == token else { return }
                owner.requestingFocus = false
                // The callback's status is permission state; re-read only while monitoring is active.
                owner.focus = .init(authorization: Self.focusAuthorization(code))
                owner.refreshFocus()
                owner.publishFocus()
            }
        }
    }
    func disconnectFocus() {
        focusGeneration = UUID(); requestingFocus = false; focusConnected = false
        focus = .init(authorization: .notConnected); publishFocus()
    }
    private static func focusAuthorization(_ rawValue: Int) -> SystemFocusAuthorization {
        switch rawValue {
        case INFocusStatusAuthorizationStatus.notDetermined.rawValue: .notDetermined
        case INFocusStatusAuthorizationStatus.restricted.rawValue: .restricted
        case INFocusStatusAuthorizationStatus.denied.rawValue: .denied
        case INFocusStatusAuthorizationStatus.authorized.rawValue: .authorized
        default: .unavailable
        }
    }
    private func focusReading(from center: INFocusStatusCenter, includeValue: Bool) -> SystemFocusSnapshot {
        let authorization = Self.focusAuthorization(center.authorizationStatus.rawValue)
        guard authorization == .authorized, includeValue else { return .init(authorization: authorization) }
        // The SDK refines NSNumber to Bool in Swift; the Foundation bridge handles either representation.
        let reported: Any? = center.focusStatus.isFocused
        return .init(authorization: authorization, isFocused: (reported as? NSNumber)?.boolValue)
    }
    private func refreshFocus() {
        guard focusConnected else { focus = .init(authorization: .notConnected); return }
        guard NSClassFromString("INFocusStatusCenter") != nil else { focus = .init(authorization: .unavailable); return }
        focus = focusReading(from: INFocusStatusCenter.default, includeValue: visible || backgroundMonitoring)
    }
    private func publishFocus() {
        guard let previous = snapshot else { return }
        snapshot = .init(inputDeviceName: previous.inputDeviceName, inputDeviceIsRunning: previous.inputDeviceIsRunning,
                         cameraInUseByAnotherApplication: previous.cameraInUseByAnotherApplication,
                         cameraStatus: previous.cameraStatus, date: previous.date, focus: focus)
    }
    private func reconcile() {
        guard visible || backgroundMonitoring else {
            generation = UUID(); task?.cancel(); task = nil; isSampling = false; snapshot = nil
            focus = .init(authorization: focus.authorization); return
        }
        guard task == nil else { return }
        let token = UUID(); generation = token; isSampling = true
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let work = Task.detached { try SystemStatusReader.read() }
                do {
                    let reading = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    try Task.checkCancellation()
                    guard let self, self.generation == token else { return }
                    self.refreshFocus()
                    self.snapshot = .init(inputDeviceName: reading.inputDeviceName, inputDeviceIsRunning: reading.inputDeviceIsRunning,
                                          cameraInUseByAnotherApplication: reading.cameraInUseByAnotherApplication,
                                          cameraStatus: reading.cameraStatus, date: reading.date, focus: self.focus)
                    self.error = nil
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError { return }
                catch {
                    guard let self, self.generation == token else { return }
                    self.error = error.localizedDescription; self.task = nil; self.isSampling = false; return
                }
            }
        }
    }
}

@MainActor
struct StatusToolView: View {
    @ObservedObject private var service = StatusService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Status", systemImage: "eye").font(.headline)
            Toggle("Monitor status while dashboard is closed", isOn: Binding(get: { service.backgroundMonitoring }, set: { service.backgroundMonitoring = $0 }))
            if let value = service.snapshot {
                LabeledContent("Default input device", value: value.inputDeviceName ?? "Unavailable")
                LabeledContent("Input device activity", value: value.inputDeviceIsRunning.map { $0 ? "Device is running" : "Device is not running" } ?? "Unavailable")
                Text("CoreAudio reports whether the default input device is running somewhere. This does not identify an app or prove that it is recording microphone audio.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                LabeledContent("Camera in another app", value: value.cameraInUseByAnotherApplication.map { $0 ? "In use" : "Not reported in use" } ?? "Unavailable")
                Text(value.cameraStatus).font(.caption).foregroundStyle(.secondary)
                Text("Checked \(value.date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            } else { Text("Reading available public device properties…").foregroundStyle(.secondary) }
            Divider()
            LabeledContent("Focus status", value: service.focus.isFocused.map { $0 ? "Active" : "Not active" } ?? "Unavailable")
            Text(service.focus.statusDescription).font(.caption).foregroundStyle(.secondary)
            Text("The public Intents API reports shared Focus status. It does not identify a Focus mode or distinguish Do Not Disturb from other modes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(service.requestingFocus ? "Waiting for permission…" : "Connect Focus") { service.connectFocus() }
                    .disabled(service.requestingFocus || service.focusConnected)
                if service.focusConnected { Button("Disconnect Focus") { service.disconnectFocus() } }
            }
            if let error = service.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.onAppear { service.resume() }.onDisappear { service.stop() }
            .background(OrbitNativeToolVisibility(onVisible: service.resume, onHidden: service.stop).frame(width: 0, height: 0))
    }
}
