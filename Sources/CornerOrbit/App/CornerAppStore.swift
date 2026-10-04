import AppKit
import Combine
import CornerCore

enum CornerSettingsPage: String, CaseIterable, Identifiable {
    case corners, gestures, profiles, behavior, history, links, clipboard, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .corners: "Corners"; case .gestures: "Gestures & Practice"; case .profiles: "Profiles & Rules"
        case .behavior: "Behavior"; case .history: "Websites"; case .links: "Favorites & Groups"
        case .clipboard: "Clipboard"; case .about: "Getting Started"
        }
    }
    var symbol: String {
        switch self {
        case .corners: "viewfinder"; case .gestures: "cursorarrow.motionlines"; case .profiles: "person.crop.rectangle.stack"
        case .behavior: "slider.horizontal.3"; case .history: "clock.arrow.circlepath"; case .links: "star"
        case .clipboard: "clipboard"; case .about: "hand.point.up.left"
        }
    }
}
enum CornerWebsiteSource { case chrome, recent, favorites }

@MainActor
final class CornerAppStore: ObservableObject {
    @Published private(set) var preferences: CornerPreferences
    @Published var selectedCorner: Corner = .topLeft
    @Published var page: CornerSettingsPage = .corners
    @Published var errorMessage: String?
    @Published private(set) var lastAction: String = "Choose a corner to get started."
    @Published private(set) var isRunningAction = false
    @Published private(set) var settingsNeedRecovery = false
    @Published private(set) var isExcluded = false
    @Published private(set) var suspensionReason: String?
    @Published private(set) var canUndoBinding = false
    @Published private(set) var canRedoBinding = false
    let history: ChromeHistoryStore
    let recent: RecentlyOpenedStore
    let profiles: CornerProfilesStore
    let timedPause: CornerTimedPauseController
    let login: CornerLaunchAtLoginService
    let links: CornerLinkStore
    let clipboard: CornerClipboardStore
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
    private var wantsMonitoring: Bool
    private var profileFailurePaused = false
    private struct BindingEdit { let corner: Corner; let gesture: CornerGesture; let before: CornerAction; let after: CornerAction }
    private var undoEdits: [BindingEdit] = []
    private var redoEdits: [BindingEdit] = []
    lazy var monitor: CornerGestureMonitor = CornerGestureMonitor(settings: preferences.settings,
        dependencies: monitorDependencies, onRecognized: { [weak self] trigger in self?.recognized(trigger) })

    init(preferences: CornerPreferences = .defaults, persistence: CornerPreferencesPersistence? = nil,
         monitorDependencies: CornerMonitorDependencies = .live, actionRunner: CornerActionRunner? = nil,
         history: ChromeHistoryStore? = nil, recent: RecentlyOpenedStore? = nil, isPreview: Bool = false,
         profiles: CornerProfilesStore? = nil, timedPause: CornerTimedPauseController? = nil,
         login: CornerLaunchAtLoginService? = nil, links: CornerLinkStore? = nil, clipboard: CornerClipboardStore? = nil) {
        self.preferences = preferences; self.persistence = persistence
        self.monitorDependencies = monitorDependencies; self.actionRunner = actionRunner ?? CornerActionRunner()
        self.history = history ?? ChromeHistoryStore.shared; self.recent = recent ?? RecentlyOpenedStore.shared
        // Default injected construction stays isolated. The live factory is
        // the only place that supplies persistent native services by default.
        self.profiles = profiles ?? CornerProfilesStore(preview: true)
        self.timedPause = timedPause ?? CornerTimedPauseController()
        self.login = login ?? CornerLaunchAtLoginService(preview: true)
        self.links = links ?? CornerLinkStore(preview: true)
        self.clipboard = clipboard ?? CornerClipboardStore(preview: true)
        self.wantsMonitoring = preferences.settings.enabled
        self.isPreview = isPreview
        self.profiles.onProfileSelected = { [weak self] settings in
            guard let self, !self.isShutDown else { throw CancellationError() }
            try self.applyProfileSettings(settings)
        }
        self.profiles.onExclusionChanged = { [weak self] excluded in
            guard let self, !self.isShutDown else { return }
            self.isExcluded = excluded; self.cancelActions(); self.reconcileMonitoring()
        }
        self.timedPause.onPause = { [weak self] in
            guard let self else { return }; self.cancelActions(); self.reconcileMonitoring()
        }
        self.timedPause.onResume = { [weak self] in self?.reconcileMonitoring() }
    }

