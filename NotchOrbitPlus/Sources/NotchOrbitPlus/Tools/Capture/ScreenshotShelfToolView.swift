import SwiftUI
import NotchCore

@MainActor
struct ScreenshotShelfToolView: View {
    @ObservedObject private var store = ScreenshotShelfStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Screenshots and recordings", systemImage: "camera.viewfinder").font(.headline)
            Text("Save a screen, window or selected area directly to File Shelf.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Capture source", selection: $store.selection) {
                Text("Full screen").tag(CaptureSelectionKind.display)
                Text("Window").tag(CaptureSelectionKind.window)
                Text("Selected area").tag(CaptureSelectionKind.area)
            }.pickerStyle(.segmented).disabled(store.isWorking || store.isRecording)
            if store.selection == .window {
                if store.windows.isEmpty {
                    Text("Press Start once to authorize capture and load shareable windows; then choose a window.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Window", selection: $store.windowID) {
                        Text("Choose a window").tag(UInt32?.none)
                        ForEach(store.windows) { window in Text(window.name).tag(Optional(window.id)) }
                    }.disabled(store.isWorking || store.isRecording)
                }
            } else {
                Picker("Display", selection: $store.displayID) {
                    ForEach(store.displays) { display in Text(display.name).tag(Optional(display.id)) }
                }.disabled(store.isWorking || store.isRecording)
            }
            HStack {
                Picker("Recording length", selection: $store.duration) {
                    ForEach([5, 10, 20, 30, 60], id: \.self) { Text("\($0) seconds").tag(Double($0)) }
                }.frame(maxWidth: 260)
                Toggle("Include cursor", isOn: $store.showsCursor)
            }.disabled(store.isWorking || store.isRecording)
            HStack {
                Button("Start Screenshot") { store.startScreenshot() }
                    .disabled(store.isWorking || store.isRecording)
                Button("Start Recording") { store.startRecording() }
                    .disabled(store.isWorking || store.isRecording)
                if store.isRecording { Button("Stop and Save") { store.stopAndSave() }.buttonStyle(.borderedProminent) }
            }
            if store.isRecording {
                Label("Recording now · no audio", systemImage: "record.circle.fill").foregroundStyle(.red)
            }
            if store.isWorking { ProgressView(value: store.progress) }
            if store.isWorking || store.isRecording { Button("Cancel and Discard") { store.cancel() } }
            Text(store.status).font(.caption).foregroundStyle(.secondary)
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("Screen Recording access is requested only when you start. Hiding this tool stops an active recording. Captures stay on this Mac unless you share them.")
                .font(.caption).foregroundStyle(.secondary)
            if let latest = store.history.first {
                Divider()
                HStack {
                    Label(latest.fileURL.lastPathComponent, systemImage: latest.duration == nil ? "photo" : "film")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show File") { store.reveal(latest) }
                }
                Text("\(latest.width) × \(latest.height)\(latest.duration.map { " · \(String(format: "%.1f", $0)) seconds" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                if latest.duration == nil {
                    Button("Send Screenshot to Selected Workflow") { store.sendScreenshotToWorkflow() }
                        .disabled(store.isWorking || store.isRecording)
                } else {
                    HStack {
                        Button("Compress Recording with Workflow") { store.compressLatestRecording() }
                        Button("Send to Selected Video Workflow") { store.sendRecordingToWorkflow() }
                    }.disabled(store.isWorking || store.isRecording)
                    Text("Compression runs a real video workflow and saves only if the result is smaller; the source recording is kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("\(store.history.count) saved capture\(store.history.count == 1 ? "" : "s")").font(.caption)
                    Spacer()
                    Button("Clear History") { store.clearHistory() }
                }
            }
        }.background(CaptureToolVisibility(onVisible: { store.setVisible(true) },
            onHidden: { store.setVisible(false) }).frame(width: 0, height: 0))
            .onAppear { store.setVisible(true) }.onDisappear { store.setVisible(false) }
    }
}
