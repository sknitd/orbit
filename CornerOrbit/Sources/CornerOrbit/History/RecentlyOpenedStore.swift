import Foundation
import Combine
import CornerCore

@MainActor
final class RecentlyOpenedStore: ObservableObject {
    static let shared = RecentlyOpenedStore()
    @Published private(set) var entries: [CornerHistoryEntry] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var enabled = false
    private let defaults: UserDefaults
    private let ephemeral: Bool
    private var unreadableOriginal = false
    private static let enabledKey = "cornerorbit.recentHistory.enabled"
    private static let entriesKey = "cornerorbit.recentHistory.entries"
    private static let maximumBytes = 2 * 1024 * 1024
    private struct Archive: Codable { let schemaVersion: Int; let entries: [CornerHistoryEntry] }
    init(defaults: UserDefaults = .standard, previewEntries: [CornerHistoryEntry]? = nil) {
        self.defaults = defaults; ephemeral = previewEntries != nil
        if let previewEntries { enabled = true; entries = CornerHistorySanitizer.sanitize(previewEntries, limit: 200); return }
        enabled = defaults.bool(forKey: Self.enabledKey)
        if enabled { loadSavedEntries() }
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if !ephemeral { defaults.set(value, forKey: Self.enabledKey) }
        if value { if !ephemeral { loadSavedEntries() } }
        else { clear() }
    }
    /// Root calls this only after an explicit CornerOrbit URL open succeeds.
    func record(_ url: URL, title: String = "") {
        guard enabled else { return }
        guard !unreadableOriginal else { errorMessage = "Saved recent links are unreadable and were retained. Clear them explicitly before recording new links."; return }
        let old = entries.first(where: { $0.url == url })
        let count = old.map { $0.visitCount == Int.max ? Int.max : $0.visitCount + 1 } ?? 1
        let entry = CornerHistoryEntry(url: url, title: title.isEmpty ? (old?.title ?? url.host ?? "Website") : title,
                                       lastVisited: Date(), visitCount: count, source: .recent)
        guard (try? entry.validated()) != nil else { errorMessage = "Only credential-free HTTP or HTTPS links can be recorded."; return }
        let next = CornerHistorySanitizer.sanitize([entry] + entries, limit: 200)
        do {
            let bytes = try JSONEncoder().encode(Archive(schemaVersion: 1, entries: next))
            guard bytes.count <= Self.maximumBytes else { throw ChromeHistoryError.oversizedFile }
            if !ephemeral { defaults.set(bytes, forKey: Self.entriesKey) }
            entries = next; errorMessage = nil
        } catch { errorMessage = "The bounded recent-link list could not be saved; its prior entries were retained." }
    }
    func clear() {
        entries = []; errorMessage = nil; unreadableOriginal = false
        if !ephemeral { defaults.removeObject(forKey: Self.entriesKey) }
    }
    private func loadSavedEntries() {
        guard let original = defaults.object(forKey: Self.entriesKey) else { entries = []; return }
        do {
            guard let bytes = original as? Data, bytes.count <= Self.maximumBytes else { throw ChromeHistoryError.invalidDatabase }
            let archive = try JSONDecoder().decode(Archive.self, from: bytes)
            guard archive.schemaVersion == 1, archive.entries.count <= 200,
                  archive.entries.allSatisfy({ $0.source == .recent && (try? $0.validated()) != nil }) else { throw ChromeHistoryError.invalidDatabase }
            entries = CornerHistorySanitizer.sanitize(archive.entries, limit: 200)
            unreadableOriginal = false; errorMessage = nil
        } catch {
            unreadableOriginal = true; entries = []
            errorMessage = "Saved recent links are unreadable. Their original bytes were retained; Clear explicitly resets them."
        }
    }
}
