import AppKit
import Combine
import CornerCore

enum CornerSettingsPage: String, CaseIterable, Identifiable {
    case corners, behavior, history, about
    var id: String { rawValue }
    var title: String {
        switch self { case .corners: "Corners"; case .behavior: "Behavior"; case .history: "Websites"; case .about: "Getting Started" }
    }
    var symbol: String {
        switch self { case .corners: "viewfinder"; case .behavior: "slider.horizontal.3"; case .history: "clock.arrow.circlepath"; case .about: "hand.point.up.left" }
    }
}
enum CornerWebsiteSource { case chrome, recent }

@MainActor
final class CornerAppStore: ObservableObject {
    @Published private(set) var preferences: CornerPreferences
    @Published var selectedCorner: Corner = .topLeft
    @Published var page: CornerSettingsPage = .corners
    @Published var errorMessage: String?
    @Published private(set) var lastAction: String = "Choose a corner to get started."
    @Published private(set) var isRunningAction = false
    @Published private(set) var settingsNeedRecovery = false
    let history: ChromeHistoryStore
    let recent: RecentlyOpenedStore
    let isPreview: Bool
    var onOpenSettings: (@MainActor (CornerSettingsPage) -> Void)?
    var onShowWebsites: (@MainActor (CornerWebsiteSource, CornerPoint?) -> Void)?
    var onNotice: (@MainActor (String) -> Void)?
    private let persistence: CornerPreferencesPersistence?
    private let monitorDependencies: CornerMonitorDependencies
    private let actionRunner: CornerActionRunner
    private var actionTask: Task<Void, Never>?
    private var actionTaskID: UUID?
    private var actionGeneration: UInt64 = 0
    private var isShutDown = false
    lazy var monitor: CornerGestureMonitor = CornerGestureMonitor(settings: preferences.settings,
        dependencies: monitorDependencies, onRecognized: { [weak self] trigger in self?.recognized(trigger) })

    init(preferences: CornerPreferences = .defaults, persistence: CornerPreferencesPersistence? = nil,
         monitorDependencies: CornerMonitorDependencies = .live, actionRunner: CornerActionRunner? = nil,
         history: ChromeHistoryStore? = nil, recent: RecentlyOpenedStore? = nil, isPreview: Bool = false) {
        self.preferences = preferences; self.persistence = persistence
        self.monitorDependencies = monitorDependencies; self.actionRunner = actionRunner ?? CornerActionRunner()
        self.history = history ?? ChromeHistoryStore.shared; self.recent = recent ?? RecentlyOpenedStore.shared
        self.isPreview = isPreview
    }

    static func live() -> CornerAppStore {
        let persistence = CornerPreferencesPersistence.live
        do { return CornerAppStore(preferences: try persistence.load(), persistence: persistence) }
        catch {
            let store = CornerAppStore(persistence: persistence)
            store.settingsNeedRecovery = true
            store.errorMessage = "Saved settings could not be read and were preserved. \(error.localizedDescription)"
            return store
        }
    }
    static func preview(settings: CornerSettings = .samplePreset, historyEntries: [CornerHistoryEntry] = [],
                        recentEntries: [CornerHistoryEntry] = []) -> CornerAppStore {
        .init(preferences: .init(settings: settings), history: ChromeHistoryStore(previewEntries: historyEntries),
              recent: RecentlyOpenedStore(previewEntries: recentEntries), isPreview: true)
    }

