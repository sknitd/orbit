import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NotchCore

@MainActor
struct AIUsageToolView: View {
    @State private var exports: [OnlineAIUsageExport] = []
    @State private var error: String?
    private var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.sknitd.NotchOrbitPlus", isDirectory: true).appendingPathComponent("AIUsageImports.json")
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI Usage").font(.title2.bold())
                Text("Import a local usage export for Claude, Codex, Cursor, Copilot or Grok. These services do not offer one universal documented subscription-quota API. This tool reads only the file you select; it does not inspect sign-in tokens or authentication caches.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Button("Import usage JSON…", action: importUsage); Button("Save format example…", action: saveExample) }
                Text("Imports are snapshots, not an automatic signed-in account connection. Exported time and known limits stay visible.").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange).font(.callout) }
                if exports.isEmpty { ContentUnavailableView("No imported usage", systemImage: "chart.bar", description: Text("Select an export you created or obtained from your provider.")) }
                ForEach(exports, id: \.provider) { item in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(item.provider).font(.headline); Spacer(); Button("Remove") { remove(item.provider) } }
                            Text("Imported snapshot · exported \(item.exportedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                            if item.isStale(at: Date()) { Text("Stale snapshot: more than six hours old. Import a new export for current usage.").font(.caption).foregroundStyle(.orange) }
                            ForEach(item.snapshots) { snapshot in
                                Text(snapshot.scope.capitalized).font(.subheadline.bold())
                                Text("Used: \(onlineAmount(snapshot.used)) \(snapshot.unit)")
                                if let limit = snapshot.limit, let remaining = snapshot.remaining {
                                    Text("Limit: \(onlineAmount(limit)) · remaining at export: \(onlineAmount(remaining)) \(snapshot.unit)")
                                    if let fraction = snapshot.fraction { ProgressView(value: min(1, max(0, fraction))) }
                                } else { Text("Provider limit absent; remaining quota is unavailable.").foregroundStyle(.secondary) }
                                if let reset = snapshot.resetsAt { Text("Reset: \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                DisclosureGroup("Supported normalized JSON format") {
                    Text("provider: Claude / Codex / Cursor / Copilot / Grok\nexported_at: ISO 8601 timestamp with time zone\nsnapshots: one or two objects\n  scope: session or weekly\n  used: nonnegative number\n  limit: positive number (optional)\n  unit: tokens / requests / percent / USD\n  resets_at: ISO 8601 timestamp (optional)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Percent exports must supply their actual limit (normally 100) to show remaining percentage. No missing limit is inferred.").font(.caption)
                }
            }.padding(16)
        }.frame(minWidth: 480, minHeight: 400).onAppear(perform: load)
    }
    private func importUsage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.message = "Choose a local normalized AI usage export. No authentication files are scanned."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2 * 1024 * 1024 else {
                throw OnlineServiceError.message("Select a regular JSON export under 2 MB.")
            }
            let imported = try OnlineAIUsageExport.decode(Data(contentsOf: url))
            exports.removeAll { $0.provider == imported.provider }; exports.append(imported)
            exports.sort { $0.provider < $1.provider }; try persist(); error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            guard data.count <= 2 * 1024 * 1024 else { throw OnlineServiceError.message("Saved usage imports exceed their size limit.") }
            exports = try JSONDecoder().decode([OnlineAIUsageExport].self, from: data)
        } catch { self.error = "Saved imports could not be read. Import a fresh export." }
    }
    private func persist() throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(exports).write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }
    private func remove(_ provider: String) { exports.removeAll { $0.provider == provider }; do { try persist() } catch { self.error = error.localizedDescription } }
    private func saveExample() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "usage-format-example.json"
        panel.message = "This is a format example with zero usage, not provider data. Replace it with your real export."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let example: [String: Any] = ["provider": "Codex", "exported_at": timestamp,
            "snapshots": [["scope": "session", "used": 0, "unit": "tokens"]]]
        do { try JSONSerialization.data(withJSONObject: example, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
}