    static func live() -> CornerAppStore {
        let persistence = CornerPreferencesPersistence.live
        func make(_ preferences: CornerPreferences) -> CornerAppStore {
            CornerAppStore(preferences: preferences, persistence: persistence, profiles: CornerProfilesStore(),
                login: CornerLaunchAtLoginService(), links: CornerLinkStore(), clipboard: CornerClipboardStore())
        }
        do { return make(try persistence.load()) }
        catch {
            let store = make(.defaults)
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
        guard !isPreview, !settingsNeedRecovery, !isShutDown else { return }
        profiles.resumeContext()
        do { try monitor.update(settings: preferences.settings, showHints: preferences.showHints); reconcileMonitoring() }
        catch { errorMessage = error.localizedDescription }
    }
    private func reconcileMonitoring(requestPermission: Bool = false) {
        suspensionReason = profileFailurePaused ? "Gestures are paused because a profile could not be applied. Apply a profile again or explicitly enable gestures."
            : isExcluded ? "Gestures are paused for this application."
            : timedPause.isPaused ? "Gestures are temporarily paused." : nil
        guard !isPreview, !settingsNeedRecovery, !isShutDown, wantsMonitoring,
              preferences.settings.enabled, !profileFailurePaused, !isExcluded, !timedPause.isPaused else { monitor.disable(); return }
        if requestPermission { monitor.enable(requestPermission: true) }
        else { monitor.resumeIfAuthorized() }
    }
    func pause(minutes: Int) { guard !isPreview, !isShutDown else { return }; timedPause.pause(minutes: minutes) }
    func resumePausedGestures() { guard !isPreview, !isShutDown else { return }; timedPause.resumeNow() }
    func setPractice(_ enabled: Bool) { cancelActions(); monitor.setPractice(enabled) }
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
        wantsMonitoring = enabled; timedPause.cancel()
        if enabled { profileFailurePaused = false }
        if !enabled { cancelActions() }
        var next = preferences; next.settings.enabled = enabled
        do {
            if !enabled { monitor.disable() }
            try commit(next)
            reconcileMonitoring(requestPermission: enabled)
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
        let action = try action.validated(), before = self.action(corner: corner, gesture: gesture)
        guard before != action else { return }
        var next = preferences
        next.settings.corners[corner, default: .init()].bindings[gesture] = action
        try commit(next)
        undoEdits.append(.init(corner: corner, gesture: gesture, before: before, after: action))
        if undoEdits.count > 100 { undoEdits.removeFirst() }
        redoEdits = []; updateUndoState()
    }
    func undoBinding() { replayBinding(undo: true) }
    func redoBinding() { replayBinding(undo: false) }
    private func replayBinding(undo: Bool) {
        guard let edit = undo ? undoEdits.last : redoEdits.last else { return }
        var next = preferences
        next.settings.corners[edit.corner, default: .init()].bindings[edit.gesture] = undo ? edit.before : edit.after
        do {
            try commit(next)
            if undo { undoEdits.removeLast(); redoEdits.append(edit) } else { redoEdits.removeLast(); undoEdits.append(edit) }
            selectedCorner = edit.corner; updateUndoState(); lastAction = undo ? "Binding edit undone." : "Binding edit restored."
        } catch { errorMessage = error.localizedDescription }
    }
    private func updateUndoState() { canUndoBinding = !undoEdits.isEmpty; canRedoBinding = !redoEdits.isEmpty }
    private func clearBindingUndo() { undoEdits = []; redoEdits = []; updateUndoState() }
    func applyProfileSettings(_ settings: CornerSettings) throws {
        guard !isShutDown else { throw CancellationError() }
        var next = preferences; next.settings = settings; next.settings.enabled = preferences.settings.enabled
        do {
            try commit(next); profileFailurePaused = false; clearBindingUndo(); reconcileMonitoring()
            lastAction = "Profile applied. Permission choices are unchanged."
        } catch {
            profileFailurePaused = true; cancelActions(); reconcileMonitoring()
            errorMessage = error.localizedDescription
            throw error
        }
    }
    func applyPreset() {
        cancelActions(); wantsMonitoring = false; timedPause.cancel()
        var next = preferences; next.settings = .samplePreset
        do { monitor.disable(); try commit(next); clearBindingUndo(); lastAction = "Starter bindings applied. Enable gestures when ready." }
        catch { errorMessage = error.localizedDescription }
    }
    func resetPreservingSettings() {
        cancelActions(); wantsMonitoring = false; timedPause.cancel()
        do {
            monitor.disable(); let backup = try persistence?.preserveForReset()
            try persistence?.save(.defaults)
            preferences = .defaults; settingsNeedRecovery = false; errorMessage = nil
            clearBindingUndo()
            try monitor.update(settings: .defaults, showHints: false)
            lastAction = backup == nil ? "Settings reset." : "Old settings preserved beside the new configuration."
        } catch { errorMessage = error.localizedDescription }
    }
    func action(corner: Corner, gesture: CornerGesture) -> CornerAction {
        preferences.settings.corners[corner]?.action(for: gesture) ?? .none
    }
    private func recognized(_ trigger: CornerTrigger) {
        guard !settingsNeedRecovery, wantsMonitoring, preferences.settings.enabled, monitor.isEnabled,
              !profileFailurePaused, !isExcluded, !timedPause.isPaused, !monitor.practiceMode else { return }
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
                case .showFavorites:
                    self.onShowWebsites?(.favorites, point)
                case .showClipboard:
                    self.onOpenSettings?(.clipboard)
                case .transformClipboard(let kind):
                    self.lastAction = try self.clipboard.perform(kind: kind)
                    self.onNotice?(self.lastAction)
                case .openURLGroup(let id):
                    let urls = try self.links.urls(forGroup: id)
                    var completed = 0
                    do {
                        for url in urls {
                            try Task.checkCancellation()
                            guard self.actionGeneration == token, !self.isShutDown else { throw CancellationError() }
                            _ = try await self.actionRunner.run(.init(kind: .openURL, url: url.absoluteString), automationEnabled: automationEnabled)
                            try Task.checkCancellation()
                            guard self.actionGeneration == token, !self.isShutDown else { throw CancellationError() }
                            completed += 1; self.recent.record(url)
                        }
                        self.lastAction = "Opened \(completed) websites."
                    } catch is CancellationError { throw CancellationError() }
                    catch { throw CornerActionError.invalid("Opened \(completed) of \(urls.count) websites. \(error.localizedDescription)") }
                    self.onNotice?(self.lastAction)
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
    func shutdown() {
        isShutDown = true; monitor.disable(); cancelActions(); history.shutdown()
        timedPause.shutdown(); profiles.shutdown()
    }
}
