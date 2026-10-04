import AppKit
import SwiftUI
import NotchCore

@MainActor
final class ContextService: ObservableObject {
    static let shared = ContextService()
    @Published private(set) var rules: [ContextRule]
    @Published private(set) var proposal: ContextProposal?
    @Published private(set) var previewProposal: ContextProposal?
    @Published private(set) var hasPreviewed = false
    @Published private(set) var error: String?
    @Published private(set) var isSampling = false
    @Published private(set) var editorOpen = false
    @Published var enabled = false { didSet { reconcile() } }
    @Published var backgroundMonitoring = false { didSet { reconcile() } }
    @Published var canUndoSelection = false
    var visibleToolIDsProvider: (@MainActor () -> Set<String>)?
    var injectedStateProvider: (@MainActor () -> ContextSignals)?
    var onProposal: (@MainActor (ContextProposal) -> Void)?
    var onUndoSelection: (@MainActor () -> Void)?
    private let defaults: UserDefaults
    private var visible = false
    private var task: Task<Void, Never>?
    private var lastProposal: ContextProposal?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; rules = ContextRule.defaults
        if let bytes = defaults.data(forKey: "plus.context.rules") {
            do {
                guard bytes.count <= 64_000 else { throw ContextRuleError.invalid("Saved context rules exceed their limit.") }
                let saved = try JSONDecoder().decode([ContextRule].self, from: bytes)
                guard saved.count <= 32, Set(saved.map(\.id)).count == saved.count else { throw ContextRuleError.invalid("Saved context rules contain duplicate or excess entries.") }
                rules = try saved.map { try $0.validated() }
            } catch { self.error = error.localizedDescription; defaults.set(bytes, forKey: "plus.context.preserved-invalid") }
        }
    }
    func save(_ rule: ContextRule) -> Bool {
        do {
            let value = try rule.validated()
            var updated = rules
            if let index = updated.firstIndex(where: { $0.id == value.id }) { updated[index] = value }
            else { guard updated.count < 32 else { throw ContextRuleError.invalid("Use at most 32 context rules.") }; updated.append(value) }
            try persist(updated); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func remove(_ id: UUID) { do { try persist(rules.filter { $0.id != id }) } catch { self.error = error.localizedDescription } }
    func move(_ id: UUID, by offset: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(index + offset) else { return }
        var updated = rules; updated.swapAt(index, index + offset)
        do { try persist(updated) } catch { self.error = error.localizedDescription }
    }
    private func persist(_ values: [ContextRule]) throws {
        defaults.set(try JSONEncoder().encode(values), forKey: "plus.context.rules")
        rules = values; lastProposal = nil; error = nil
    }
    func resume() { visible = true; reconcile() }
    func setEditorOpen(_ value: Bool) { editorOpen = value }
    func previewCurrent() {
        previewProposal = ContextRuleSelection.proposal(rules: rules, observation: currentObservation(),
                                                       visibleToolIDs: visibleToolIDsProvider?() ?? [])
        hasPreviewed = true
    }
    func undoLastSelection() {
        guard canUndoSelection else { return }
        onUndoSelection?()
    }
    func stop() { visible = false; reconcile() }
    func shutdown() { enabled = false; backgroundMonitoring = false; visible = false; canUndoSelection = false; reconcile() }
    private func reconcile() {
        guard enabled, visible || backgroundMonitoring else {
            task?.cancel(); task = nil; isSampling = false; proposal = nil; lastProposal = nil; return
        }
        guard task == nil else { return }
        isSampling = true
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sample()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private func currentObservation() -> ContextObservation {
        let workspace = NSWorkspace.shared
        return ContextObservation(frontmostApp: workspace.frontmostApplication?.bundleIdentifier,
            runningApps: Set(workspace.runningApplications.compactMap(\.bundleIdentifier)), signals: injectedStateProvider?() ?? .init())
    }
    private func sample() {
        let next = ContextRuleSelection.proposal(rules: rules, observation: currentObservation(), visibleToolIDs: visibleToolIDsProvider?() ?? [])
        proposal = next
        if next != lastProposal { lastProposal = next; if let next { onProposal?(next) } }
    }
}

@MainActor
struct ContextToolView: View {
    @ObservedObject private var service: ContextService
    @State private var editing: ContextRule?
    init(service: ContextService = .shared) { self.service = service }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Context rules", systemImage: "wand.and.stars").font(.headline)
            Toggle("Enable context suggestions", isOn: Binding(get: { service.enabled }, set: { service.enabled = $0 }))
            Toggle("Observe while dashboard is closed", isOn: Binding(get: { service.backgroundMonitoring }, set: { service.backgroundMonitoring = $0 })).disabled(!service.enabled)
            Text("The first enabled matching rule may select a visible tool. Rules never launch apps, run a workflow, or execute an action.").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(service.rules) { rule in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { flag in var copy = rule; copy.enabled = flag; _ = service.save(copy) })).labelsHidden()
                            .accessibilityLabel("Enable rule \(rule.name)")
                        VStack(alignment: .leading) { Text(rule.name); Text("\(rule.trigger.title) → \(PlusTool(rawValue: rule.toolID)?.title ?? "Unavailable tool")").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { service.move(rule.id, by: -1) } label: { Image(systemName: "chevron.up") }.help("Earlier priority")
                            .accessibilityLabel("Move \(rule.name) earlier")
                        Button { service.move(rule.id, by: 1) } label: { Image(systemName: "chevron.down") }.help("Later priority")
                            .accessibilityLabel("Move \(rule.name) later")
                        Button("Edit") { service.setEditorOpen(true); editing = rule }
                        Button { service.remove(rule.id) } label: { Image(systemName: "trash") }.help("Delete rule")
                            .accessibilityLabel("Delete rule \(rule.name)")
                    }
                }
            }.frame(height: 200)
            Button("Add Rule") { service.setEditorOpen(true); editing = .init(name: "New rule", trigger: .frontmostApp, toolID: "teleprompter") }.disabled(service.rules.count >= 32)
            HStack {
                Button("Preview Current Match", action: service.previewCurrent)
                Button("Undo Last Selection", action: service.undoLastSelection)
                    .disabled(!service.canUndoSelection || service.onUndoSelection == nil)
            }
            if service.hasPreviewed {
                if let preview = service.previewProposal {
                    Text("Preview: \(preview.ruleName) → \(PlusTool(rawValue: preview.toolID)?.title ?? "Unavailable tool"). No selection was applied.").font(.caption).foregroundStyle(.secondary)
                } else { Text("Preview: no enabled rule matches a visible tool in the current context.").font(.caption).foregroundStyle(.secondary) }
            }
            if let proposal = service.proposal { Text("Matched: \(proposal.ruleName) → \(PlusTool(rawValue: proposal.toolID)?.title ?? "Unavailable tool")").font(.caption) }
            LocalToolError(message: service.error)
        }.sheet(item: $editing, onDismiss: { service.setEditorOpen(false) }) { rule in ContextRuleEditor(rule: rule, save: service.save) }
            .onAppear { service.resume() }.onDisappear { service.stop() }
            .background(OrbitNativeToolVisibility(onVisible: service.resume, onHidden: service.stop).frame(width: 0, height: 0))
    }
}
@MainActor
private struct ContextRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: ContextRule
    @State private var error: String?
    let save: @MainActor (ContextRule) -> Bool
    init(rule: ContextRule, save: @escaping @MainActor (ContextRule) -> Bool) { _rule = State(initialValue: rule); self.save = save }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Context rule").font(.title2)
            TextField("Rule name", text: $rule.name)
            Picker("When", selection: $rule.trigger) { ForEach(ContextTrigger.allCases, id: \.self) { Text($0.title).tag($0) } }
            if [.frontmostApp, .runningApp].contains(rule.trigger) {
                Menu("Choose Running App") {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "Application") { rule.appBundleID = app.bundleIdentifier ?? "" }
                    }
                }
                TextField("Application identifier", text: $rule.appBundleID)
            }
            Picker("Show tool", selection: $rule.toolID) {
                ForEach(PlusTool.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Text("Hidden tools are ignored until you make them visible in Settings.").font(.caption).foregroundStyle(.secondary)
            Toggle("Open expanded dashboard", isOn: Binding(get: { rule.showExpanded }, set: { rule.showExpanded = $0 }))
            LocalToolError(message: error)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { if save(rule) { dismiss() } else { error = "Check the rule fields and service error." } } }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 440)
    }
}
