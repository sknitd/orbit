import SwiftUI
import AppKit
import OrbitCore

@main
struct OrbitDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { SettingsView(model: delegate.model, requestAccess: delegate.requestAccess, applyPreferences: delegate.applyPreferences) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let wheel = WheelController()
    private var drag: DragMonitor?
    private var statusItem: NSStatusItem?
    private var resultsPanel: NSPanel?
    private var welcome: NSWindow?

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
        }, onCancel: { [weak self] in self?.wheel.dismiss() })
        applyPreferences()
        drag?.start()
        updateMonitoringStatus()
        if !UserDefaults.standard.bool(forKey: "welcomeSeen") { showWelcome() }
    }

    func applicationWillTerminate(_ notification: Notification) { drag?.stop(); model.cancel() }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; menu.addItem(item)
    }

    private func presentWheel(_ urls: [URL], at point: NSPoint, advanced: Bool = false) {
        guard !model.preferences.paused, !model.busy else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await Task.detached { try FileInspector.inspect(urls) }.value
                var actions = ActionResolver.actions(for: items)
                if advanced {
                    actions.sort { ($0.category == "Privacy" ? 0 : 1) < ($1.category == "Privacy" ? 0 : 1) }
                }
                guard !actions.isEmpty else { return }
                self.wheel.show(items: items, actions: actions, at: point, onSelect: { [weak self] action, dropped in
                    self?.drag?.finishDrag()
                    self?.model.run(action, urls: dropped)
                }, onCancel: {})
            } catch { self.model.errorMessage = error.localizedDescription; self.showResults() }
        }
    }

    func requestAccess() {
        drag?.requestInputMonitoringAccess()
        drag?.stop(); drag?.start(); updateMonitoringStatus()
    }
    func applyPreferences() {
        drag?.trigger = model.preferences.triggerOption ? [.shift, .option] : [.shift]
        drag?.paused = model.preferences.paused
    }
    private func updateMonitoringStatus() {
        model.monitoringStatus = CGPreflightListenEventAccess() ? "Input Monitoring is available. Drag a file and hold Shift." : "Enable Input Monitoring in System Settings, then quit and reopen OrbitDrop."
    }

    @objc private func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = true; chooser.allowsMultipleSelection = true
        chooser.message = "Choose files, then drag them onto an action in the wheel."
        if chooser.runModal() == .OK { presentWheel(chooser.urls, at: NSEvent.mouseLocation) }
    }
    @objc private func togglePause() {
        model.preferences.paused.toggle(); drag?.paused = model.preferences.paused
        if model.preferences.paused { wheel.dismiss() }
    }
    @objc private func undo() { model.undoLast() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
