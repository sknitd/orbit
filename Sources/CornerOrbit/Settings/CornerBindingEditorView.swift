import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CornerCore

@MainActor
struct CornerBindingEditorView: View {
    @ObservedObject private var store: CornerAppStore
    @ObservedObject private var links: CornerLinkStore
    let corner: Corner
    let gesture: CornerGesture
    @Environment(\.dismiss) private var dismiss
    @State private var kind: CornerActionKind
    @State private var search: String
    @State private var urlText: String
    @State private var bundleID: String
    @State private var argument: String
    @State private var error: String?
    @State private var shortcutNames: [String] = []
    @State private var shortcutRefresh: Task<Void, Never>?
    @State private var shortcutRefreshID: UUID?
    @State private var refreshingShortcuts = false
    @State private var shortcutStatus: String?

    init(store: CornerAppStore, corner: Corner, gesture: CornerGesture, initialSearch: String = "") {
        self.store = store; self.links = store.links; self.corner = corner; self.gesture = gesture
        let action = store.action(corner: corner, gesture: gesture)
        _kind = State(initialValue: action.kind)
        _search = State(initialValue: initialSearch)
        _urlText = State(initialValue: action.url ?? "")
        _bundleID = State(initialValue: action.bundleID ?? "")
        _argument = State(initialValue: action.argument ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(corner.title) · \(gesture.title)").font(.title2.weight(.semibold))
            searchField
            actionList
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Label(kind.title, systemImage: kind.systemImage).font(.headline)
                    Text(kind.purpose).font(.caption).foregroundStyle(.secondary)
                    parameterEditor
                    applicationAvailability
                    permissionNotes
                    if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(22).frame(width: 550, height: 660)
        .onChange(of: kind) { old, new in
            error = nil
            if old.parameterKind != new.parameterKind { argument = "" }
            if new != .runShortcut { cancelShortcutRefresh() }
        }
        .onChange(of: urlText) { _, _ in error = nil }
        .onChange(of: bundleID) { _, _ in error = nil }
        .onChange(of: argument) { _, _ in error = nil }
        .onDisappear { cancelShortcutRefresh() }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search actions, categories, or purpose", text: $search)
                .textFieldStyle(.plain).accessibilityLabel("Search actions")
                .accessibilityIdentifier("CornerOrbit.editor.search")
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Clear action search")
            }
        }.padding(9).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var filteredActions: [CornerActionKind] {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return CornerActionCatalog.all.filter { action in
            let text = ([action.title, action.category, action.purpose] + action.searchTerms).joined(separator: " ")
            return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
    private var categories: [String] { Array(Set(filteredActions.map(\.category))).sorted() }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(filteredActions.count) of \(CornerActionCatalog.all.count) actions")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if filteredActions.isEmpty {
                        Text("No matching actions. Try an app name, clipboard, or window.")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(categories, id: \.self) { category in
                        Text(category).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 6).padding(.horizontal, 8)
                        ForEach(filteredActions.filter { $0.category == category }, id: \.self) { action in
                            actionRow(action)
                        }
                    }
                }.padding(6)
            }
            .frame(height: 210)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("CornerOrbit.editor.action")
        }
    }
    private func actionRow(_ action: CornerActionKind) -> some View {
        Button { kind = action } label: {
            HStack(spacing: 9) {
                Image(systemName: action.systemImage).frame(width: 20)
                Text(action.title).font(.callout).multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                if kind == action { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(kind == action ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(action.title)
        .accessibilityValue(kind == action ? "Selected" : "Not selected")
        .accessibilityIdentifier("CornerOrbit.editor.select.\(action.rawValue)")
        .help(action.purpose)
    }

    @ViewBuilder private var parameterEditor: some View {
        switch kind.parameterKind {
        case .none: EmptyView()
        case .website:
            TextField("https://example.com", text: $urlText).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Website URL").accessibilityIdentifier("CornerOrbit.editor.url")
            caption("Use a complete HTTP or HTTPS URL without account credentials. The website opens in Google Chrome when run.")
        case .application:
            HStack {
                TextField("com.apple.TextEdit", text: $bundleID).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Application bundle identifier").accessibilityIdentifier("CornerOrbit.editor.bundleID")
                Button("Choose App…") { chooseApplication() }.disabled(store.isPreview)
                    .accessibilityIdentifier("CornerOrbit.editor.chooseApp")
            }
            caption("Choose an installed app or enter its bundle identifier. Choosing an app only updates this binding.")
        case .file:
            HStack {
                TextField("/Users/you/Documents/file.txt", text: $argument).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Local file or folder path").accessibilityIdentifier("CornerOrbit.editor.file")
                Button("Choose…") { chooseFile() }.disabled(store.isPreview)
                    .accessibilityIdentifier("CornerOrbit.editor.chooseFile")
            }
            caption("Choose an absolute local file or folder. It opens with its default app only when run; this editor does not read its contents.")
        case .shortcut: shortcutEditor
        case .urlGroup: groupEditor
        }
    }
    private var shortcutEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Exact Shortcut name", text: $argument).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Shortcut name").accessibilityIdentifier("CornerOrbit.editor.shortcut")
                if refreshingShortcuts {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { cancelShortcutRefresh() }
                } else {
                    Button("Refresh List") { refreshShortcuts() }.disabled(store.isPreview)
                        .accessibilityIdentifier("CornerOrbit.editor.refreshShortcuts")
                }
            }
            if !shortcutNames.isEmpty {
                Picker("Choose from refreshed list", selection: $argument) {
                    Text("Enter a name above").tag("")
                    if !argument.isEmpty && !shortcutNames.contains(argument) { Text(argument).tag(argument) }
                    ForEach(shortcutNames, id: \.self) { name in Text(name).tag(name) }
                }.pickerStyle(.menu).accessibilityIdentifier("CornerOrbit.editor.shortcutList")
            }
            caption("Refresh explicitly lists up to 256 local Shortcuts; it does not run one. Saving only stores the exact name. A Shortcut’s configured actions run when you explicitly run this binding.")
            if let shortcutStatus { caption(shortcutStatus) }
        }
    }
    private var groupEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Saved website group", selection: $argument) {
                Text("Choose a group").tag("")
                if !argument.isEmpty && !links.groups.contains(where: { $0.id.uuidString == argument }) {
                    Text("Unavailable saved group").tag(argument)
                }
                ForEach(links.groups) { group in Text("\(group.name) · \(group.urls.count) websites").tag(group.id.uuidString) }
            }.pickerStyle(.menu).disabled(links.groups.isEmpty || links.needsRecovery)
                .accessibilityIdentifier("CornerOrbit.editor.urlGroup")
            if links.needsRecovery {
                caption("The local group library needs recovery. Open Favorites & Groups to preserve and reload or reset it before choosing a group.")
            } else if links.groups.isEmpty {
                caption("No saved groups yet. Create a group in Favorites & Groups, then return to bind it. Saving or choosing a group opens no websites.")
            } else {
                caption("The selected group’s websites open in Chrome only when run. Changes to the saved group apply to this binding.")
            }
        }
    }

    @ViewBuilder private var applicationAvailability: some View {
        if let targetID {
            let application = CornerNativeWorkspace().applicationURL(bundleID: targetID)
            Label(application.map { "Installed: \($0.deletingPathExtension().lastPathComponent)" } ?? "Application not found: \(targetID)",
                  systemImage: application == nil ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.caption).foregroundStyle(application == nil ? Color.orange : Color.secondary)
            if application == nil { caption("Install the required app, or choose Custom Application. Running this action reports an error if the app is unavailable.") }
        }
    }
    @ViewBuilder private var permissionNotes: some View {
        if CornerActionScripts.request(for: kind) != nil {
            caption(store.preferences.automationEnabled
                    ? "Automation is enabled. macOS asks for access only when you explicitly run the action. Tab and document commands use the chosen app; new documents are blank and unsaved."
                    : "Enable Allow document and tab Automation in Behavior for this action. Saving this binding does not request access.")
        } else if kind.isWindowAction && kind != .hideOtherApps && kind != .restoreHiddenApps {
            caption("This action needs Accessibility access to the front app’s supported window. macOS access is requested only when explicitly run; changing the binding does not request access.")
        } else if kind == .chromeHistory {
            caption("Connect Chrome history explicitly in Websites before using this local picker.")
        } else if kind == .recentWebsites {
            caption("Shows websites you opened through CornerOrbit; it does not read another app’s browsing history.")
        }
    }
    private func caption(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private var targetID: String? {
        if kind == .openApplication {
            return (try? CornerAction(kind: .openApplication, bundleID: bundleID).validated())?.bundleID
        }
        if kind == .chromeHistory { return nil }
        if kind == .openURLGroup { return "com.google.Chrome" }
        return kind.defaultBundleID
    }
    private var footer: some View {
        VStack(spacing: 12) {
            Divider()
            HStack {
                Text("Saving changes the binding only.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { cancelShortcutRefresh(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(store.settingsNeedRecovery)
                    .accessibilityIdentifier("CornerOrbit.editor.save")
            }
        }
    }

    private func chooseApplication() {
        guard !store.isPreview else { return }
        let panel = NSOpenPanel(); panel.title = "Choose an application for this binding"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false; panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true); panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let identifier = Bundle(url: url)?.bundleIdentifier else { throw CornerActionError.invalid("This application has no bundle identifier. Choose another app.") }
            bundleID = try CornerAction(kind: .openApplication, bundleID: identifier).validated().bundleID ?? ""; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func chooseFile() {
        guard !store.isPreview else { return }
        let panel = NSOpenPanel(); panel.title = "Choose a local file or folder for this binding"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false; panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { argument = try CornerActionArgumentValidation.localPath(url.path); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func refreshShortcuts() {
        guard !store.isPreview, !refreshingShortcuts else { return }
        let id = UUID(); shortcutRefreshID = id; refreshingShortcuts = true; shortcutStatus = nil
        shortcutRefresh = Task { @MainActor in
            do {
                let names = try await CornerShortcutsRunner().list()
                try Task.checkCancellation()
                guard shortcutRefreshID == id, kind == .runShortcut else { return }
                shortcutNames = Array(Set(names)).sorted(); shortcutStatus = names.isEmpty ? "No local Shortcuts found." : "Refreshed the local list. Enter a name directly if it is outside the first 256."
            } catch is CancellationError {
                if shortcutRefreshID == id { shortcutStatus = "Refresh cancelled." }
            } catch {
                if shortcutRefreshID == id { shortcutStatus = "Could not list Shortcuts: \(error.localizedDescription)" }
            }
            guard shortcutRefreshID == id else { return }
            refreshingShortcuts = false; shortcutRefresh = nil; shortcutRefreshID = nil
        }
    }
    private func cancelShortcutRefresh() {
        let wasRefreshing = refreshingShortcuts
        shortcutRefreshID = nil; shortcutRefresh?.cancel(); shortcutRefresh = nil; refreshingShortcuts = false
        if wasRefreshing { shortcutStatus = "Refresh cancelled." }
    }
    private func save() {
        let action: CornerAction
        switch kind.parameterKind {
        case .website: action = .init(kind: kind, url: urlText)
        case .application: action = .init(kind: kind, bundleID: bundleID)
        case .file, .shortcut, .urlGroup: action = .init(kind: kind, argument: argument)
        case .none: action = .init(kind: kind)
        }
        do {
            if kind.parameterKind == .urlGroup {
                guard !links.needsRecovery, let id = UUID(uuidString: argument), links.groups.contains(where: { $0.id == id }) else {
                    throw CornerActionError.invalid("Choose an available saved website group in Favorites & Groups.")
                }
            }
            try store.assign(action, to: corner, gesture: gesture)
            cancelShortcutRefresh(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
