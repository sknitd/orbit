import AppKit
import SwiftUI
import NotchCore

@MainActor
struct WorkflowsToolView: View {
    @ObservedObject private var store: WorkflowStore
    @State private var editing: WorkflowPreset?
    @State private var targeted = false
    @State private var deleting: WorkflowPreset?
    init(store: WorkflowStore = .shared) { self.store = store }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Saved workflows", systemImage: "arrow.triangle.branch").font(.headline)
                Spacer()
                Button("New Preset") {
                    store.setEditorOpen(true)
                    editing = WorkflowPreset(name: "New workflow", steps: [.resize(maxDimension: 1600), .convert(format: .jpeg), .compress(quality: 0.72), .zip])
                }
                    .disabled(store.isRunning || store.presets.count >= 24)
            }
            if !store.presets.isEmpty {
                HStack {
                    Picker("Preset", selection: $store.selectedPresetID) {
                        ForEach(store.presets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                    }.disabled(store.isRunning)
                    Button("Edit") { store.setEditorOpen(true); editing = store.selectedPreset }.disabled(store.isRunning || store.selectedPreset == nil)
                    Button { if let preset = store.selectedPreset { store.move(preset.id, by: -1) } } label: { Image(systemName: "chevron.up") }
                        .help("Move preset earlier").disabled(store.isRunning || store.selectedPresetID == store.presets.first?.id)
                    Button { if let preset = store.selectedPreset { store.move(preset.id, by: 1) } } label: { Image(systemName: "chevron.down") }
                        .help("Move preset later").disabled(store.isRunning || store.selectedPresetID == store.presets.last?.id)
                    Button { deleting = store.selectedPreset } label: { Image(systemName: "trash") }
                        .help("Delete selected preset").disabled(store.isRunning || store.selectedPreset == nil)
                }
            }
            if let preset = store.selectedPreset {
                Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(targeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down").font(.title2)
                        Text(store.isRunning ? "Workflow running" : "Drop to Run \(preset.name)").font(.headline)
                        Text("One drop runs every saved step. Originals stay intact.").font(.caption)
                    }.foregroundStyle(.secondary).padding()
                    WorkflowDropTarget(presetID: preset.id, enabled: !store.isRunning,
                                       isTargeted: $targeted, selectedID: { store.selectedPresetID },
                                       receive: { store.acceptDrop($0, presetID: $1) })
                }.frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(targeted ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: targeted ? 2 : 1))
            } else {
                Text("Create a preset to add its real file drop target.").foregroundStyle(.secondary)
            }
            if store.isRunning {
                HStack {
                    ProgressView(value: store.progress)
                    Button("Cancel", action: store.cancel)
                }
            }
            Text(store.status).font(.caption).foregroundStyle(.secondary)
            LocalToolError(message: store.error)
            if !store.outputURLs.isEmpty {
                Button("Reveal Outputs") { NSWorkspace.shared.activateFileViewerSelecting(store.outputURLs) }
            }
            Text("Images or videos: 64 files maximum, 512 MB each, 2 GB per batch. Each preset uses one media type. Image resize preserves aspect ratio and never enlarges; without Convert it writes PNG. Video compression writes a playable H.264 MP4 using the native preset. Compression must reduce every file, otherwise the whole workflow rolls back. ZIP collects the batch into one archive.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing, onDismiss: { store.setEditorOpen(false) }) { preset in
            WorkflowPresetEditor(preset: preset, save: store.save)
        }
        .confirmationDialog("Delete this saved workflow?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let deleting { Button("Delete \(deleting.name)", role: .destructive) { store.remove(deleting.id); self.deleting = nil } }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }
}

