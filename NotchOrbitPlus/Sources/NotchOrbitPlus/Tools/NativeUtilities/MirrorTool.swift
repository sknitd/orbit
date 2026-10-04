import SwiftUI
import AppKit
@preconcurrency import AVFoundation

/// Configuration and start/stop are confined to one serial queue. The preview
/// layer consumes the session through AVFoundation's supported rendering API.
private final class OrbitMirrorPipeline: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.sknitd.NotchOrbitPlus.mirror")

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    if session.inputs.isEmpty {
                        guard let camera = AVCaptureDevice.default(for: .video) else {
                            throw NSError(domain: "NotchOrbitPlus.Mirror", code: 1, userInfo: [NSLocalizedDescriptionKey: "No camera is available. Connect a camera and try again."])
                        }
                        let input = try AVCaptureDeviceInput(device: camera)
                        session.beginConfiguration()
                        defer { session.commitConfiguration() }
                        if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
                        guard session.canAddInput(input) else {
                            throw NSError(domain: "NotchOrbitPlus.Mirror", code: 2, userInfo: [NSLocalizedDescriptionKey: "The camera cannot be added to this capture session."])
                        }
                        session.addInput(input)
                    }
                    if !session.isRunning { session.startRunning() }
                    guard session.isRunning else {
                        throw NSError(domain: "NotchOrbitPlus.Mirror", code: 3, userInfo: [NSLocalizedDescriptionKey: "Camera capture did not start. Another application or device issue may be preventing capture."])
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }
}

@MainActor
private final class OrbitMirrorModel: ObservableObject {
    let pipeline = OrbitMirrorPipeline()
    @Published var running = false
    @Published var starting = false
    @Published var message = "Start Mirror to use your camera. Audio is never captured."
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start() {
        guard !running, !starting else { return }
        let id = UUID(); generation = id; starting = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == id { self.starting = false; self.task = nil } }
            let permission: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: permission = true
            case .notDetermined: permission = await AVCaptureDevice.requestAccess(for: .video)
            case .denied, .restricted: permission = false
            @unknown default: permission = false
            }
            guard self.generation == id, !Task.isCancelled else { return }
            guard permission else {
                self.message = "Camera access is unavailable. Allow NotchOrbit Plus in System Settings → Privacy & Security → Camera."
                return
            }
            do {
                try await self.pipeline.start()
                guard self.generation == id, !Task.isCancelled else { self.pipeline.stop(); return }
                self.running = true
                self.message = "Camera preview is active. Hiding this tool stops capture. No audio is captured or recorded."
            } catch { self.message = error.localizedDescription }
        }
    }

    func stop() {
        generation = UUID(); task?.cancel(); task = nil; pipeline.stop()
        running = false; starting = false
        message = "Camera stopped. Start Mirror when you need it."
    }
}

@MainActor
private final class OrbitMirrorPreviewView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer = CALayer(); preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func layout() {
        super.layout(); preview.frame = bounds
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}

@MainActor
private struct OrbitMirrorPreview: NSViewRepresentable {
    let pipeline: OrbitMirrorPipeline
    func makeNSView(context: Context) -> OrbitMirrorPreviewView {
        let view = OrbitMirrorPreviewView(frame: .zero); view.preview.session = pipeline.session
        return view
    }
    func updateNSView(_ view: OrbitMirrorPreviewView, context: Context) { view.preview.session = pipeline.session }
    static func dismantleNSView(_ view: OrbitMirrorPreviewView, coordinator: ()) { view.preview.session = nil }
}

@MainActor
struct MirrorToolView: View {
    @StateObject private var model = OrbitMirrorModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mirror").font(.headline)
            OrbitMirrorPreview(pipeline: model.pipeline).frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    if !model.running { Text(model.starting ? "Starting camera…" : "Camera stopped").padding(8).background(.regularMaterial, in: Capsule()) }
                }
            HStack {
                Button(model.starting ? "Starting…" : "Start Mirror", action: model.start).disabled(model.running || model.starting)
                Button("Stop", action: model.stop).disabled(!model.running && !model.starting)
            }
            Text(model.message).font(.caption).foregroundStyle(.secondary)
        }.onDisappear { model.stop() }
            .background(OrbitNativeToolVisibility(onVisible: {}, onHidden: model.stop).frame(width: 0, height: 0))
    }
}
