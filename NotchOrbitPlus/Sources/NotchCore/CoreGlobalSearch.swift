import Foundation

public struct CoreSearchEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let content: String
    public let toolID: String
    public let fileURL: URL?
    public init(id: String, title: String, detail: String = "", content: String = "", toolID: String, fileURL: URL? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.content = content; self.toolID = toolID; self.fileURL = fileURL
    }
}

public enum CoreGlobalSearch {
    public static func results(query: String, entries: [CoreSearchEntry], limit: Int = 50) -> [CoreSearchEntry] {
        let tokens = folded(String(query.prefix(512))).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        var seen = Set<String>()
        return entries.prefix(5_000).enumerated().compactMap { index, entry -> (CoreSearchEntry, Int, Int)? in
            guard !entry.id.isEmpty, !entry.title.isEmpty, seen.insert(entry.id).inserted else { return nil }
            let title = folded(String(entry.title.prefix(4_096)))
            let words = title + " " + folded(String((entry.detail + " " + entry.content).prefix(100_000)))
            guard tokens.allSatisfy({ words.contains($0) }) else { return nil }
            let score = tokens.reduce(0) { score, token in score + (title == token ? 0 : title.hasPrefix(token) ? 1 : title.contains(token) ? 2 : 3) }
            return (entry, score, index)
        }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }
            .prefix(max(0, min(limit, 100))).map(\.0)
    }
    public static func selection(in entries: [CoreSearchEntry], current: String?, offset: Int) -> String? {
        guard !entries.isEmpty else { return nil }
        guard let index = entries.firstIndex(where: { $0.id == current }) else { return offset < 0 ? entries.last?.id : entries.first?.id }
        return entries[max(0, min(entries.count - 1, index + (offset < 0 ? -1 : 1)))].id
    }
    private static func folded(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
