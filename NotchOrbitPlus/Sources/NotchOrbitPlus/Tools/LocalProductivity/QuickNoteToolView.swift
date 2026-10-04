import AppKit
import SwiftUI

@MainActor
private final class QuickNoteToolStore: ObservableObject {
    @Published var text = "" {
        didSet {
            if text.utf8.count > byteLimit {
                text = Self.bounded(text, bytes: byteLimit)
                error = "Notes are limited to 200 KB; the pasted text was shortened."
            }
            dirty = true
            scheduleSave()
        }
    }
    @Published var error: String?
    @Published private(set) var savedAt: Date?
    @Published private(set) var pending = false
    @Published private(set) var requiresReplacement = false
    @Published private(set) var backupNotice: String?
    private var dirty = false
    private let byteLimit = 200_000
    private var pendingSave: Task<Void, Never>?
    private var fileURL: URL?
    init() {
        do {
            let url = try LocalToolStorage.directory().appendingPathComponent("quick-note.txt")
            fileURL = url
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
                guard let value = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                text = Self.bounded(value, bytes: byteLimit)
                if data.count > byteLimit {
                    requiresReplacement = true
                    error = "Stored note exceeds 200 KB. It is preserved until you explicitly replace it with a backup."
                }
            }
        } catch {
            requiresReplacement = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            self.error = "Could not load the note. Its original is preserved: \(error.localizedDescription)"
        }
    }
    deinit { pendingSave?.cancel() }
    private static func bounded(_ value: String, bytes: Int) -> String {
        var data = Data(value.utf8.prefix(bytes))
        while !data.isEmpty {
            if let result = String(data: data, encoding: .utf8) { return result }
            data.removeLast()
        }
        return ""
    }
    private func scheduleSave() {
        pendingSave?.cancel()
        pending = true
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.saveNow()
        }
    }
    func saveNow() {
        pendingSave?.cancel(); pendingSave = nil
        guard dirty else { pending = false; return }
        guard !requiresReplacement else {
            pending = false
            error = "The original stored note is preserved. Choose Replace Stored Note to back it up and save these edits."
            return
        }
        guard let fileURL else { error = "The local note location is unavailable."; return }
        do {
            try Data(text.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            savedAt = Date(); pending = false; dirty = false; error = nil
        } catch { self.error = "Could not save the note: \(error.localizedDescription)" }
    }
    func replaceStoredNote() {
        guard requiresReplacement, let fileURL else { return }
        do {
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("quick-note-\(UUID().uuidString).backup.txt")
            try FileManager.default.copyItem(at: fileURL, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            backupNotice = "Original preserved as \(backup.lastPathComponent)."
            requiresReplacement = false
            dirty = true
            saveNow()
        } catch { self.error = "Could not back up the original; it was not replaced: \(error.localizedDescription)" }
    }
    func copy() {
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(text, forType: .string) { error = "macOS could not copy the note." }
    }
}

@MainActor
struct QuickNoteToolView: View {
    @StateObject private var store = QuickNoteToolStore()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Private local note").font(.headline)
                Spacer()
                Button("Copy", action: store.copy).disabled(store.text.isEmpty)
                Button("Clear") { store.text = "" }.disabled(store.text.isEmpty)
            }
            LocalToolError(message: store.error)
            if store.requiresReplacement {
                Button("Replace Stored Note (Keep Backup)", action: store.replaceStoredNote)
                    .help("Preserve a full backup before saving the displayed text")
            }
            if let notice = store.backupNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            TextEditor(text: $store.text).font(.body).accessibilityLabel("Quick note text")
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            HStack {
                if store.pending { Text("Saving…") }
                else if let date = store.savedAt { Text("Saved \(date.formatted(date: .omitted, time: .shortened))") }
                else { Text("Saves automatically on this Mac") }
                Spacer()
                Text("\(store.text.utf8.count.formatted()) / 200,000 bytes")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding().onDisappear { store.saveNow() }
    }
}
