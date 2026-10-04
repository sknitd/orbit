import SwiftUI
import CornerCore

@MainActor
struct CornerWebsitesSettingsView: View {
    @ObservedObject var store: CornerAppStore
    @ObservedObject private var history: ChromeHistoryStore
    @ObservedObject private var recent: RecentlyOpenedStore
    init(store: CornerAppStore) { self.store = store; history = store.history; recent = store.recent }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your websites, within reach").font(.title3.weight(.semibold))
                GroupBox("Chrome history") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(ChromeHistoryStore.privacyExplanation).font(.callout).foregroundStyle(.secondary)
                        Text(history.sourceLabel).font(.headline)
                        HStack {
                            Button("Choose History File…") { history.chooseHistoryFile() }
                            Button("Choose Profile…") { history.chooseProfileFolder() }
                            Button("Refresh") { history.refresh() }.disabled(!history.isConnected || history.isRefreshing)
                            if history.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Reading Chrome history") }
                        }.disabled(store.isPreview)
                        HStack {
                            if let date = history.lastRefreshed { Text("Loaded \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                            Spacer()
                            Button("Disconnect") { history.disconnect() }
                                .disabled(store.isPreview || (!history.isConnected && history.errorMessage == nil))
                        }
                        if let error = history.errorMessage {
                            Text(error).foregroundStyle(.orange).textSelection(.enabled)
                            Button("Open macOS File Access Settings") { history.openPrivacySettings() }.disabled(store.isPreview)
                        }
                        Text("Typical profile: ~/Library/Application Support/Google/Chrome/Default. Choose its History file, or the profile folder. Other profiles have their own history.").font(.caption).foregroundStyle(.secondary)
                        if !history.entries.isEmpty { entryList(history.entries) }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Recently opened websites") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Remember websites opened through CornerOrbit", isOn: Binding(get: { recent.enabled }, set: { recent.setEnabled($0) }))
                            .disabled(store.isPreview).accessibilityIdentifier("CornerOrbit.rememberWebsites")
                        Text("Optional, local history of successful website opens through this app. It does not observe your browsing. Turning this off clears these saved links.")
                            .font(.callout).foregroundStyle(.secondary)
                        if let error = recent.errorMessage { Text(error).foregroundStyle(.orange) }
                        if recent.entries.isEmpty { Text("No saved links yet.").foregroundStyle(.secondary) }
                        else { entryList(recent.entries) }
                        HStack {
                            Text("Up to 200 links; credentials and non-web URLs are excluded.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear Links") { recent.clear() }
                                .disabled(store.isPreview || (recent.entries.isEmpty && recent.errorMessage == nil))
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Assign Chrome History or Recent Websites to any gesture to open a searchable dropdown. Opening the dropdown uses the entries already loaded; refresh is always explicit.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
    private func entryList(_ entries: [CornerHistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entries.prefix(6))) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).lineLimit(1)
                        Text(entry.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Open") { store.openWebsite(entry) }.disabled(store.isPreview || store.isRunningAction)
                        .accessibilityLabel("Open \(entry.title) in Chrome")
                }
            }
            if entries.count > 6 { Text("\(entries.count - 6) more available in the dropdown").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

@MainActor
struct WebsiteDropdownView: View {
    let entries: [CornerHistoryEntry]
    let title: String
    let onOpen: (CornerHistoryEntry) -> Void
    var onSettings: () -> Void = {}
    @State private var query = ""
    @State private var selection: String?
    private var matches: [CornerHistoryEntry] {
        entries.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Search websites", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Search websites")
            if entries.isEmpty {
                ContentUnavailableView("No websites loaded", systemImage: "globe", description: Text("Connect or refresh Chrome history in Websites settings, or enable recent websites and open a link through CornerOrbit."))
            } else if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(matches, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).lineLimit(1)
                        Text(entry.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(entry.id).padding(.vertical, 3).accessibilityLabel("\(entry.title), \(entry.url.host ?? "website")")
                        .contextMenu { Button("Open in Chrome") { onOpen(entry) } }
                }.listStyle(.inset).onTapGesture(count: 2) { openSelected() }
            }
            HStack {
                Button("Websites Settings…", action: onSettings)
                Spacer()
                Button("Open in Chrome") { openSelected() }.keyboardShortcut(.defaultAction)
                    .disabled(!matches.contains(where: { $0.id == selection }))
            }
        }.padding(16).frame(width: 440, height: 420)
            .onChange(of: query) { _, _ in selection = matches.first?.id }
            .onAppear { selection = matches.first?.id }
    }
    private func openSelected() { if let entry = matches.first(where: { $0.id == selection }) { onOpen(entry) } }
}
