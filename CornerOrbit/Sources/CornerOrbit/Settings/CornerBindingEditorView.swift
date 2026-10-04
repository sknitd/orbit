import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CornerCore

@MainActor
struct CornerBindingEditorView: View {
    @ObservedObject private var store: CornerAppStore
    let corner: Corner
    let gesture: CornerGesture
    @Environment(\.dismiss) private var dismiss
    @State private var kind: CornerActionKind
    @State private var urlText: String
    @State private var bundleID: String
    @State private var error: String?
    init(store: CornerAppStore, corner: Corner, gesture: CornerGesture) {
        self.store = store; self.corner = corner; self.gesture = gesture
        let action = store.action(corner: corner, gesture: gesture)
        _kind = State(initialValue: action.kind)
        _urlText = State(initialValue: action.url ?? "")
        _bundleID = State(initialValue: action.bundleID ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(corner.title) · \(gesture.title)").font(.title2.weight(.semibold))
            Picker("Action", selection: $kind) {
                ForEach(CornerActionCatalog.all, id: \.self) { action in
                    Label(action.title, systemImage: action.systemImage).tag(action)
                }
            }.pickerStyle(.menu).accessibilityIdentifier("CornerOrbit.editor.action")
            if kind == .openURL {
                TextField("https://example.com", text: $urlText).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Website URL").accessibilityIdentifier("CornerOrbit.editor.url")
                Text("Use a complete HTTP or HTTPS URL without account credentials. The website opens in Google Chrome.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if kind == .openApplication {
                HStack {
                    TextField("com.apple.TextEdit", text: $bundleID).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Application bundle identifier").accessibilityIdentifier("CornerOrbit.editor.bundleID")
                    Button("Choose App…") { chooseApplication() }.disabled(store.isPreview)
                        .accessibilityIdentifier("CornerOrbit.editor.chooseApp")
                }
                Text("Choose an installed app or enter its bundle identifier. Choosing an app only updates this binding.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let targetID {
                let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: targetID)
                Label(application.map { "Installed: \($0.deletingPathExtension().lastPathComponent)" } ?? "Application not found: \(targetID)",
                      systemImage: application == nil ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption).foregroundStyle(application == nil ? Color.orange : Color.secondary)
                if application == nil {
                    Text("Install the required app, or choose Custom Application. Running this action reports an error if the app is unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if CornerActionScripts.request(for: kind) != nil {
                Text(store.preferences.automationEnabled
                     ? "Automation is enabled. macOS asks for access only when you explicitly run the action. New documents are blank and unsaved."
                     : "Enable Automation in Behavior to create browser tabs or blank documents. Saving this binding does not request access.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if kind == .chromeHistory {
                Text("Shows the local Chrome history picker. Connect Chrome history explicitly in Websites before using it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if kind == .recentWebsites {
                Text("Shows websites you opened through CornerOrbit. It does not read another app’s browsing history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            HStack {
                Text("Saving changes the binding only.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(store.settingsNeedRecovery)
                    .accessibilityIdentifier("CornerOrbit.editor.save")
            }
        }.padding(24).frame(width: 500)
            .onChange(of: kind) { _, _ in error = nil }
            .onChange(of: urlText) { _, _ in error = nil }
            .onChange(of: bundleID) { _, _ in error = nil }
    }
    private var targetID: String? {
        if kind == .openApplication {
            return (try? CornerAction(kind: .openApplication, bundleID: bundleID).validated())?.bundleID
        }
        if kind == .chromeHistory { return nil }
        return kind.defaultBundleID
    }
    private func chooseApplication() {
        let panel = NSOpenPanel(); panel.title = "Choose an application for this binding"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false; panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true); panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let identifier = Bundle(url: url)?.bundleIdentifier else {
                throw CornerActionError.invalid("This application has no bundle identifier. Choose another app.")
            }
            let action = try CornerAction(kind: .openApplication, bundleID: identifier).validated()
            bundleID = action.bundleID ?? ""; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        let action: CornerAction
        switch kind {
        case .openURL: action = .init(kind: kind, url: urlText)
        case .openApplication: action = .init(kind: kind, bundleID: bundleID)
        default: action = .init(kind: kind)
        }
        do { try store.assign(action, to: corner, gesture: gesture); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
