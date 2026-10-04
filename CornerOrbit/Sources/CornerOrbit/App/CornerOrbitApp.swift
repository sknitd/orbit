import AppKit
import SwiftUI
import CornerCore

@main
enum CornerOrbitApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = CornerAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class CornerAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: CornerAppStore?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var websitePopover: NSPopover?
    private var monitoringItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted fixtures construct isolated stores. Never start a second live
        // store, file connection, permission request or observer in the host.
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let smoke = CommandLine.arguments.contains("--smoke")
        let model = smoke ? CornerAppStore.preview(settings: .defaults) : CornerAppStore.live()
        store = model
        model.onOpenSettings = { [weak self] page in self?.showSettings(page: page) }
        model.onShowWebsites = { [weak self] source, _ in self?.showWebsites(source) }
        model.onNotice = { [weak self] notice in self?.statusItem?.button?.toolTip = "CornerOrbit — \(notice)" }
        installEditingMenu()
        installMenu()
        guard !smoke else { return }
        model.resume()
        if model.settingsNeedRecovery { showSettings(page: .about) }
        else if Corner.allCases.allSatisfy({ corner in CornerGesture.allCases.allSatisfy { model.action(corner: corner, gesture: $0).kind == .none } }) {
            showSettings(page: .corners)
        }
    }
    private func installEditingMenu() {
        let main = NSMenu()
        let appEntry = NSMenuItem(); let appMenu = NSMenu(title: "CornerOrbit")
        appMenu.addItem(withTitle: "Quit CornerOrbit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appEntry.submenu = appMenu; main.addItem(appEntry)
        let editEntry = NSMenuItem(); let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] { editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        editEntry.submenu = editMenu; main.addItem(editEntry); NSApp.mainMenu = main
    }
    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "CornerOrbit")
        item.button?.toolTip = "CornerOrbit — corner gestures"
        item.button?.setAccessibilityLabel("CornerOrbit menu")
        let menu = NSMenu(); menu.delegate = self
        let settings = NSMenuItem(title: "CornerOrbit Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let toggle = NSMenuItem(title: "Enable Gestures…", action: #selector(toggleMonitoring), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle); monitoringItem = toggle
        menu.addItem(.separator())
        for (title, selector) in [("Chrome History…", #selector(openChromeHistory)), ("Recent Websites…", #selector(openRecentWebsites))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit CornerOrbit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu; statusItem = item
    }
    func menuWillOpen(_ menu: NSMenu) {
        monitoringItem?.title = store?.monitor.isEnabled == true ? "Pause Gestures" : "Enable Gestures…"
        monitoringItem?.isEnabled = store?.isPreview == false && store?.settingsNeedRecovery == false
    }
    @objc private func openSettings() { showSettings(page: store?.page ?? .corners) }
    @objc private func toggleMonitoring() {
        guard let store else { return }
        store.setMonitoring(!store.monitor.isEnabled)
        if !store.monitor.isEnabled { showSettings(page: .behavior) }
    }
    @objc private func openChromeHistory() { store?.perform(CornerAction(kind: .chromeHistory)) }
    @objc private func openRecentWebsites() { store?.perform(CornerAction(kind: .recentWebsites)) }
    @objc private func quitApp() { NSApp.terminate(nil) }

    private func showSettings(page: CornerSettingsPage) {
        guard let store else { return }
        websitePopover?.close(); store.page = page
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "CornerOrbit"; window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 820, height: 640)
            window.contentView = NSHostingView(rootView: CornerSettingsView(store: store))
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func showWebsites(_ source: CornerWebsiteSource) {
        guard let store, let button = statusItem?.button else { return }
        websitePopover?.close()
        let chrome = source == .chrome
        let view = WebsiteDropdownView(entries: chrome ? store.history.entries : store.recent.entries,
                                       title: chrome ? "Chrome History" : "Recent Websites", onOpen: { [weak self] entry in
            self?.websitePopover?.close(); self?.store?.openWebsite(entry)
        }, onSettings: { [weak self] in self?.showSettings(page: .history) })
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: view)
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        websitePopover = popover
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(page: store?.page ?? .corners); return true
    }
    func applicationWillTerminate(_ notification: Notification) { store?.shutdown(); websitePopover?.close() }
}
