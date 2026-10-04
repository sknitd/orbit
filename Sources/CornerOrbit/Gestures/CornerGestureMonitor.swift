import AppKit
import Combine
import CornerCore

enum CornerMonitorStatus: Equatable {
    case disabled, listening, inputMonitoringRequired, eventTapUnavailable, sessionInactive, noSelectedDisplays
    case invalidConfiguration(String)
    var message: String {
        switch self {
        case .disabled: "Corner monitoring is off."
        case .listening: "Listening for left-button corner clicks and drags. macOS Hot Corners may also respond."
        case .inputMonitoringRequired: "Allow CornerOrbit in System Settings → Privacy & Security → Input Monitoring, then enable again. macOS may require a relaunch."
        case .eventTapUnavailable: "The listen-only mouse event tap is unavailable or was interrupted. Enable again to retry."
        case .sessionInactive: "Monitoring is suspended while this session or its displays are inactive."
        case .noSelectedDisplays: "No connected display matches your selection. Connect a selected display or choose All Displays."
        case .invalidConfiguration(let text): "Corner configuration is invalid: \(text)"
        }
    }
}

private final class CornerSystemObservers: @unchecked Sendable {
    private var observations: [(NotificationCenter, any NSObjectProtocol)] = []
    @MainActor
    func add(center: NotificationCenter, name: Notification.Name, callback: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { callback() }
        }
        observations.append((center, token))
    }
    deinit { observations.forEach { $0.0.removeObserver($0.1) } }
}

/// Explicitly enabled, listen-only left-mouse observation. This class never
/// captures keyboard events, consumes an OS event, or performs an app action.
/// Click deadlines and system notifications are the only scheduled work.
@MainActor
final class CornerGestureMonitor: ObservableObject {
    @Published private(set) var status: CornerMonitorStatus = .disabled
    @Published private(set) var isEnabled = false
    @Published private(set) var permissionGranted = false
    @Published private(set) var screens: [CornerScreen] = []
    var diagnostic: String { status.message }

    private let dependencies: CornerMonitorDependencies
    private let onRecognized: @MainActor (CornerTrigger) -> Void
    private var settings: CornerSettings
    private var recognizer: CornerGestureRecognizer?
    private var source: (any CornerMouseEventSource)?
    private var observers: CornerSystemObservers?
    private var deadlineTask: Task<Void, Never>?
    private var deadline: Double?
    private var generation: UInt64 = 0
    private var showHints = false
    private var sessionAvailable = true
    private var displayAwake = true
    private var lastSample: CornerMouseSample?
    private let hints = CornerHintOverlay()

    init(settings: CornerSettings = .defaults, dependencies: CornerMonitorDependencies = .live,
         onRecognized: @escaping @MainActor (CornerTrigger) -> Void) {
        self.settings = settings; self.dependencies = dependencies; self.onRecognized = onRecognized
        // Even a previously enabled persisted preference cannot start a tap
        // or request a permission from this constructor.
        do { recognizer = try CornerGestureRecognizer(configuration: settings) }
        catch { status = .invalidConfiguration(error.localizedDescription) }
    }
    deinit { deadlineTask?.cancel() }

    func update(settings: CornerSettings, showHints: Bool = false) throws {
        cancelPending()
        do {
            let valid = try settings.validated()
            let next = try CornerGestureRecognizer(configuration: valid)
            self.settings = valid; self.recognizer = next; self.showHints = showHints
            if !valid.enabled { disable(); return }
            if isEnabled { refreshScreens(); updateHints() }
        } catch {
            disable(); status = .invalidConfiguration(error.localizedDescription)
            throw error
        }
    }

