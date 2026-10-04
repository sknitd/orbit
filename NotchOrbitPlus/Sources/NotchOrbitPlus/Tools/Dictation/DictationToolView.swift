import SwiftUI
import NotchCore

@MainActor
struct DictationToolView: View {
    @ObservedObject var store: DictationToolStore
    init(store: DictationToolStore = .shared) { self.store = store }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("On-Device Dictation", systemImage: "waveform").font(.headline)
            Picker("Language", selection: $store.locale) {
                Text("English (US)").tag("en-US"); Text("Spanish").tag("es-ES")
                Text("French").tag("fr-FR"); Text("German").tag("de-DE")
                Text("Japanese").tag("ja-JP"); Text("Chinese (Simplified)").tag("zh-CN")
            }.disabled(store.isPreparing || store.isListening || store.isFinishing)
            HStack {
                Picker("Hold modifiers", selection: Binding(get: { store.shortcut.modifiers }, set: {
                    store.updateShortcut(.init(key: store.shortcut.key, modifiers: $0))
                })) { ForEach(DictationShortcutModifiers.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Hold key", selection: Binding(get: { store.shortcut.key }, set: {
                    store.updateShortcut(.init(key: $0, modifiers: store.shortcut.modifiers))
                })) { ForEach(DictationShortcutKey.allCases) { Text($0.rawValue).tag($0) } }
            }.disabled(store.isPreparing || store.isListening || store.isFinishing)
            Toggle("Enable \(store.shortcut.title) hold shortcut", isOn: Binding(get: { store.shortcutEnabled }, set: { store.setShortcutEnabled($0) }))
            Toggle("Append completed hold dictation to Quick Note", isOn: Binding(get: { store.appendHoldToQuickNote }, set: { store.setAppendHoldToQuickNote($0) }))
            Toggle("Allow dictation while dashboard is hidden", isOn: Binding(get: { store.backgroundMonitoring }, set: { store.setBackgroundMonitoring($0) }))
            HStack {
                Button("Start") { store.start() }.disabled(store.isPreparing || store.isListening || store.isFinishing)
                if store.isListening { Button("Stop") { store.stop() } }
                if store.isPreparing || store.isListening || store.isFinishing { Button("Cancel") { store.cancel() } }
                if store.isPreparing || store.isFinishing { ProgressView().controlSize(.small) }
            }
            if store.isListening {
                HStack(alignment: .center, spacing: 3) {
                    ForEach(Array(store.waveform.enumerated()), id: \.offset) { _, level in
                        Capsule().fill(Color.accentColor).frame(width: 4, height: max(2, level * 44))
                    }
                    if store.waveform.isEmpty { Text("Waiting for microphone samples…").font(.caption).foregroundStyle(.secondary) }
                }.frame(height: 48).accessibilityLabel("Actual microphone level \(Int(store.amplitude * 100)) percent")
            }
            Text(store.status).font(.caption).foregroundStyle(.secondary)
            if !store.transcript.isEmpty {
                ScrollView { Text(store.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 160)
                HStack {
                    Button("Copy Transcript") { store.copy() }
                    Button("Send to Quick Note") { store.sendToQuickNote() }
                        .disabled(store.isListening || store.isPreparing || store.isFinishing)
                }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("Start may request Speech and Microphone access. Recognition requires an available on-device model; there is no cloud fallback. With hold append enabled, release sends the final transcript once; canceled or partial text stays here. Start-button recordings use Send. Hiding stops the microphone unless you explicitly allow background dictation above. No audio files are saved.")
                .font(.caption2).foregroundStyle(.secondary)
        }.background(CaptureToolVisibility(onVisible: { store.setVisible(true) }, onHidden: { store.setVisible(false) }).frame(width: 0, height: 0))
    }
}
