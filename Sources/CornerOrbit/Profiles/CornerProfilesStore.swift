import AppKit
import Combine
import CornerCore
import UniformTypeIdentifiers

@MainActor
final class CornerProfilesStore: ObservableObject {
    @Published private(set) var profiles: [CornerProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var autoSwitchEnabled = false
    @Published private(set) var excludedAppIDs: Set<String> = []
    @Published private(set) var rules: [CornerProfileRule] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var importPreview: CornerProfileImportPreview?
    @Published private(set) var needsRecovery = false
    @Published private(set) var isObservingContext = false
    let isPreview: Bool
    var onProfileSelected: (@MainActor (CornerSettings) throws -> Void)?
    var onExclusionChanged: (@MainActor (Bool) -> Void)?
    private let persistence: CornerProfilePersistence?
    private let contextSource: any CornerProfileContextSource
    private var archive = CornerProfilesArchive.defaults
    private var revision = UUID()
    private var previewRevision: UUID?
    private var lifecycleActive = false
    private var contextGeneration = UUID()
    private var lastExcluded = false
    init(preview: Bool = false, persistence: CornerProfilePersistence? = .live,
         contextSource: (any CornerProfileContextSource)? = nil, initialArchive: CornerProfilesArchive? = nil) {
        isPreview = preview; self.persistence = preview ? nil : persistence
        self.contextSource = contextSource ?? CornerWorkspaceProfileContext()
        do {
            archive = try (initialArchive ?? (preview ? .defaults : try persistence?.load() ?? .defaults)).validated()
            publishArchive()
        } catch { needsRecovery = true; errorMessage = "Saved profiles could not be read and were preserved. \(error.localizedDescription)" }
        // Loading snapshots never applies one, starts observers, or requests access.
    }
    @discardableResult
    func create(name: String, settings: CornerSettings) throws -> UUID {
        let profile = try CornerProfile(name: name, settings: settings).validated()
        var next = archive; next.profiles.append(profile); try commit(next); return profile.id
    }
    @discardableResult
    func duplicate(id: UUID) throws -> UUID {
        guard let original = profiles.first(where: { $0.id == id }) else { throw CornerActionError.invalid("Choose a saved profile to duplicate.") }
        var count = 2, name = original.name
        let names = Set(profiles.map { CornerProfileValidation.nameKey($0.name) })
        repeat {
            let suffix = " Copy \(count)"; var base = original.name
            while base.count + suffix.count > 80 || base.utf8.count + suffix.utf8.count > 240 { base.removeLast() }
            name = base + suffix; count += 1
        } while names.contains(CornerProfileValidation.nameKey(name))
        return try create(name: name, settings: original.settings)
    }
    func rename(id: UUID, name: String) throws {
        var next = archive; guard let index = next.profiles.firstIndex(where: { $0.id == id }) else { throw CornerActionError.invalid("Choose a saved profile to rename.") }
        next.profiles[index].name = name; try commit(next)
    }
    func delete(id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw CornerActionError.invalid("Choose a saved profile to delete.") }
        var next = archive; next.profiles.removeAll { $0.id == id }; next.rules.removeAll { $0.profileID == id }
        if next.activeProfileID == id { next.activeProfileID = nil }; try commit(next)
    }
    func saveSnapshot(id: UUID, settings: CornerSettings) throws {
        var next = archive; guard let index = next.profiles.firstIndex(where: { $0.id == id }) else { throw CornerActionError.invalid("Choose a saved profile to update.") }
        next.profiles[index].settings = settings; try commit(next)
    }
    func activate(id: UUID) throws {
        guard !needsRecovery else { throw CornerActionError.invalid("Preserve and reset unreadable profiles before applying one.") }
        guard let profile = profiles.first(where: { $0.id == id }) else { throw CornerActionError.invalid("Choose a saved profile to apply.") }
        if !isPreview {
            guard let onProfileSelected else { throw CornerActionError.invalid("The profile apply handler is not ready.") }
            try onProfileSelected(profile.settings)
        }
        activeProfileID = id
        var next = archive; next.activeProfileID = id
        do { try commit(next); activeProfileID = id }
        catch {
            // Settings and profile selection use separate files. The root apply
            // succeeded, so the runtime label stays honest if selection-save fails.
            activeProfileID = id
            let message = "Profile applied, but its selection could not be saved: \(error.localizedDescription)"
            errorMessage = message; throw CornerActionError.invalid(message)
        }
    }
    func setAutoSwitchEnabled(_ value: Bool) throws { var next = archive; next.autoSwitchEnabled = value; try commit(next); reconcileContext() }
    func setExcludedAppIDs(_ values: Set<String>) throws { var next = archive; next.excludedAppIDs = values; try commit(next); reconcileContext() }
    func addRule(bundleID: String, profileID: UUID, enabled: Bool = false) throws {
        var next = archive; next.rules.append(.init(bundleID: bundleID, profileID: profileID, enabled: enabled)); try commit(next); reconcileContext()
    }
    func updateRule(_ value: CornerProfileRule) throws {
        var next = archive; guard let index = next.rules.firstIndex(where: { $0.id == value.id }) else { throw CornerActionError.invalid("This profile rule is no longer available.") }
        next.rules[index] = value; try commit(next); reconcileContext()
    }
    func deleteRule(id: UUID) throws { var next = archive; next.rules.removeAll { $0.id == id }; try commit(next); reconcileContext() }
    func moveRule(id: UUID, by offset: Int) throws {
        var next = archive; guard let index = next.rules.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(index + offset, 0), next.rules.count - 1)
        guard destination != index else { return }; let rule = next.rules.remove(at: index); next.rules.insert(rule, at: destination)
        try commit(next); reconcileContext()
    }
    func previewImport(data: Data) throws {
        guard !needsRecovery else { throw CornerActionError.invalid("Preserve and reset unreadable profiles before importing.") }
        let plan = try CornerProfileImportPreview.prepare(data: data, existing: profiles)
        importPreview = plan; previewRevision = revision; errorMessage = nil
    }
    func applyImport() throws {
        guard let preview = importPreview, previewRevision == revision else { throw CornerActionError.invalid("Profiles changed after this preview. Review the import again.") }
        var next = archive; next.profiles = preview.mergedProfiles; try commit(next)
        cancelImport()
        // Applying an import adds snapshots only, with no profile callback/opt-ins.
    }
    func cancelImport() { importPreview = nil; previewRevision = nil }
    func exportData() throws -> Data { try CornerProfileDocument(profiles: profiles).encoded() }
    func chooseImport() {
        guard !isPreview else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= CornerProfileValidation.maximumBytes else { throw CornerActionError.invalid("Choose a regular profile JSON file of at most 2 MiB.") }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            try previewImport(data: handle.read(upToCount: CornerProfileValidation.maximumBytes + 1) ?? Data())
        } catch { report(error: error) }
    }
    func chooseExport() {
        guard !isPreview else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "CornerOrbitProfiles.json"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do { try CornerProfileExport.write(exportData(), to: file); errorMessage = nil } catch { report(error: error) }
    }
    func preserveAndReset() throws {
        stopContext(); _ = try persistence?.preserveForReset(); try persistence?.save(.defaults)
        archive = .defaults; needsRecovery = false; revision = UUID(); cancelImport(); publishArchive(); errorMessage = nil
        onExclusionChanged?(false); lastExcluded = false
    }
    func report(error: any Error) { errorMessage = error.localizedDescription }
    func resumeContext() { lifecycleActive = true; reconcileContext() }
    func stopContext() { lifecycleActive = false; contextGeneration = UUID(); contextSource.stop(); isObservingContext = false }
    func shutdown() { stopContext() }
    private func commit(_ next: CornerProfilesArchive) throws {
        guard !needsRecovery else { throw CornerActionError.invalid("Preserve and reset unreadable profiles before making changes.") }
        let valid = try next.validated(); try persistence?.save(valid)
        let runtimeSelection = activeProfileID
        archive = valid; revision = UUID(); publishArchive()
        if let runtimeSelection, profiles.contains(where: { $0.id == runtimeSelection }) { activeProfileID = runtimeSelection }
        errorMessage = nil
    }
    private func publishArchive() {
        profiles = archive.profiles; activeProfileID = archive.activeProfileID; autoSwitchEnabled = archive.autoSwitchEnabled
        excludedAppIDs = archive.excludedAppIDs; rules = archive.rules
    }
    private func reconcileContext() {
        guard !isPreview, !needsRecovery, lifecycleActive, autoSwitchEnabled || !excludedAppIDs.isEmpty else {
            contextGeneration = UUID(); contextSource.stop(); isObservingContext = false
            if lastExcluded { lastExcluded = false; onExclusionChanged?(false) }; return
        }
        if !isObservingContext {
            let token = UUID(); contextGeneration = token
            contextSource.start { [weak self] identifier in
                guard let self, self.contextGeneration == token, self.isObservingContext else { return }
                self.processFrontmost(identifier)
            }
            isObservingContext = true
        }
        processFrontmost(contextSource.currentBundleID)
    }
    private func processFrontmost(_ identifier: String?) {
        guard let identifier else { return }
        let excluded = excludedAppIDs.contains(identifier)
        if excluded != lastExcluded { lastExcluded = excluded; onExclusionChanged?(excluded) }
        guard identifier != "com.sknitd.CornerOrbit" else { return }
        guard !excluded, let profile = archive.profile(matching: identifier), profile.id != activeProfileID else { return }
        guard let onProfileSelected else { errorMessage = "The profile apply handler is not ready."; return }
        do { try onProfileSelected(profile.settings); activeProfileID = profile.id; errorMessage = nil }
        catch { errorMessage = "Profile could not be applied: \(error.localizedDescription)" }
        // Automatic selection is ephemeral. Unmatched apps retain the current
        // profile; the explicitly saved selection remains unchanged on disk.
    }
}