    func resume() {
        guard !isPreview, !settingsNeedRecovery, !isShutDown, preferences.settings.enabled else { return }
        do { try monitor.update(settings: preferences.settings, showHints: preferences.showHints); monitor.resumeIfAuthorized() }
        catch { errorMessage = error.localizedDescription }
    }
    func commit(_ next: CornerPreferences) throws {
        guard !settingsNeedRecovery else { throw CornerActionError.invalid("Preserve and reset the unreadable settings before making changes.") }
        let valid = try next.validated()
        cancelActions()
        try persistence?.save(valid)
        preferences = valid
        try monitor.update(settings: valid.settings, showHints: valid.showHints)
        errorMessage = nil
    }
    func updateSettings(_ edit: (inout CornerSettings) -> Void) {
        var next = preferences; edit(&next.settings)
        do { try commit(next) } catch { errorMessage = error.localizedDescription }
    }
    func setMonitoring(_ enabled: Bool) {
        guard !isPreview, !isShutDown else { return }
        if !enabled { cancelActions() }
        var next = preferences; next.settings.enabled = enabled
        do {
            if !enabled { monitor.disable() }
            try commit(next)
            if enabled { monitor.enable(requestPermission: true) }
        } catch { monitor.disable(); errorMessage = error.localizedDescription }
    }
    func setAutomation(_ enabled: Bool) {
        if !enabled { cancelActions() }
        var next = preferences; next.automationEnabled = enabled
        do { try commit(next) } catch { errorMessage = error.localizedDescription }
    }
    func setHints(_ enabled: Bool) {
        var next = preferences; next.showHints = enabled
        do { try commit(next) } catch { errorMessage = error.localizedDescription }
    }
    func assign(_ action: CornerAction, to corner: Corner, gesture: CornerGesture) throws {
        var next = preferences
        next.settings.corners[corner, default: .init()].bindings[gesture] = try action.validated()
        try commit(next)
    }
    func applyPreset() {
        cancelActions()
        var next = preferences; next.settings = .samplePreset
        do { monitor.disable(); try commit(next); lastAction = "Starter bindings applied. Enable gestures when ready." }
        catch { errorMessage = error.localizedDescription }
    }
    func resetPreservingSettings() {
        cancelActions()
        do {
            monitor.disable(); let backup = try persistence?.preserveForReset()
            try persistence?.save(.defaults)
            preferences = .defaults; settingsNeedRecovery = false; errorMessage = nil
            try monitor.update(settings: .defaults, showHints: false)
            lastAction = backup == nil ? "Settings reset." : "Old settings preserved beside the new configuration."
        } catch { errorMessage = error.localizedDescription }
    }
    func action(corner: Corner, gesture: CornerGesture) -> CornerAction {
        preferences.settings.corners[corner]?.action(for: gesture) ?? .none
    }
    private func recognized(_ trigger: CornerTrigger) {
        guard !settingsNeedRecovery, preferences.settings.enabled, monitor.isEnabled else { return }
        perform(preferences.settings.action(for: trigger), point: trigger.point)
    }
    func perform(_ action: CornerAction, point: CornerPoint? = nil) {
        guard !isPreview, !settingsNeedRecovery, !isShutDown, action.kind != .none else { return }
        guard actionTask == nil else { errorMessage = "Another action is still running."; onNotice?(errorMessage!); return }
        errorMessage = nil; isRunningAction = true
        let token = actionGeneration, identifier = UUID()
        let automationEnabled = preferences.automationEnabled
        actionTaskID = identifier
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // Cancelled work stays serialized until the native runner settles.
                // Only the task owning this slot can release it.
                if self.actionTaskID == identifier {
                    self.actionTask = nil; self.actionTaskID = nil; self.isRunningAction = false
                }
            }
            do {
                try Task.checkCancellation()
                guard self.actionGeneration == token, !self.isShutDown else { return }
                let result = try await self.actionRunner.run(action, automationEnabled: automationEnabled)
                try Task.checkCancellation()
                guard self.actionGeneration == token, !self.isShutDown else { return }
                switch result {
                case .performed(let title):
                    self.lastAction = title
                    if let url = action.webURL { self.recent.record(url, title: action.kind == .openURL ? url.host ?? url.absoluteString : action.kind.title) }
                    self.onNotice?(title)
                case .showChromeHistory:
                    self.onShowWebsites?(.chrome, point)
                case .showRecentWebsites:
                    self.onShowWebsites?(.recent, point)
                }
            } catch is CancellationError {
                if self.actionGeneration == token { self.lastAction = "Action canceled." }
            }
            catch {
                guard !Task.isCancelled, self.actionGeneration == token, !self.isShutDown else { return }
                self.errorMessage = error.localizedDescription; self.onNotice?(error.localizedDescription)
                guard self.actionGeneration == token, !self.isShutDown else { return }
                self.onOpenSettings?(.corners)
            }
        }
    }
    func openWebsite(_ entry: CornerHistoryEntry) { perform(.init(kind: .openURL, url: entry.url.absoluteString)) }
    private func cancelActions() {
        actionGeneration &+= 1
        actionTask?.cancel()
        if actionTask != nil { lastAction = "Action canceled." }
    }
    func shutdown() { isShutDown = true; monitor.disable(); cancelActions(); history.shutdown() }
}