    /// A user action may prompt. Startup restoration calls resumeIfAuthorized,
    /// which never calls CGRequestListenEventAccess.
    @discardableResult
    func enable(requestPermission: Bool = true) -> Bool {
        if isEnabled { return true }
        do {
            var active = try settings.validated(); active.enabled = true
            recognizer = try CornerGestureRecognizer(configuration: active)
            settings = active
        } catch { status = .invalidConfiguration(error.localizedDescription); return false }
        cancelPending()
        screens = dependencies.screens().filter { $0.frame.isValid && !$0.id.isEmpty }
        guard !selectedScreens.isEmpty else { status = .noSelectedDisplays; return false }
        permissionGranted = dependencies.preflightAccess()
        if !permissionGranted && requestPermission {
            _ = dependencies.requestAccess()
            // The request result is not proof the running process is already
            // authorized. Check the public listening preflight again.
            permissionGranted = dependencies.preflightAccess()
        }
        guard permissionGranted else { status = .inputMonitoringRequired; return false }
        guard let installed = dependencies.installMouseEvents({ [weak self] sample in self?.receive(sample) }) else {
            status = .eventTapUnavailable; return false
        }
        source = installed; isEnabled = true
        sessionAvailable = dependencies.sessionActive(); displayAwake = true
        observeSystemEventsIfNeeded()
        status = sessionAvailable ? .listening : .sessionInactive
        updateHints()
        return true
    }
    @discardableResult
    func resumeIfAuthorized() -> Bool { enable(requestPermission: false) }

    func disable() {
        cancelPending()
        source?.stop(); source = nil; observers = nil
        isEnabled = false; status = .disabled; hints.hide()
    }
    func stop() { disable() }

    /// Read-only diagnostics; requesting access remains a separate explicit
    /// Enable action. Losing a grant invalidates all pending recognition.
    func refreshPermissionStatus() {
        permissionGranted = dependencies.preflightAccess()
        if isEnabled && !permissionGranted { disable(); status = .inputMonitoringRequired }
    }

    func refreshScreens() {
        let fresh = dependencies.screens().filter { $0.frame.isValid && !$0.id.isEmpty }
        let changed = fresh != screens
        if changed { cancelPending(); screens = fresh }
        if isEnabled {
            let nextStatus: CornerMonitorStatus = selectedScreens.isEmpty ? .noSelectedDisplays : sessionIsActive ? .listening : .sessionInactive
            let statusChanged = nextStatus != status
            if statusChanged { status = nextStatus }
            if changed || statusChanged { updateHints() }
        }
    }

    /// Public session/sleep notifications and injected fixtures use the same
    /// cancellation boundary. No undocumented lock-state keys are queried.
    func sessionDidChange(active: Bool) {
        sessionAvailable = active; cancelPending()
        if isEnabled { status = active && displayAwake && dependencies.sessionActive() ? .listening : .sessionInactive }
        updateHints()
    }

    private var selectedScreens: [CornerScreen] { screens.filter { settings.permits(displayID: $0.id) } }
    private var sessionIsActive: Bool { sessionAvailable && displayAwake && dependencies.sessionActive() }

    /// Internal injection boundary used by hosted tests; native observation
    /// arrives here only through copied mouse position/time/modifier values.
    func receive(_ sample: CornerMouseSample) {
        guard isEnabled else { return }
        if case .interrupted = sample.kind {
            disable(); permissionGranted = dependencies.preflightAccess()
            status = permissionGranted ? .eventTapUnavailable : .inputMonitoringRequired
            return
        }
        guard sessionIsActive else { cancelPending(); status = .sessionInactive; hints.hide(); return }
        // Display changes normally notify; an event-time comparison also
        // closes notification ordering races without an idle geometry poll.
        let ticket = generation
        refreshScreens()
        if generation != ticket { return }
        guard let screen = CornerScreenGeometry.screen(at: sample.point, in: screens), settings.permits(displayID: screen.id) else {
            cancelPending(); return
        }
        lastSample = sample
        let kind: CornerPointerEventKind
        switch sample.kind {
        case .down: kind = .down
        case .up: kind = .up
        case .dragged: kind = .dragged
        case .moved: kind = .moved
        case .interrupted: return
        }
        let corner = CornerGeometry.corner(at: sample.point, in: screen.frame, size: settings.cornerSize)
        let triggers = recognizer?.handle(CornerPointerEvent(kind: kind, screenID: screen.id, corner: corner,
            point: sample.point, timestamp: sample.timestamp, modifiers: sample.modifiers)) ?? []
        deliver(triggers)
        scheduleDeadline()
    }

