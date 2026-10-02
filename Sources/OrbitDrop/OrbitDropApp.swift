import SwiftUI
import AppKit
import OrbitCore

@main
@MainActor
struct OrbitDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { SettingsView(model: delegate.model, requestAccess: delegate.requestAccess, applyPreferences: delegate.applyPreferences) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = AppModel()
    private let wheel = WheelController()
    private var drag: DragMonitor?
    private var statusItem: NSStatusItem?
    private var resultsPanel: NSPanel?
    private var settingsWindow: NSWindow?
    private var welcome: NSWindow?
    private var wheelInspection: Task<Void, Never>?
    private var wheelRequestID: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.dotted.circle", accessibilityDescription: "OrbitDrop")
        let menu = NSMenu()
        menu.addItem(withTitle: "OrbitDrop — Drag. Hold Shift. Drop.", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, "Choose Files…", #selector(chooseFiles), "o")
        add(menu, "Results & Progress", #selector(showResults), "r")
        add(menu, "Undo Last Result", #selector(undo), "z")
        add(menu, "Pause / Resume", #selector(togglePause), "")
        add(menu, "Settings…", #selector(showSettings), ",")
        add(menu, "How to Use OrbitDrop", #selector(showWelcome), "")
        menu.addItem(.separator())
        add(menu, "Quit OrbitDrop", #selector(quit), "q")
        item.menu = menu; statusItem = item
        model.onResults = { [weak self] in self?.showResults() }
        drag = DragMonitor(onActivate: { [weak self] urls, point, advanced in
            guard let self else { return }
            self.presentWheel(urls, at: point, advanced: advanced)
        }, onCancel: { [weak self] in self?.cancelWheelPresentation() })
        applyPreferences()
        drag?.start()
        updateMonitoringStatus()
        if !UserDefaults.standard.bool(forKey: "welcomeSeen") { showWelcome() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelWheelPresentation(); drag?.stop(); model.cancel()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo) {
            menuItem.toolTip = model.undoHelp
            return model.canUndo
        }
        if menuItem.action == #selector(chooseFiles) {
            return !model.busy && !model.preferences.paused
        }
        return true
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; menu.addItem(item)
    }

    private func presentWheel(_ urls: [URL], at point: NSPoint, advanced: Bool = false) {
        guard !model.preferences.paused, !model.busy else { return }
        cancelWheelPresentation()
        let identifier = UUID()
        wheelRequestID = identifier
        wheelInspection = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.wheelRequestID == identifier { self.wheelInspection = nil }
            }
            do {
                let inspection = Task.detached(priority: .userInitiated) { try FileInspector.inspect(urls) }
                let items = try await withTaskCancellationHandler {
                    try await inspection.value
                } onCancel: {
                    inspection.cancel()
                }
                try Task.checkCancellation()
                guard self.wheelRequestID == identifier,
                      !self.model.preferences.paused, !self.model.busy else { return }
                let actions = ActionResolver.actions(for: items)
                guard !actions.isEmpty else { return }
                self.wheel.show(items: items, actions: actions, at: point, preferredCategory: advanced ? "Privacy" : nil, onSelect: { [weak self] action, dropped in
                    guard let self, self.wheelRequestID == identifier else { return }
                    self.cancelWheelPresentation()
                    self.drag?.finishDrag()
                    self.model.run(action, urls: dropped)
                }, onCancel: { [weak self] in
                    self?.cancelWheelPresentation()
                    self?.drag?.finishDrag()
                })
            } catch is CancellationError {
                // A cancelled or superseded drag must not reopen a window.
            } catch {
                guard !Task.isCancelled, self.wheelRequestID == identifier else { return }
                self.model.errorMessage = error.localizedDescription; self.showResults()
            }
        }
    }

    private func cancelWheelPresentation() {
        wheelRequestID = nil
        wheelInspection?.cancel()
        wheelInspection = nil
        wheel.dismiss()
    }

    func requestAccess() {
        cancelWheelPresentation()
        drag?.requestInputMonitoringAccess()
        drag?.stop(); drag?.start(); updateMonitoringStatus()
    }
    func applyPreferences() {
        cancelWheelPresentation()
        drag?.trigger = model.preferences.triggerOption ? [.shift, .option] : [.shift]
        drag?.paused = model.preferences.paused
        updateMonitoringStatus()
    }
    private func updateMonitoringStatus() {
        if model.preferences.paused {
            model.monitoringStatus = "Drag observation is paused. Resume OrbitDrop from the menu bar."
            return
        }
        switch drag?.status {
        case .listening:
            let modifier = model.preferences.triggerOption ? "Shift + Option" : "Shift"
            model.monitoringStatus = "Drag observation is active. Drag a file and hold \(modifier)."
        case .eventTapUnavailable:
            model.monitoringStatus = "macOS could not start drag observation. Quit and reopen OrbitDrop, then check Input Monitoring."
        case .inputMonitoringRequired:
            model.monitoringStatus = "Enable Input Monitoring in System Settings, then quit and reopen OrbitDrop."
        case .stopped, .none:
            model.monitoringStatus = "Drag observation has not started."
        }
    }

    @objc private func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = true; chooser.allowsMultipleSelection = true
        chooser.message = "Choose files, then drag them onto an action in the wheel."
        if chooser.runModal() == .OK { presentWheel(chooser.urls, at: NSEvent.mouseLocation) }
    }
    @objc private func togglePause() {
        model.preferences.paused.toggle(); applyPreferences()
    }
    @objc private func undo() { model.undoLast() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 594, height: 414),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "OrbitDrop Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model,
                requestAccess: requestAccess, applyPreferences: applyPreferences))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func showWelcome() {
        if welcome == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 430),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Welcome to OrbitDrop"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: WelcomeView(model: model, requestAccess: requestAccess))
            window.center(); welcome = window
        }
        NSApp.activate(ignoringOtherApps: true); welcome?.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: "welcomeSeen")
    }
    @objc private func showResults() {
        if resultsPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 290),
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "OrbitDrop"; panel.level = .floating; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: ResultView(model: model))
            if let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 370, y: screen.visibleFrame.maxY - 325))
            }
            resultsPanel = panel
        }
        resultsPanel?.orderFrontRegardless()
    }
}