@MainActor
private struct WorkflowPresetEditor: View {
    private enum PresetType: String, CaseIterable { case image = "Images", video = "Video Compression" }
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var presetType: PresetType
    @State private var resizing: Bool
    @State private var dimension: String
    @State private var converting: Bool
    @State private var format: WorkflowFormat
    @State private var compressing: Bool
    @State private var quality: Double
    @State private var zipping: Bool
    @State private var error: String?
    let id: UUID
    let save: @MainActor (WorkflowPreset) -> Bool
    init(preset: WorkflowPreset, save: @escaping @MainActor (WorkflowPreset) -> Bool) {
        id = preset.id; self.save = save
        _name = State(initialValue: preset.name)
        _presetType = State(initialValue: preset.isVideoWorkflow ? .video : .image)
        let size = preset.steps.compactMap { if case .resize(let size) = $0 { size } else { nil as Int? } }.first
        _resizing = State(initialValue: size != nil); _dimension = State(initialValue: String(size ?? 1600))
        let type = preset.steps.compactMap { if case .convert(let type) = $0 { type } else { nil as WorkflowFormat? } }.first
        _converting = State(initialValue: type != nil); _format = State(initialValue: type ?? .jpeg)
        let amount = preset.steps.compactMap { if case .compress(let amount) = $0 { amount } else { nil as Double? } }.first
        _compressing = State(initialValue: amount != nil); _quality = State(initialValue: amount ?? 0.72)
        _zipping = State(initialValue: preset.steps.contains(.zip))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Workflow preset").font(.title2.weight(.semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Workflow type", selection: $presetType) {
                ForEach(PresetType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Form {
                if presetType == .image {
                Toggle("1. Resize longest edge", isOn: $resizing)
                TextField("Maximum pixels (64–12,000)", text: $dimension).disabled(!resizing)
                Toggle("2. Convert format", isOn: $converting)
                Picker("Format", selection: $format) {
                    ForEach(WorkflowFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(!converting)
                Toggle("3. Compress", isOn: $compressing)
                HStack {
                    Slider(value: $quality, in: 0.1...0.95, step: 0.01).disabled(!compressing)
                    Text("\(Int((quality * 100).rounded()))%").monospacedDigit().frame(width: 44)
                }
                } else {
                    Label("1. Compress video to H.264 MP4", systemImage: "film")
                    Text("Apple's native smaller-file preset retains video duration and any existing audio track. A file that cannot become smaller rejects the entire batch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(presetType == .image ? "4. Group outputs in one ZIP" : "2. Group outputs in one ZIP", isOn: $zipping)
            }
            Text(presetType == .image ? "Steps run in the shown order. Quality applies to JPEG, HEIC and WebP. Resizing without conversion writes lossless PNG." : "Drop MOV, MP4 or another video supported by macOS. Image stages cannot be mixed into a video preset. The source recording stays intact.")
                .font(.caption).foregroundStyle(.secondary)
            LocalToolError(message: error)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Preset", action: savePreset).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 460)
    }
    private func savePreset() {
        var steps: [WorkflowStep] = []
        if presetType == .video { steps.append(.compressVideo) }
        else {
        if resizing {
            guard let pixels = Int(dimension.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                error = "Enter a whole-number maximum dimension."; return
            }
            steps.append(.resize(maxDimension: pixels))
        }
        if converting { steps.append(.convert(format: format)) }
        if compressing { steps.append(.compress(quality: quality)) }
        }
        if zipping { steps.append(.zip) }
        do {
            let valid = try WorkflowPreset(id: id, name: name, steps: steps).validated()
            if save(valid) { dismiss() } else { error = "The preset could not be saved. Close this editor to see the error." }
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private struct WorkflowDropTarget: NSViewRepresentable {
    let presetID: UUID
    let enabled: Bool
    @Binding var isTargeted: Bool
    let selectedID: @MainActor () -> UUID?
    let receive: @MainActor ([URL], UUID) -> Bool
    func makeNSView(context: Context) -> WorkflowDropView { WorkflowDropView(frame: .zero) }
    func updateNSView(_ view: WorkflowDropView, context: Context) {
        view.presetID = presetID; view.enabled = enabled
        view.selectedID = selectedID; view.receive = receive
        view.targetChanged = { isTargeted = $0 }
        view.setAccessibilityLabel("Drop files to run the selected saved workflow")
    }
}

@MainActor
private final class WorkflowDropView: NSView {
    var presetID: UUID?
    var enabled = false
    var selectedID: (@MainActor () -> UUID?)?
    var receive: (@MainActor ([URL], UUID) -> Bool)?
    var targetChanged: (@MainActor (Bool) -> Void)?
    private var enteredID: UUID?
    private var enteredURLs: [URL] = []
    override var isOpaque: Bool { false }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        enteredURLs = NotchDragMonitor.fileURLs(from: sender.draggingPasteboard)
        enteredID = presetID
        let accepted = canAccept(sender)
        targetChanged?(accepted)
        return accepted ? .copy : []
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = canAccept(sender); targetChanged?(accepted)
        return accepted ? .copy : []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { clear() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { canAccept(sender) }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard canAccept(sender), let id = enteredID else { clear(); return false }
        let authoritative = NotchDragMonitor.fileURLs(from: sender.draggingPasteboard)
        let result = receive?(authoritative, id) ?? false
        clear(); return result
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { clear() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { clear() }
    private func canAccept(_ sender: any NSDraggingInfo) -> Bool {
        guard enabled, sender.draggingSourceOperationMask.contains(.copy), enteredID != nil,
              enteredID == presetID, enteredID == selectedID?(),
              bounds.contains(convert(sender.draggingLocation, from: nil)) else { return false }
        return NotchDragPayload.matches(observed: enteredURLs, dropped: NotchDragMonitor.fileURLs(from: sender.draggingPasteboard))
    }
    private func clear() { enteredID = nil; enteredURLs = []; targetChanged?(false) }
}
