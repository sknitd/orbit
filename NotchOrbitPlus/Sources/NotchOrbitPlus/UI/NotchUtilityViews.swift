import SwiftUI
import AppKit
import ServiceManagement

@MainActor
private struct NotchAppIcon: View {
    let size: CGFloat
    var body: some View {
        if let icon = NSImage(named: NSImage.Name("AppIcon")) {
            Image(nsImage: icon).resizable().scaledToFit().frame(width: size, height: size)
                .accessibilityLabel("NotchOrbitPlus")
        } else {
            Image(systemName: "rectangle.topthird.inset.filled")
                .font(.system(size: size * 0.7)).foregroundStyle(.blue)
                .frame(width: size, height: size).accessibilityLabel("NotchOrbitPlus")
        }
    }
}

@MainActor
struct NotchWelcomeView: View {
    let model: AppModel
    let requestAccess: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                NotchAppIcon(size: 82)
                Text("NotchOrbitPlus").font(.title.weight(.semibold))
                Text("Drag to the notch. Drop an action.").font(.title3)
                Text("Drag a file from Finder toward your display's notch to reveal compatible actions. Drop the file onto a labeled action to run it. On displays without a notch, use the top center.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("Your originals stay untouched. All processing stays on this Mac.")
                    .font(.callout).multilineTextAlignment(.center)
                Divider()
                Text("Input Monitoring lets NotchOrbitPlus detect a file drag near the top of your display. It does not record typing or upload files.")
                    .font(.callout).multilineTextAlignment(.center)
                Button("Enable Input Monitoring", action: requestAccess).buttonStyle(.borderedProminent)
                Text(model.monitoringStatus).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("You can also use Choose Files from the menu bar. NotchOrbitPlus reveals those files in Finder; drag the same files onto an action to continue.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(28).frame(maxWidth: .infinity)
        }.frame(width: 480, height: 510)
    }
}

@MainActor
struct NotchResultView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
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
                            .onDrag { NSItemProvider(contentsOf: first) ?? NSItemProvider(object: first as NSURL) }
                            .help("Drag the result into another application")
                    }
                    HStack {
                        Button("Reveal") { model.reveal(entry.result.outputs) }
                        Button("Copy") { model.copy(entry.result.outputs) }
                        Button("Undo", action: model.undoLast).disabled(!model.canUndo).help(model.undoHelp)
                    }
                } else if !model.busy && model.errorMessage == nil {
                    ContentUnavailableView("Ready for a file", systemImage: "rectangle.topthird.inset.filled",
                        description: Text("Drag a file toward the notch or the top center of a display."))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(18).frame(width: 370, height: 320)
    }
}

@MainActor
struct NotchSettingsView: View {
    let model: AppModel
    let requestAccess: () -> Void
    let applyPreferences: () -> Void
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var preferences = model.preferences
        TabView {
            Form {
                Toggle("Launch at login", isOn: $loginEnabled).onChange(of: loginEnabled) { _, enabled in
                    guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        if SMAppService.mainApp.status == .requiresApproval {
                            loginError = "Allow NotchOrbitPlus in System Settings → General → Login Items."
                        } else { loginError = nil }
                        loginEnabled = SMAppService.mainApp.status == .enabled
                    } catch {
                        loginError = error.localizedDescription
                        loginEnabled = SMAppService.mainApp.status == .enabled
                    }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Play a sound after completion", isOn: $preferences.sound)
                Text("NotchOrbitPlus runs in the menu bar. All processing stays on this Mac.")
                    .foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Text("Bring a file drag toward the notch to reveal actions. On displays without a notch, use the top center. Drop onto a labeled action to run it.")
                Toggle("Pause NotchOrbitPlus", isOn: $preferences.paused)
                    .onChange(of: preferences.paused) { _, _ in applyPreferences() }
                Text(model.monitoringStatus).foregroundStyle(.secondary)
                Button("Enable Input Monitoring", action: requestAccess)
                Button("Open Input Monitoring Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text("Choose Files from the menu bar provides a manual drop destination. You still drag the selected files onto an action before anything is processed.")
                    .font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("Interaction", systemImage: "rectangle.topthird.inset.filled") }

            Form {
                Toggle("Save outputs in Downloads", isOn: $preferences.outputDownloads)
                Text("Otherwise, outputs are saved beside each original. Existing files are never replaced.")
                    .foregroundStyle(.secondary)
                LabeledContent("Image quality") {
                    Slider(value: $preferences.quality, in: 0.4...1).frame(width: 180)
                    Text(preferences.quality, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
                Text("Resize uses a maximum edge of 1600 px. Conversion keeps the original file.").font(.caption)
            }.formStyle(.grouped).tabItem { Label("Output", systemImage: "folder") }

            Form {
                Toggle("Show recent results for 24 hours", isOn: $preferences.retainHistory)
                    .onChange(of: preferences.retainHistory) { _, enabled in
                        if !enabled { model.recent = Array(model.recent.prefix(1)) }
                    }
                Text("Off keeps only the latest result for Undo. History keeps output locations and operation summaries in memory. Quitting clears it.")
                Text("Undo checks file identity, size, and modification date. It cannot detect edits that preserve those values. Extracted folders must be managed in Finder.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear Recent Results", action: model.clearRecent)
            }.formStyle(.grouped).tabItem { Label("Privacy", systemImage: "hand.raised") }

            VStack(spacing: 14) {
                NotchAppIcon(size: 78)
                Text("NotchOrbitPlus").font(.title)
                Text("File actions, right below your display's top edge.")
                Text("macOS 14+ · Native Swift 6 / AppKit / SwiftUI").font(.caption).foregroundStyle(.secondary)
            }.tabItem { Label("About", systemImage: "info.circle") }
        }.padding(12).frame(width: 600, height: 460)
            .onAppear {
                loginEnabled = SMAppService.mainApp.status == .enabled
                loginError = SMAppService.mainApp.status == .requiresApproval
                    ? "Allow NotchOrbitPlus in System Settings → General → Login Items." : nil
            }
    }
}