    /// An explicit test clock may advance and flush pending clicks. Production
    /// calls this only from a pending click's one-shot deadline.
    func flushPending() {
        deadlineTask?.cancel(); deadlineTask = nil; deadline = nil
        guard isEnabled, sessionIsActive else { cancelPending(); return }
        let ticket = generation
        refreshScreens()
        guard generation == ticket else { return }
        let now = dependencies.now(), modifiers = dependencies.modifiers()
        if !modifiers.isSuperset(of: settings.modifierRequirement) {
            if let sample = lastSample, let screen = CornerScreenGeometry.screen(at: sample.point, in: screens) {
                _ = recognizer?.handle(.init(kind: .modifiersChanged, screenID: screen.id, corner: nil,
                    point: sample.point, timestamp: now, modifiers: modifiers))
            } else { cancelPending() }
        } else { deliver(recognizer?.flush(at: now) ?? []) }
        scheduleDeadline()
    }

    private func cancelPending() {
        generation &+= 1; deadlineTask?.cancel(); deadlineTask = nil; deadline = nil
        recognizer?.reset(); lastSample = nil
    }
    private func scheduleDeadline() {
        let next = recognizer?.nextDeadline
        // Pointer movement does not create/cancel a task for an unchanged
        // pending deadline. With no pending click, no timer exists at all.
        guard next != deadline else { return }
        deadlineTask?.cancel(); deadlineTask = nil; deadline = next
        guard let next, isEnabled else { return }
        let interval = max(0, next - dependencies.now()), ticket = generation
        deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            guard let self, generation == ticket, isEnabled else { return }
            flushPending()
        }
    }
    private func deliver(_ triggers: [CornerTrigger]) {
        guard !triggers.isEmpty else { return }
        let ticket = generation
        // Leave the native tap promptly; action execution belongs to the app
        // store, and never blocks a listen-only C callback.
        Task { @MainActor [weak self] in
            guard let self, isEnabled, generation == ticket, sessionIsActive else { return }
            let current = dependencies.screens().filter { $0.frame.isValid && !$0.id.isEmpty }
            guard current == screens else { refreshScreens(); return }
            for trigger in triggers {
                guard isEnabled, generation == ticket, settings.permits(displayID: trigger.screenID),
                      screens.contains(where: { $0.id == trigger.screenID }) else { return }
                onRecognized(trigger)
            }
        }
    }

    private func updateHints() {
        guard isEnabled, showHints, sessionIsActive, !selectedScreens.isEmpty else { hints.hide(); return }
        let corners = Set(Corner.allCases.filter { corner in
            guard let configuration = settings.corners[corner], configuration.enabled else { return false }
            return CornerGesture.allCases.contains { configuration.action(for: $0).kind != .none }
        })
        hints.show(screens: selectedScreens, enabledCorners: corners, size: settings.cornerSize)
    }
    private func observeSystemEventsIfNeeded() {
        guard dependencies.observeSystemEvents, observers == nil else { return }
        let holder = CornerSystemObservers()
        holder.add(center: .default, name: NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.refreshScreens() }
        let workspace = NSWorkspace.shared.notificationCenter
        holder.add(center: workspace, name: NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.sessionDidChange(active: false) }
        holder.add(center: workspace, name: NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.sessionDidChange(active: true) }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            holder.add(center: workspace, name: name) { [weak self] in
                guard let self, isEnabled else { return }; displayAwake = false; cancelPending()
                status = .sessionInactive; hints.hide()
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            holder.add(center: workspace, name: name) { [weak self] in
                guard let self, isEnabled else { return }; displayAwake = true; cancelPending()
                refreshPermissionStatus(); refreshScreens()
            }
        }
        observers = holder
    }
}
