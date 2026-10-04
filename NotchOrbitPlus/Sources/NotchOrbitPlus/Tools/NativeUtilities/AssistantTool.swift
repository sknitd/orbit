import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

private enum OrbitAssistantMode: String, CaseIterable, Identifiable {
    case chat = "Ask", rewrite = "Rewrite", summarize = "Summarize"
    var id: String { rawValue }
}

private struct OrbitAssistantMessage: Identifiable {
    let id = UUID()
    let role: String
    let text: String
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@MainActor
private final class OrbitOnDeviceAssistant {
    private let session = LanguageModelSession(instructions: "Help the user clearly and concisely. Do not claim to browse, access files, or take actions. Preserve the user's meaning when rewriting and summarize only the text supplied.")
    func respond(to prompt: String) async throws -> String {
        try await session.respond(to: prompt).content
    }
}
#endif

@MainActor
private final class OrbitAssistantModel: ObservableObject {
    @Published var input = ""
    @Published var mode: OrbitAssistantMode = .chat
    @Published var messages: [OrbitAssistantMessage] = []
    @Published var available = false
    @Published var availability = "Checking on-device model availability…"
    @Published var error: String?
    @Published var busy = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    // Type erasure prevents older deployment targets from storing a newer-SDK type.
    private var backend: AnyObject?

    func checkAvailability() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                available = true; availability = "Apple's on-device model is ready. Your text stays on this Mac."
            case .unavailable(let reason):
                available = false
                switch reason {
                case .deviceNotEligible: availability = "This Mac is not eligible for Apple's on-device language model."
                case .appleIntelligenceNotEnabled: availability = "Enable Apple Intelligence in System Settings to use Ask Orbit."
                case .modelNotReady: availability = "Apple's on-device model is not ready. Complete its download in System Settings, then check again."
                @unknown default: availability = "Apple's on-device language model is currently unavailable."
                }
            @unknown default:
                available = false; availability = "Apple's on-device language model is currently unavailable."
            }
            return
        }
        #endif
        available = false
        availability = "Ask Orbit requires macOS 26, an eligible Mac, and enabled Apple Intelligence. This build has no cloud fallback."
    }

    func submit() {
        checkAvailability()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard available, !busy, !text.isEmpty else { return }
        guard text.count <= 6_000 else { error = "Use 6,000 characters or fewer. The on-device model also enforces its own context limit."; return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let engine: OrbitOnDeviceAssistant
            if mode == .chat, let existing = backend as? OrbitOnDeviceAssistant { engine = existing }
            else { engine = OrbitOnDeviceAssistant(); backend = engine }
            let prompt: String
            switch mode {
            case .chat: prompt = text
            case .rewrite: prompt = "Rewrite the following text for clarity, preserving its meaning. Return only the rewritten text:\n\n" + text
            case .summarize: prompt = "Summarize the following text accurately and briefly. Use only facts present in it:\n\n" + text
            }
            let id = UUID(); generation = id; busy = true; error = nil
            messages.append(OrbitAssistantMessage(role: "You", text: text))
            input = ""
            task = Task { [weak self] in
                guard let self else { return }
                defer { if self.generation == id { self.busy = false; self.task = nil } }
                do {
                    let response = try await engine.respond(to: prompt)
                    try Task.checkCancellation()
                    guard self.generation == id else { return }
                    self.messages.append(OrbitAssistantMessage(role: "Orbit", text: response))
                } catch is CancellationError {
                    if self.generation == id { self.error = "Request cancelled." }
                } catch {
                    guard self.generation == id else { return }
                    self.error = error.localizedDescription
                    self.backend = nil
                }
            }
        }
        #endif
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; busy = false; backend = nil
    }
    func reset() { cancel(); messages = []; error = nil }
}

@MainActor
struct AssistantToolView: View {
    @StateObject private var model = OrbitAssistantModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask Orbit").font(.headline)
            Text(model.availability).font(.caption).foregroundStyle(.secondary)
            if !model.available { Button("Check availability", action: model.checkAvailability) }
            Picker("Task", selection: $model.mode) {
                ForEach(OrbitAssistantMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).onChange(of: model.mode) { _, _ in model.reset() }
            TextEditor(text: $model.input).frame(height: 90).disabled(!model.available || model.busy)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                .accessibilityLabel("Text or question for Ask Orbit")
            HStack {
                Button(model.mode.rawValue, action: model.submit).disabled(!model.available || model.busy || model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.busy { ProgressView().controlSize(.small); Button("Cancel", action: model.cancel) }
                Button("New conversation", action: model.reset).disabled(model.messages.isEmpty && !model.busy)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(message.text).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxHeight: 200)
        }.onAppear { model.checkAvailability() }.onDisappear { model.cancel() }
            .background(OrbitNativeToolVisibility(onVisible: model.checkAvailability, onHidden: model.cancel).frame(width: 0, height: 0))
    }
}
