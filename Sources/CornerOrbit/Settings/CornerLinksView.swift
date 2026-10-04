import SwiftUI
import CornerCore

@MainActor struct CornerLinksView: View {
    @ObservedObject private var links: CornerLinkStore
    private let onOpenFavorite: @MainActor (CornerFavorite) -> Void
    private let onOpenGroup: @MainActor (CornerLinkGroup) -> Void
    @State private var search = ""
    @State private var favoriteEditor: FavoriteEditorRequest?
    @State private var groupEditor: GroupEditorRequest?
    init(store: CornerAppStore) {
        links = store.links
        onOpenFavorite = { favorite in store.perform(.init(kind: .openURL, url: favorite.url.absoluteString)) }
        onOpenGroup = { group in store.perform(.init(kind: .openURLGroup, argument: group.id.uuidString)) }
    }
    init(links: CornerLinkStore = .shared, onOpenFavorite: @escaping @MainActor (CornerFavorite) -> Void = { _ in }, onOpenGroup: @escaping @MainActor (CornerLinkGroup) -> Void = { _ in }) {
        self.links = links; self.onOpenFavorite = onOpenFavorite; self.onOpenGroup = onOpenGroup
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Favorites & URL Groups").font(.title2.bold())
            Text("These ordered lists are stored privately on this Mac. Saving or previewing them never contacts a website. Bind Favorites or a saved group to any corner gesture.").foregroundStyle(.secondary)
            HStack { TextField("Search favorite titles or websites", text: $search).textFieldStyle(.roundedBorder); Button("New Favorite") { favoriteEditor = .init(favorite: nil) }.disabled(links.needsRecovery) }
            List(links.searchFavorites(search)) { favorite in
                HStack {
                    VStack(alignment: .leading) { Text(favorite.title).font(.headline); Text(favorite.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open") { onOpenFavorite(favorite) }; Button("Edit") { favoriteEditor = .init(favorite: favorite) }
                    Button { run { try links.moveFavorite(favorite.id, by: -1) } } label: { Image(systemName: "arrow.up") }.disabled(!search.isEmpty || links.favorites.first?.id == favorite.id).help("Move favorite up").accessibilityLabel("Move favorite \(favorite.title) up")
                    Button { run { try links.moveFavorite(favorite.id, by: 1) } } label: { Image(systemName: "arrow.down") }.disabled(!search.isEmpty || links.favorites.last?.id == favorite.id).help("Move favorite down").accessibilityLabel("Move favorite \(favorite.title) down")
                    Button { run { try links.removeFavorite(favorite.id) } } label: { Image(systemName: "trash") }.accessibilityLabel("Remove favorite \(favorite.title)")
                }
            }.frame(height: 210).overlay { if links.favorites.isEmpty { Text("Add a favorite to build your corner dropdown.").foregroundStyle(.secondary).allowsHitTesting(false) } }
            HStack { Text("URL launch groups").font(.headline); Spacer(); Button("New URL Group") { groupEditor = .init(group: nil) }.disabled(links.needsRecovery) }
            List(links.groups) { group in
                HStack {
                    VStack(alignment: .leading) { Text(group.name).font(.headline); Text("\(group.urls.count) websites — opens in listed order").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open Group") { onOpenGroup(group) }; Button("Edit") { groupEditor = .init(group: group) }
                    Button { run { try links.moveGroup(group.id, by: -1) } } label: { Image(systemName: "arrow.up") }.disabled(links.groups.first?.id == group.id).help("Move group up").accessibilityLabel("Move URL group \(group.name) up")
                    Button { run { try links.moveGroup(group.id, by: 1) } } label: { Image(systemName: "arrow.down") }.disabled(links.groups.last?.id == group.id).help("Move group down").accessibilityLabel("Move URL group \(group.name) down")
                    Button { run { try links.removeGroup(group.id) } } label: { Image(systemName: "trash") }.accessibilityLabel("Remove URL group \(group.name)")
                }
            }.frame(height: 145)
            Text("Up to 200 favorites, 40 named groups and 10 websites per group. URLs must use HTTP(S) and contain no login credentials. Group opening is explicit and can partially succeed if an application launch fails.").font(.caption).foregroundStyle(.secondary)
            if let error = links.errorMessage { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text(links.status).font(.caption).foregroundStyle(.secondary); Spacer()
                Button("Reload Library") { run { try links.reload() } }
                if links.needsRecovery { Button("Preserve Original & Reset") { run { try links.resetPreservingOriginal() } } }
            }
        }.padding(20)
        }
            .sheet(item: $favoriteEditor) { request in CornerFavoriteEditorView(links: links, favorite: request.favorite) { favoriteEditor = nil } }
            .sheet(item: $groupEditor) { request in CornerURLGroupEditorView(links: links, group: request.group) { groupEditor = nil } }
    }
    private func run(_ operation: () throws -> Void) { do { try operation() } catch { } }
    private struct FavoriteEditorRequest: Identifiable { let id = UUID(); let favorite: CornerFavorite? }
    private struct GroupEditorRequest: Identifiable { let id = UUID(); let group: CornerLinkGroup? }
}

@MainActor struct CornerFavoriteEditorView: View {
    @ObservedObject var links: CornerLinkStore
    private let identifier: UUID
    private let onFinish: () -> Void
    @State private var title: String
    @State private var address: String
    @State private var error: String?
    init(links: CornerLinkStore, favorite: CornerFavorite? = nil, onFinish: @escaping () -> Void = {}) {
        self.links = links; identifier = favorite?.id ?? UUID(); self.onFinish = onFinish
        _title = State(initialValue: favorite?.title ?? ""); _address = State(initialValue: favorite?.url.absoluteString ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Favorite Website").font(.title2.bold())
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).accessibilityLabel("Favorite title")
            TextField("https://example.com", text: $address).textFieldStyle(.roundedBorder).accessibilityLabel("Favorite website URL")
            Text("Saving adds this credential-free website to your local ordered favorites. It does not open the website.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Button("Cancel") { onFinish() }; Spacer(); Button("Save Favorite") {
                do { try links.saveFavorite(.init(id: identifier, title: title, url: CornerURLValidation.webURL(address))); onFinish() }
                catch { self.error = error.localizedDescription }
            } }
        }.padding(24).frame(width: 520)
    }
}

