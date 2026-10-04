import SwiftUI
import AppKit
import OrbitCore
import NotchCore

@main
@MainActor
struct NotchOrbitPlusApp: App {
    @NSApplicationDelegateAdaptor(NotchAppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            PlusSettingsView(model: delegate.model, dashboardPreferences: delegate.dashboardPreferences,
                             requestAccess: delegate.requestAccess, applyPreferences: delegate.applyPreferences)
        }
    }
}

@MainActor
final class NotchAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = AppModel()
    let dashboardPreferences = DashboardPreferences()
    private lazy var dashboard = NotchDashboardController(
        modules: Self.dashboardModules(chooseFiles: { [weak self] in self?.chooseFiles() }),
        preferences: dashboardPreferences, compactContent: { AnyView(PlusCompactView()) })
    private let shortcut = GlobalNotchShortcut()
    private let panel = NotchPanelController()
    private var drag: NotchDragMonitor?
    private var statusItem: NSStatusItem?
    private var resultsWindow: NSPanel?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var inspectionTask: Task<Void, Never>?
    private var presentationID: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                    accessibilityDescription: "NotchOrbitPlus")
            ?? NSImage(systemSymbolName: "circle.dotted.circle", accessibilityDescription: "NotchOrbitPlus")
        let menu = NSMenu()
        menu.addItem(withTitle: "NotchOrbitPlus — Drag to the notch. Drop an action.", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, "Open Notch Dashboard", #selector(showDashboard))
        add(menu, "Choose Files…", #selector(chooseFiles), "o")
        add(menu, "Results & Progress", #selector(showResults), "r")
        add(menu, "Undo Last Result", #selector(undo), "z")
        add(menu, "Pause NotchOrbitPlus", #selector(togglePause))
        add(menu, "Settings…", #selector(showSettings), ",")
        add(menu, "How to Use NotchOrbitPlus", #selector(showWelcome))
        menu.addItem(.separator())
        add(menu, "Quit NotchOrbitPlus", #selector(quit), "q")
        item.menu = menu
        statusItem = item
        dashboard.onOpenSettings = { [weak self] in self?.showSettings() }
        dashboard.start()
        shortcut.configure(enabled: dashboardPreferences.keyboardShortcutEnabled) { [weak self] in self?.dashboard.toggleExpanded() }

        model.onResults = { [weak self] in self?.showResults() }
        drag = NotchDragMonitor(onActivate: { [weak self] urls, layout in
            guard let self, let generation = self.drag?.activationGeneration else { return }
            // An open shelf is already a genuine file destination; preserve it
            // so its own drop handler can retain/share files instead of transforming them.
            if self.dashboard.isExpanded && self.dashboard.selectedToolID == PlusTool.fileShelf.rawValue { return }
            self.presentActions(urls, layout: layout, dragGeneration: generation)
        }, onCancel: { [weak self] in self?.cancelPresentation() })
        applyPreferences()
        drag?.start()
        updateMonitoringStatus()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if !UserDefaults.standard.bool(forKey: "welcomeSeen") { showWelcome() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        cancelPresentation()
        drag?.stop()
        dashboard.stop()
        shortcut.stop()
        FocusTimerService.shared.shutdown()
        model.cancel()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo) {
            menuItem.toolTip = model.undoHelp
            return model.canUndo
        }
        if menuItem.action == #selector(chooseFiles) {
            return !model.busy && !model.preferences.paused
        }
        if menuItem.action == #selector(togglePause) {
            menuItem.title = model.preferences.paused ? "Resume NotchOrbitPlus" : "Pause NotchOrbitPlus"
        }
        return true
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func presentActions(_ urls: [URL], layout: NotchLayout,
                                dragGeneration: UInt64? = nil, revealChosenFiles: Bool = false) {
        guard !model.preferences.paused, !model.busy else { return }
        cancelPresentation()
        dashboard.setSuspended(true)
        let identifier = UUID()
        presentationID = identifier
        inspectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.presentationID == identifier { self.inspectionTask = nil }
            }
            do {
                let inspection = Task.detached(priority: .userInitiated) { try FileInspector.inspect(urls) }
                let items = try await withTaskCancellationHandler {
                    try await inspection.value
                } onCancel: {
                    inspection.cancel()
                }
                try Task.checkCancellation()
                guard self.presentationID == identifier,
                      !self.model.preferences.paused, !self.model.busy else { return }
                if let generation = dragGeneration {
                    guard self.drag?.isCurrentActivation(generation) == true else { return }
                }
                let actions = ActionResolver.actions(for: items)
                guard !items.isEmpty, !actions.isEmpty else { self.cancelPresentation(); return }

                self.panel.show(items: items, actions: actions, layout: layout,
                    onSelect: { [weak self] action, droppedURLs in
                        guard let self, self.presentationID == identifier,
                              !self.model.preferences.paused, !self.model.busy else { return }
                        guard NotchDragPayload.matches(observed: items.map(\.url), dropped: droppedURLs) else { return }
                        // Only the panel's genuine NSDraggingInfo drop callback
                        // reaches this point; inspection and hover never run actions.
                        self.cancelPresentation()
                        self.drag?.finishDrag()
                        self.model.run(action, urls: droppedURLs)
                    }, onCancel: { [weak self] in
                        self?.cancelPresentation()
                        self?.drag?.finishDrag()
                    })
                if revealChosenFiles { self.model.reveal(urls) }
            } catch is CancellationError {
                // A cancelled drag cannot reopen the panel or show a stale error.
            } catch {
                guard !Task.isCancelled, self.presentationID == identifier else { return }
                if let generation = dragGeneration {
                    guard self.drag?.isCurrentActivation(generation) == true else { return }
                }
                self.model.errorMessage = error.localizedDescription
                self.cancelPresentation()
                self.showResults()
            }
        }
    }

    private func cancelPresentation() {
        presentationID = nil
        inspectionTask?.cancel()
        inspectionTask = nil
        panel.dismiss()
        dashboard.setSuspended(model.preferences.paused)
    }

    func requestAccess() {
        cancelPresentation()
        drag?.requestInputMonitoringAccess()
        drag?.stop()
        drag?.start()
        updateMonitoringStatus()
    }

    func applyPreferences() {
        cancelPresentation()
        // NotchOrbitPlus activation is driven entirely by the file-drag location.
        drag?.paused = model.preferences.paused
        dashboard.setSuspended(model.preferences.paused)
        shortcut.configure(enabled: dashboardPreferences.keyboardShortcutEnabled) { [weak self] in self?.dashboard.toggleExpanded() }
        updateMonitoringStatus()
    }

    private func updateMonitoringStatus() {
        if model.preferences.paused {
            model.monitoringStatus = "NotchOrbitPlus is paused. Resume it from the menu bar to use file actions."
            return
        }
        switch drag?.status {
        case .listening:
            model.monitoringStatus = "Drag detection is active. Bring a file toward the notch or the top center of a display."
        case .inputMonitoringRequired:
            model.monitoringStatus = "Enable Input Monitoring for NotchOrbitPlus in System Settings, then quit and reopen the app. Choose Files also provides a manual drop destination."
        case .eventTapUnavailable:
            model.monitoringStatus = "macOS could not start automatic drag detection. Quit and reopen NotchOrbitPlus, or use Choose Files from the menu bar."
        case .stopped, .none:
            model.monitoringStatus = "Automatic drag detection has not started. Choose Files provides a manual drop destination."
        }
    }

    @objc private func screensChanged() {
        cancelPresentation()
        drag?.finishDrag()
    }

    @objc private func chooseFiles() {
        guard !model.busy, !model.preferences.paused else { return }
        cancelPresentation()
        NSApp.activate(ignoringOtherApps: true)
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.allowsMultipleSelection = true
        chooser.message = "Choose files to reveal in Finder, then drag those files onto a labeled action below the notch or top center."
        guard chooser.runModal() == .OK else { return }
        guard let screen = NotchScreenLayout.screen(at: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first else {
            model.errorMessage = "No display is available for the drop destination."
            showResults()
            return
        }
        presentActions(chooser.urls, layout: NotchScreenLayout.layout(for: screen), revealChosenFiles: true)
    }

    @objc private func togglePause() {
        model.preferences.paused.toggle()
        applyPreferences()
    }
    @objc private func undo() { model.undoLast() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showDashboard() { dashboard.toggleExpanded() }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "NotchOrbitPlus Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PlusSettingsView(model: model,
                dashboardPreferences: dashboardPreferences, requestAccess: requestAccess, applyPreferences: applyPreferences))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showWelcome() {
        if welcomeWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 510),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Welcome to NotchOrbitPlus"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PlusWelcomeView(requestAccess: requestAccess))
            window.center()
            welcomeWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: "welcomeSeen")
    }

    @objc private func showResults() {
        if resultsWindow == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 320),
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "NotchOrbitPlus Results"
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: NotchResultView(model: model))
            resultsWindow = window
        }
        if let screen = NotchScreenLayout.screen(at: NSEvent.mouseLocation) ?? NSScreen.main {
            let visible = screen.visibleFrame
            resultsWindow?.setFrameOrigin(NSPoint(x: max(visible.minX, visible.maxX - 390),
                                                  y: max(visible.minY, visible.maxY - 360)))
        }
        resultsWindow?.orderFrontRegardless()
    }
}
