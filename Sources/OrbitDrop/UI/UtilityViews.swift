import SwiftUI
import AppKit
import ServiceManagement

struct WelcomeView: View {
    let model: AppModel
    let requestAccess: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            if let icon = NSImage(named: NSImage.Name("AppIcon")) {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 82, height: 82)
            } else { Image(systemName: "circle.dotted.circle").font(.system(size: 52)).foregroundStyle(.blue) }
            Text("The file becomes the interface.").font(.title2.weight(.semibold))
            Text("Drag. Hold Shift. Drop.").font(.title3)
            Text("Drag a file from Finder, hold Shift, and drop it onto an action. Hold Shift + Option to bring privacy tools forward. Your originals stay untouched.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Divider()
            Text("OrbitDrop needs Input Monitoring to detect mouse drags, modifiers, and Escape. It does not record typing or upload files.")
                .font(.callout).multilineTextAlignment(.center)
            Button("Enable Input Monitoring", action: requestAccess)
            Text(model.monitoringStatus).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(28).frame(width: 470)
    }
}

struct ResultView: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.busy {
                Label(model.progressLabel, systemImage: "arrow.triangle.2.circlepath")
                ProgressView(value: model.progress)
                Button("Cancel", action: model.cancel)
            }
            if let error = model.errorMessage {
                Label("Couldn’t finish", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Text(error).font(.callout).textSelection(.enabled)
                Button("Dismiss") { model.errorMessage = nil }
            }
            if let entry = model.recent.first {
                Label(entry.title, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(entry.result.outputs.count) output file\(entry.result.outputs.count == 1 ? "" : "s")")
                Text("\(ByteCountFormatter.string(fromByteCount: entry.result.inputBytes, countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: entry.result.outputBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                if let first = entry.result.outputs.first {
                    Label(first.lastPathComponent, systemImage: "doc").lineLimit(1)
                        .onDrag { NSItemProvider(contentsOf: first) ?? NSItemProvider(object: first.path as NSString) }
                        .help("Drag the result into another application")
                }
                HStack {
                    Button("Reveal") { model.reveal(entry.result.outputs) }
                    Button("Copy") { model.copy(entry.result.outputs) }
                    Button("Undo", action: model.undoLast).disabled(model.busy)
                }
            } else if !model.busy && model.errorMessage == nil {
                ContentUnavailableView("Ready for a drop", systemImage: "circle.dotted.circle", description: Text("Drag a file and hold Shift."))
            }
            Spacer(minLength: 0)
        }.padding(18).frame(width: 350, height: 290)
    }
}

struct SettingsView: View {
    let model: AppModel
    let requestAccess: () -> Void
    var applyPreferences: () -> Void = {}
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    var body: some View {
        @Bindable var preferences = model.preferences
        TabView {
            Form {
                Toggle("Launch at login", isOn: $loginEnabled).onChange(of: loginEnabled) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch { loginError = error.localizedDescription; loginEnabled = SMAppService.mainApp.status == .enabled }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Play a sound after completion", isOn: $preferences.sound)
                Text("OrbitDrop runs in the menu bar. All processing stays on this Mac.").foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Toggle("Require Shift + Option", isOn: $preferences.triggerOption).onChange(of: preferences.triggerOption) { _, _ in applyPreferences() }
                Text("Default: Shift. Advanced: Shift + Option. Drop on a labeled action to run it; the center and Escape cancel.")
                Text(model.monitoringStatus).foregroundStyle(.secondary)
                Button("Enable Input Monitoring", action: requestAccess)
                Button("Open Input Monitoring Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
                }
            }.formStyle(.grouped).tabItem { Label("Interaction", systemImage: "cursorarrow.rays") }
            Form {
                Toggle("Save outputs in Downloads", isOn: $preferences.outputDownloads)
                Text("Otherwise, outputs are saved beside each original. Existing files are never replaced.").foregroundStyle(.secondary)
                LabeledContent("Image quality") {
                    Slider(value: $preferences.quality, in: 0.4...1).frame(width: 180)
                    Text(preferences.quality, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
                Text("Resize uses a maximum edge of 1600 px. Conversion does not modify originals.").font(.caption)
            }.formStyle(.grouped).tabItem { Label("Output", systemImage: "folder") }
            Form {
                Toggle("Keep recent results in memory for 24 hours", isOn: $preferences.retainHistory)
                Text("Off keeps only the latest result for Undo. Quitting clears all history. No thumbnails or document contents are saved by OrbitDrop.")
                Text("Cloud AI, telemetry, and watched folders are not enabled in this build.").foregroundStyle(.secondary)
                Button("Clear Recent Results") { model.recent = [] }
            }.formStyle(.grouped).tabItem { Label("Privacy", systemImage: "hand.raised") }
            VStack(spacing: 14) {
                Image(systemName: "circle.dotted.circle").font(.system(size: 48)).foregroundStyle(.blue)
                Text("OrbitDrop").font(.title)
                Text("A quiet, local extension of your file workflow.")
                Text("macOS 14+ · Native Swift 6 / AppKit / SwiftUI").font(.caption).foregroundStyle(.secondary)
            }.tabItem { Label("About", systemImage: "info.circle") }
        }.padding(12).frame(width: 570, height: 390)
    }
}