@MainActor struct CornerURLGroupEditorView: View {
    @ObservedObject var links: CornerLinkStore
    private let identifier: UUID
    private let onFinish: () -> Void
    @State private var name: String
    @State private var addresses: String
    @State private var error: String?
    init(links: CornerLinkStore, group: CornerLinkGroup? = nil, onFinish: @escaping () -> Void = {}) {
        self.links = links; identifier = group?.id ?? UUID(); self.onFinish = onFinish
        _name = State(initialValue: group?.name ?? ""); _addresses = State(initialValue: group?.urls.map(\.absoluteString).joined(separator: "\n") ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("URL Launch Group").font(.title2.bold()); TextField("Group name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("URL group name")
            Text("One HTTP(S) website per line, in launch order. Up to ten unique URLs.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $addresses).font(.system(.body, design: .monospaced)).frame(height: 170).accessibilityLabel("URL group websites, one per line").overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            Text("Saving only updates your local library. Bind this group to a gesture or use Open Group to launch it explicitly.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Button("Cancel") { onFinish() }; Spacer(); Button("Save Group") {
                do {
                    let lines = addresses.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    guard (1...10).contains(lines.count) else { throw CornerActionError.invalid("Choose 1–10 websites, one per line.") }
                    try links.saveGroup(.init(id: identifier, name: name, urls: lines.map { try CornerURLValidation.webURL($0) })); onFinish()
                } catch { self.error = error.localizedDescription }
            } }
        }.padding(24).frame(width: 540)
    }
}
