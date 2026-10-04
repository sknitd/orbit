import AppKit
import SwiftUI

struct EmojiCatalogEntry: Decodable, Identifiable, Sendable {
    let emoji: String
    let name: String
    let group: String
    var id: String { emoji }
}

@MainActor
enum EmojiCatalog {
    static func load(from bundle: Bundle = .main) throws -> [EmojiCatalogEntry] {
        guard let url = bundle.url(forResource: "EmojiCatalog", withExtension: "json") else {
            throw NSError(domain: "NotchOrbitPlus.Emoji", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The bundled Unicode emoji catalog is missing. Use the macOS character palette."])
        }
        let entries = try JSONDecoder().decode([EmojiCatalogEntry].self, from: Data(contentsOf: url))
        guard !entries.isEmpty, Set(entries.map(\.emoji)).count == entries.count,
              entries.allSatisfy({ !$0.emoji.isEmpty && !$0.name.isEmpty && !$0.group.isEmpty }) else {
            throw NSError(domain: "NotchOrbitPlus.Emoji", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The bundled Unicode emoji catalog is invalid."])
        }
        return entries
    }
    static func search(_ entries: [EmojiCatalogEntry], query: String, group: String? = nil) -> [EmojiCatalogEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in
            (group == nil || entry.group == group) && terms.allSatisfy {
                entry.name.localizedCaseInsensitiveContains($0) || entry.emoji.contains($0) ||
                    entry.group.localizedCaseInsensitiveContains($0)
            }
        }
    }
}

@MainActor
private final class EmojiToolStore: ObservableObject {
    @Published var entries: [EmojiCatalogEntry] = []
    @Published var error: String?
    @Published var status = ""
    init() {
        do { entries = try EmojiCatalog.load() }
        catch { self.error = error.localizedDescription }
    }
    var groups: [String] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }
    func copy(_ entry: EmojiCatalogEntry) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(entry.emoji, forType: .string) {
            status = "Copied \(entry.name)."; error = nil
        } else { error = "macOS could not copy this emoji." }
    }
}

@MainActor
struct EmojiToolView: View {
    @StateObject private var store = EmojiToolStore()
    @State private var search = ""
    @State private var group = "All"
    private var visible: [EmojiCatalogEntry] {
        EmojiCatalog.search(store.entries, query: search, group: group == "All" ? nil : group)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search emoji names or symbols", text: $search).textFieldStyle(.roundedBorder)
                Picker("Group", selection: $group) {
                    Text("All").tag("All")
                    ForEach(store.groups, id: \.self) { Text($0).tag($0) }
                }.frame(width: 180)
                Button("Character Palette") { NSApp.orderFrontCharacterPalette(nil) }
                    .help("Open the complete macOS character palette")
            }
            LocalToolError(message: store.error)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 42))], spacing: 8) {
                    ForEach(visible) { entry in
                        Button { store.copy(entry) } label: {
                            Text(entry.emoji).font(.system(size: 26)).frame(width: 38, height: 38)
                        }.buttonStyle(.plain).help(entry.name).accessibilityLabel("Copy \(entry.name)")
                            .onDrag { NSItemProvider(object: entry.emoji as NSString) }
                    }
                }.padding(.vertical, 4)
            }
            HStack {
                Text(store.status.isEmpty ? "Click to copy; drag to insert in a text destination." : store.status)
                Spacer()
                Text("\(visible.count) of \(store.entries.count) · Unicode 17.0")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
}
