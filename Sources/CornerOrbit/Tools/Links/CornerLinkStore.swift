import Foundation
import Combine
import Darwin
import CornerCore

@MainActor final class CornerLinkStore: ObservableObject {
    static let shared = CornerLinkStore()
    @Published private(set) var favorites: [CornerFavorite] = []
    @Published private(set) var groups: [CornerLinkGroup] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var status = "Favorites and URL groups stay on this Mac."
    @Published private(set) var needsRecovery = false
    private var library = CornerLinkLibrary()
    private var originalBytes: Data?
    private let file: URL?

    init(directory: URL? = nil, preview: Bool = false, previewFavorites: [CornerFavorite] = [], previewGroups: [CornerLinkGroup] = []) {
        if preview {
            file = nil
            do { library = try CornerLinkLibrary(favorites: previewFavorites, groups: previewGroups).validated(); favorites = library.favorites; groups = library.groups }
            catch { errorMessage = error.localizedDescription }
            return
        }
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.sknitd.CornerOrbit", isDirectory: true)
        file = root.appendingPathComponent("links-v1.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try validateDirectory(root)
            originalBytes = try readOriginal()
            library = try originalBytes.map(CornerLinkLibrary.decode) ?? .init()
            favorites = library.favorites; groups = library.groups
        } catch { needsRecovery = true; errorMessage = "The local link library could not be read and was retained. \(error.localizedDescription)" }
    }
    func searchFavorites(_ query: String) -> [CornerFavorite] { library.searchFavorites(query) }
    func saveFavorite(_ value: CornerFavorite) throws {
        try edit { state in
            let valid = try value.validated()
            if let index = state.favorites.firstIndex(where: { $0.id == valid.id }) { state.favorites[index] = valid }
            else { state.favorites.append(valid) }
        }
    }
    func removeFavorite(_ id: UUID) throws { try edit { state in guard state.favorites.contains(where: { $0.id == id }) else { throw CornerActionError.invalid("The favorite no longer exists.") }; state.favorites.removeAll { $0.id == id } } }
    func moveFavorite(_ id: UUID, by offset: Int) throws {
        try edit { state in guard [-1, 1].contains(offset), let index = state.favorites.firstIndex(where: { $0.id == id }), state.favorites.indices.contains(index + offset) else { throw CornerActionError.invalid("Choose an adjacent position for this favorite.") }; state.favorites.swapAt(index, index + offset) }
    }
    func saveGroup(_ value: CornerLinkGroup) throws {
        try edit { state in let valid = try value.validated(); if let index = state.groups.firstIndex(where: { $0.id == valid.id }) { state.groups[index] = valid } else { state.groups.append(valid) } }
    }
    func removeGroup(_ id: UUID) throws { try edit { state in guard state.groups.contains(where: { $0.id == id }) else { throw CornerActionError.invalid("The URL group no longer exists.") }; state.groups.removeAll { $0.id == id } } }
    func moveGroup(_ id: UUID, by offset: Int) throws {
        try edit { state in guard [-1, 1].contains(offset), let index = state.groups.firstIndex(where: { $0.id == id }), state.groups.indices.contains(index + offset) else { throw CornerActionError.invalid("Choose an adjacent position for this URL group.") }; state.groups.swapAt(index, index + offset) }
    }
    func urls(forGroup identifier: String) throws -> [URL] {
        guard !needsRecovery, let id = UUID(uuidString: identifier), let group = groups.first(where: { $0.id == id }) else { throw CornerActionError.invalid("The selected URL group is missing or its local library needs recovery. Choose a saved group.") }
        return try group.validated().urls
    }
    func reload() throws {
        do { let bytes = try readOriginal(); let next = try bytes.map(CornerLinkLibrary.decode) ?? .init(); originalBytes = bytes; publish(next); needsRecovery = false; errorMessage = nil; status = "Reloaded the local link library." }
        catch { errorMessage = "Reload failed; the original library remains untouched. \(error.localizedDescription)"; throw error }
    }
    func resetPreservingOriginal() throws {
        guard let file else { publish(.init()); needsRecovery = false; errorMessage = nil; return }
        var backup: URL?
        do {
            if try hasNode(file) {
                var info = stat(); guard lstat(file.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw CornerActionError.invalid("The library path is a link or directory. It was left untouched; fix the path before resetting.") }
                let saved = file.deletingLastPathComponent().appendingPathComponent("links-v1.backup.\(UUID().uuidString).json")
                try FileManager.default.moveItem(at: file, to: saved); backup = saved
            }
            originalBytes = nil
            let next = CornerLinkLibrary(), bytes = try next.encoded()
            try saveAtomically(bytes, expecting: nil); originalBytes = bytes
            publish(next); needsRecovery = false; errorMessage = nil
            status = backup == nil ? "Link library reset." : "Reset complete; the original library is retained in a private backup beside it."
        } catch {
            if let backup, (try? hasNode(file)) == false { try? FileManager.default.moveItem(at: backup, to: file) }
            needsRecovery = true; errorMessage = "Reset did not complete. The prior library or its backup remains retained. \(error.localizedDescription)"; throw error
        }
    }
    private func edit(_ mutation: (inout CornerLinkLibrary) throws -> Void) throws {
        do {
            guard !needsRecovery else { throw CornerActionError.invalid("Preserve and reset or reload the unreadable link library before editing.") }
            var next = library; try mutation(&next); next = try next.validated()
            let bytes = try next.encoded()
            try saveAtomically(bytes, expecting: originalBytes)
            if file != nil { originalBytes = bytes }
            publish(next); errorMessage = nil; status = "Saved locally. No website was opened or contacted."
        } catch { errorMessage = error.localizedDescription; throw error }
    }
    private func publish(_ next: CornerLinkLibrary) { library = next; favorites = next.favorites; groups = next.groups }
    private func validateDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw CornerActionError.invalid("Use a private regular directory for the link library; directory links are not accepted.") }
    }
    private func hasNode(_ url: URL) throws -> Bool {
        var info = stat(); if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }; throw CocoaError(.fileReadUnknown)
    }
    private func readOriginal() throws -> Data? {
        guard let file, try hasNode(file) else { return nil }
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size <= Int64(CornerLinkLibrary.maximumBytes) else { throw CornerActionError.invalid("The library must be a regular JSON file of at most 2 MB. Its contents were retained.") }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: CornerLinkLibrary.maximumBytes + 1) ?? Data()
        guard bytes.count <= CornerLinkLibrary.maximumBytes else { throw CornerActionError.invalid("The link library exceeds 2 MB.") }; return bytes
    }
    private func saveAtomically(_ bytes: Data, expecting expected: Data?) throws {
        guard let file else { return }
        try validateDirectory(file.deletingLastPathComponent())
        guard try readOriginal() == expected else { throw CornerActionError.invalid("The library changed outside this editor. Reload before saving; the changed file was retained.") }
        let stage = file.deletingLastPathComponent().appendingPathComponent(".links-stage-\(UUID().uuidString)")
        let descriptor = open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor); try? FileManager.default.removeItem(at: stage) }
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count { let amount = write(descriptor, base.advanced(by: offset), buffer.count - offset); guard amount > 0 else { throw CocoaError(.fileWriteUnknown) }; offset += amount }
        }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        guard try readOriginal() == expected else { throw CornerActionError.invalid("The library changed while saving. Reload; no changed file was overwritten.") }
        guard rename(stage.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
