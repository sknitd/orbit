import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import NotchCore

@MainActor
final class QRToolStore: ObservableObject {
    static let shared = QRToolStore()
    typealias AreaCapture = @MainActor () async throws -> FileShelfItem
    @Published var payload = ""
    @Published var correction: QRCorrectionLevel = .medium
    @Published var scale = 8
    @Published private(set) var generatedPNG: URL?
    @Published private(set) var preview: NSImage?
    @Published private(set) var generatedSize = ""
    @Published private(set) var decodedPayloads: [String] = []
    @Published private(set) var isWorking = false
    @Published private(set) var status = "Generate a QR code or explicitly scan a PNG or screen region."
    @Published private(set) var error: String?
    private let captureArea: AreaCapture?
    private let exportRoot: URL?
    private var generation: UUID?
    private var task: Task<Void, Never>?

    /// Initialization never samples the screen, asks for permissions, or creates files.
    init(captureArea: AreaCapture? = nil, exportRoot: URL? = nil) {
        self.captureArea = captureArea; self.exportRoot = exportRoot
    }
    func start() { }
    func shutdown() { cancel() }
    func cancel() {
        task?.cancel(); task = nil; generation = nil; isWorking = false
        status = "QR operation cancelled. Previous results remain available."
    }
    private func begin(_ message: String) -> UUID? {
        guard !isWorking else { return nil }
        let token = UUID(); generation = token; isWorking = true; error = nil; status = message
        return token
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }
    private func finish(_ token: UUID) {
        if generation == token { isWorking = false; task = nil }
    }
    private func fail(_ failure: Error, token: UUID) {
        guard generation == token else { return }
        if failure is CancellationError { status = "QR operation cancelled. Previous results remain available." }
        else { error = failure.localizedDescription; status = "QR operation did not produce a new result." }
    }

    func generate() {
        let request: QRGenerationRequest
        do { request = try QRGenerationRequest(payload: payload, options: .init(correction: correction, scale: scale)) }
        catch { self.error = error.localizedDescription; return }
        guard let token = begin("Encoding QR PNG…") else { return }
        task = Task { @MainActor [weak self] in
            guard let store = self else { return }
            defer { store.finish(token) }
            var directory: URL?
            do {
                try store.check(token)
                let owned = try store.createOutputDirectory(); directory = owned
                let worker = Task.detached(priority: .userInitiated) { try QRImageCodec.generate(request, in: owned) }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try store.check(token)
                guard let preview = NSImage(contentsOf: result.url) else { throw QRImageFailure.exportFailed }
                store.generatedPNG = result.url; store.preview = preview
                store.generatedSize = "\(result.width) × \(result.height) pixels"
                store.status = "QR PNG is ready to drag or export."
                // Published exports stay in their owned private folder for later drag/reveal.
                directory = nil
            } catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                store.fail(error, token: token)
            }
        }
    }

    func selectPNG() {
        guard !isWorking else { return }
        let panel = NSOpenPanel(); panel.title = "Scan QR Codes in PNG"
        panel.allowedContentTypes = [.png]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scanPNG(url)
    }
    func scanPNG(_ url: URL) {
        guard let token = begin("Scanning PNG with Vision…") else { return }
        task = Task { @MainActor [weak self] in
            guard let store = self else { return }
            defer { store.finish(token) }
            do {
                try store.check(token)
                let result = try await QRImageCodec.scanPNG(url)
                try store.publish(result, token: token)
            } catch { store.fail(error, token: token) }
        }
    }
    /// The only QR action that can request Screen Recording permission.
    func scanScreenRegion() {
        guard let token = begin("Select a screen region to scan…") else { return }
        task = Task { @MainActor [weak self] in
            guard let store = self else { return }
            defer { store.finish(token) }
            do {
                try store.check(token)
                let item: FileShelfItem
                if let captureArea = store.captureArea { item = try await captureArea() }
                else { item = try await ScreenshotShelfStore.shared.captureAreaForQR() }
                try store.check(token)
                guard let url = item.managedURL else { throw QRImageFailure.invalidPNG }
                store.status = "Scanning the captured PNG with Vision…"
                let result = try await QRImageCodec.scanPNG(url)
                try store.publish(result, token: token)
            } catch { store.fail(error, token: token) }
        }
    }
    private func publish(_ result: QRScanOutput, token: UUID) throws {
        try check(token)
        decodedPayloads = result.payloads
        if result.payloads.isEmpty {
            status = result.unreadableCount == 0 ? "Vision found no QR codes in this image." : "Vision found QR codes without readable text payloads."
        } else {
            status = "Decoded \(result.payloads.count) QR payload\(result.payloads.count == 1 ? "" : "s")."
            if result.unreadableCount > 0 { status += " \(result.unreadableCount) additional QR code(s) had no readable text payload." }
        }
    }

    func copyPayload(at index: Int, to pasteboard: NSPasteboard = .general) {
        guard decodedPayloads.indices.contains(index) else { return }
        pasteboard.clearContents()
        if !pasteboard.setString(decodedPayloads[index], forType: .string) { error = "macOS could not copy this QR payload." }
    }
    func exportPNG() {
        guard let source = generatedPNG else { return }
        let panel = NSSavePanel(); panel.title = "Export QR PNG"
        panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Orbit-QR.png"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            guard source.standardizedFileURL != destination.standardizedFileURL else { return }
            let saved = try OutputTransaction.write(source: source,
                outputDirectory: destination.deletingLastPathComponent(),
                stem: destination.deletingPathExtension().lastPathComponent, extension: "png",
                writer: { staging in try FileManager.default.copyItem(at: source, to: staging) },
                validate: { staging in
                    guard try Data(contentsOf: staging) == Data(contentsOf: source) else { throw QRImageFailure.exportFailed }
                })
            status = "QR PNG exported: " + saved.lastPathComponent; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func revealPNG() {
        guard let generatedPNG, FileManager.default.fileExists(atPath: generatedPNG.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([generatedPNG])
    }

    private func createOutputDirectory() throws -> URL {
        let root = try exportRoot ?? LocalToolStorage.directory().appendingPathComponent("QRExports", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw QRImageFailure.exportFailed }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
}
