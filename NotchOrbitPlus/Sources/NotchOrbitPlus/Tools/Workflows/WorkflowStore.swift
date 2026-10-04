import AppKit
import SwiftUI
import OrbitCore
import NotchCore

@MainActor
final class WorkflowStore: ObservableObject {
    static let shared = WorkflowStore()
    @Published private(set) var presets: [WorkflowPreset] = []
    @Published var selectedPresetID: UUID? {
        didSet { defaults.set(selectedPresetID?.uuidString, forKey: "workflows.selected") }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Select a saved preset, then drop files into its target."
    @Published private(set) var outputURLs: [URL] = []
    @Published private(set) var error: String?
    /// Root integration can follow the app's output-folder preference.
    var outputDirectory: URL?
    var onCompleted: (@MainActor (ActionResult) -> Void)?
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var generation: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "workflows.presets") {
            do {
                presets = try Self.validatedStoredPresets(data)
            } catch { self.error = "Could not load saved workflows. Their stored bytes were retained: \(error.localizedDescription)" }
        } else { presets = [.starter] }
        selectedPresetID = defaults.string(forKey: "workflows.selected").flatMap(UUID.init(uuidString:))
        if !presets.contains(where: { $0.id == selectedPresetID }) { selectedPresetID = presets.first?.id }
    }
    var selectedPreset: WorkflowPreset? { presets.first { $0.id == selectedPresetID } }

    @discardableResult
    func save(_ value: WorkflowPreset) -> Bool {
        guard !isRunning else { return false }
        do {
            let valid = try value.validated()
            var next = presets
            if let index = next.firstIndex(where: { $0.id == valid.id }) { next[index] = valid }
            else {
                guard next.count < 24 else { throw WorkflowValidationError.invalid("You can save up to 24 workflows.") }
                next.append(valid)
            }
            try persist(next); presets = next; selectedPresetID = valid.id; error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func remove(_ id: UUID) {
        guard !isRunning else { return }
        do {
            let next = presets.filter { $0.id != id }
            try persist(next); presets = next
            if selectedPresetID == id { selectedPresetID = next.first?.id }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func move(_ id: UUID, by offset: Int) {
        guard !isRunning, let index = presets.firstIndex(where: { $0.id == id }), presets.indices.contains(index + offset) else { return }
        do {
            var next = presets; next.swapAt(index, index + offset)
            try persist(next); presets = next; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func persist(_ values: [WorkflowPreset]) throws {
        // Retain unreadable prior bytes before an explicit user edit replaces them.
        if let existing = defaults.data(forKey: "workflows.presets"),
           (try? Self.validatedStoredPresets(existing)) == nil {
            defaults.set(existing, forKey: "workflows.preserved-invalid")
        }
        defaults.set(try JSONEncoder().encode(values), forKey: "workflows.presets")
    }
    private static func validatedStoredPresets(_ data: Data) throws -> [WorkflowPreset] {
        guard data.count <= 100_000 else { throw WorkflowValidationError.invalid("The saved preset file is too large.") }
        let decoded = try JSONDecoder().decode([WorkflowPreset].self, from: data)
        guard decoded.count <= 24, Set(decoded.map(\.id)).count == decoded.count else {
            throw WorkflowValidationError.invalid("Saved workflow IDs must be unique; at most 24 presets are supported.")
        }
        return try decoded.map { try $0.validated() }
    }

    /// Call only from an actual native dragging destination's perform operation.
    /// The immutable saved preset ID must still match the target shown on entry.
    @discardableResult
    func acceptDrop(_ urls: [URL], presetID: UUID) -> Bool {
        guard !isRunning, selectedPresetID == presetID, let preset = selectedPreset,
              NotchDragPayload.matches(observed: urls, dropped: urls) else { return false }
        let token = UUID(); generation = token
        let directory = outputDirectory
        isRunning = true; progress = 0; error = nil; outputURLs = []
        status = "Starting \(preset.name)…"
        task = Task { @MainActor [weak self] in
            // A stable actor reference is Sendable. Keep this run's owner alive
            // until completion/rollback; clear its task in both terminal paths.
            guard let store = self else { return }
            do {
                let result = try await WorkflowRunner.perform(preset: preset, urls: urls, outputDirectory: directory) { [store] fraction, text in
                    Task { @MainActor [store] in
                        guard store.generation == token, store.isRunning else { return }
                        store.progress = fraction; store.status = text
                    }
                }
                guard store.generation == token else { return }
                store.outputURLs = result.outputs; store.progress = 1
                store.status = "Saved \(result.outputs.count) workflow output\(result.outputs.count == 1 ? "" : "s")."
                store.isRunning = false; store.task = nil; store.onCompleted?(result)
            } catch {
                guard store.generation == token else { return }
                store.isRunning = false; store.task = nil; store.progress = 0
                if error is CancellationError { store.status = "Cancelled; workflow outputs were rolled back." }
                else { store.error = error.localizedDescription; store.status = "Workflow failed; no outputs were kept." }
            }
        }
        return true
    }
    func cancel() {
        guard isRunning else { return }
        status = "Cancelling…"; task?.cancel()
    }
}
