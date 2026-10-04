#if os(macOS)
import AppKit
import Combine
import NotchCore
import SwiftUI

@MainActor
private final class DashboardWindow: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

@MainActor
private final class DashboardTrackingView: NSView {
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    private var area: NSTrackingArea?
    override var isOpaque: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let newArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(newArea); area = newArea
    }
    override func mouseEntered(with event: NSEvent) { entered?() }
    override func mouseExited(with event: NSEvent) { exited?() }
}

/// Hosts injected native tools; all feature data and operations belong to the
/// corresponding provider views. Hovering never starts a file transformation.
@MainActor
public final class NotchDashboardController {
    public let preferences: DashboardPreferences
    public var onOpenSettings: (@MainActor () -> Void)?
    private let modules: [NotchDashboardModule]
    private let compactContent: @MainActor () -> AnyView
    private let presentation = DashboardPresentation()
    private var panel: DashboardWindow?
    private var hosting: NSHostingView<NotchDashboardView>?
    private var screenID: UInt32?
    private var screenObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var preferenceObserver: AnyCancellable?
    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?
    private var started = false
    private var suspended = false
    private var wantsVisible = false
    private var hoverSuppressedUntilExit = false
    private var lastDisplaySelection: String

    public var isExpanded: Bool { panel?.isVisible == true && presentation.expanded }
    /// Hidden/suspended dashboard has no active on-screen frame.
    public var frame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }
    public var selectedToolID: String? {
        visibleModules.first { $0.id == presentation.selectedToolID }?.id ?? visibleModules.first?.id
    }
    public var selectedToolTitle: String? { visibleModules.first { $0.id == selectedToolID }?.title }

    public init(modules: [NotchDashboardModule], preferences: DashboardPreferences = DashboardPreferences(),
                compactContent: @escaping @MainActor () -> AnyView = {
                    AnyView(Label("NotchOrbitPlus", systemImage: "rectangle.topthird.inset.filled")
                        .font(.system(size: 11, weight: .medium)))
                }) {
        var seen = Set<String>()
        self.modules = modules.filter { seen.insert($0.id).inserted }
        self.preferences = preferences; self.compactContent = compactContent
        lastDisplaySelection = preferences.displaySelection
        preferences.register(self.modules.map { .init(id: $0.id, title: $0.title, symbol: $0.symbol) })
        presentation.selectedToolID = visibleModules.first?.id
    }

    public func start() {
        guard !started else { return }
        started = true
        if preferenceObserver == nil { installObservers() }
        show()
    }

    public func show(on screen: NSScreen? = nil, expanded: Bool = false) {
        wantsVisible = true
        guard !suspended, let target = screen ?? preferredScreen() else { return }
        cancelHoverTasks()
        hoverSuppressedUntilExit = false
        if preferenceObserver == nil { installObservers() }
        screenID = NotchScreenLayout.screenID(for: target)
        presentation.expanded = expanded
        presentation.openedManually = expanded
        reconcileSelection()
        if panel == nil { makePanel() }
        guard layout(on: target, animated: false) else { return }
        panel?.orderFrontRegardless()
    }

    public func toggleExpanded() {
        guard !suspended else { return }
        if isExpanded { collapse() }
        else {
            if panel?.isVisible != true { show(expanded: true) }
            else { expand(manually: true) }
            panel?.makeKey()
        }
    }

    @discardableResult
    public func selectTool(id: String) -> Bool {
        guard visibleModules.contains(where: { $0.id == id }) else { return false }
        presentation.selectedToolID = id
        return true
    }

    public func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        cancelHoverTasks()
        if value {
            presentation.expanded = false; presentation.openedManually = false; presentation.pinned = false
            panel?.orderOut(nil)
        } else if wantsVisible { show() }
    }

    public func dismiss() {
        wantsVisible = false
        cancelHoverTasks()
        presentation.expanded = false; presentation.openedManually = false; presentation.pinned = false
        panel?.orderOut(nil)
    }

    public func stop() {
        dismiss()
        started = false
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        screenObserver = nil; accessibilityObserver = nil; keyObserver = nil
        preferenceObserver?.cancel(); preferenceObserver = nil
        panel?.contentView = nil; hosting = nil; panel = nil
    }

    /// Native evaluation captures this application's real rendered tool view.
    /// Call again after a run-loop turn when selecting a new tool for capture.
    func evaluationPNG(toolID: String? = nil) -> Data? {
        guard !suspended else { return nil }
        if let toolID, !selectTool(id: toolID) { return nil }
        if panel?.isVisible != true { show(expanded: true) }
        else if !presentation.expanded { expand(manually: true) }
        guard let view = panel?.contentView else { return nil }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private var visibleModules: [NotchDashboardModule] {
        preferences.orderedTools.compactMap { tool in
            modules.first { $0.id == tool.id && !preferences.hiddenToolIDs.contains(tool.id) }
        }
    }
    private func reconcileSelection() {
        if !visibleModules.contains(where: { $0.id == presentation.selectedToolID }) {
            presentation.selectedToolID = visibleModules.first?.id
        }
    }
    private func preferredScreen() -> NSScreen? {
        if preferences.displaySelection == "pointer", let screen = NotchScreenLayout.screen(at: NSEvent.mouseLocation) { return screen }
        if preferences.displaySelection.hasPrefix("id:"),
           let number = UInt32(preferences.displaySelection.dropFirst(3)),
           let screen = NotchScreenLayout.screen(id: number) { return screen }
        return NSScreen.screens.first ?? NSScreen.main
    }
    private func currentScreen() -> NSScreen? {
        screenID.flatMap { NotchScreenLayout.screen(id: $0) } ?? preferredScreen()
    }
    private func makePanel() {
        let window = DashboardWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.hidesOnDeactivate = false; window.isFloatingPanel = true; window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.setAccessibilityLabel("NotchOrbitPlus dashboard")
        window.onEscape = { [weak self] in self?.collapse() }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                            object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.presentation.expanded else { return }
                self.presentation.openedManually = true
            }
        }
        let tracking = DashboardTrackingView(frame: .zero)
        tracking.entered = { [weak self] in self?.pointerEntered() }
        tracking.exited = { [weak self] in self?.pointerExited() }
        let view = NotchDashboardView(presentation: presentation, preferences: preferences, modules: modules,
                                     compactContent: compactContent, toggleExpanded: { [weak self] in self?.toggleExpanded() },
                                     collapse: { [weak self] in self?.collapse() }, openSettings: { [weak self] in self?.onOpenSettings?() })
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]; hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        tracking.addSubview(hosting)
        window.contentView = tracking
        self.hosting = hosting; panel = window
    }
    @discardableResult
    private func layout(on screen: NSScreen, animated: Bool) -> Bool {
        guard let panel else { return false }
        let notch = NotchScreenLayout.layout(for: screen)
        let visible = screen.visibleFrame
        let wantedWidth = presentation.expanded ? preferences.width : max(240, min(340, (notch.notchRect?.width ?? 180) + 44))
        let width = max(0, min(wantedWidth, visible.width - 24))
        let height = max(0, min(presentation.expanded ? 440 : 36, notch.anchor.y - visible.minY - 12))
        guard width >= 120, height >= 24 else { panel.orderOut(nil); return false }
        let x = max(visible.minX + 12, min(notch.anchor.x - width / 2, visible.maxX - 12 - width))
        let frame = NSRect(x: x, y: notch.anchor.y - height, width: width, height: height)
        presentation.width = width; presentation.height = height
        panel.setFrame(frame, display: true, animate: animated && !presentation.reduceMotion)
        hosting?.frame = NSRect(origin: .zero, size: frame.size)
        return true
    }
    private func expand(manually: Bool) {
        guard !suspended, let screen = currentScreen() else { return }
        hoverOpenTask?.cancel(); hoverOpenTask = nil
        hoverCloseTask?.cancel(); hoverCloseTask = nil
        presentation.expanded = true; presentation.openedManually = manually
        reconcileSelection()
        layout(on: screen, animated: true)
        // Hover intentionally does not make the panel key or activate the app.
    }
    private func collapse() {
        cancelHoverTasks()
        presentation.expanded = false; presentation.openedManually = false; presentation.pinned = false
        if let screen = currentScreen(), panel?.isVisible == true { layout(on: screen, animated: true) }
        hoverSuppressedUntilExit = panel?.frame.contains(NSEvent.mouseLocation) == true
        panel?.resignKey()
    }
    private func pointerEntered() {
        hoverCloseTask?.cancel(); hoverCloseTask = nil
        guard !suspended, !hoverSuppressedUntilExit, preferences.openMode == .hoverAndClick, !presentation.expanded else { return }
        hoverOpenTask?.cancel()
        let delay = preferences.hoverDelay
        hoverOpenTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !self.suspended, self.panel?.isVisible == true,
                  self.preferences.openMode == .hoverAndClick else { return }
            self.hoverOpenTask = nil
            self.expand(manually: false)
        }
    }
    private func pointerExited() {
        hoverSuppressedUntilExit = false
        hoverOpenTask?.cancel(); hoverOpenTask = nil
        guard presentation.expanded, !presentation.pinned, !presentation.openedManually else { return }
        hoverCloseTask?.cancel()
        hoverCloseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(320)) } catch { return }
            guard let self, !self.presentation.pinned, !self.presentation.openedManually,
                  self.panel?.attachedSheet == nil,
                  !(self.panel?.firstResponder is NSTextView) else { return }
            self.hoverCloseTask = nil
            self.collapse()
        }
    }
    private func cancelHoverTasks() {
        hoverOpenTask?.cancel(); hoverCloseTask?.cancel(); hoverOpenTask = nil; hoverCloseTask = nil
    }
    private func installObservers() {
        preferenceObserver = preferences.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcileSelection()
                self.cancelHoverTasks()
                if self.wantsVisible, !self.suspended {
                    let displayChanged = self.lastDisplaySelection != self.preferences.displaySelection
                    self.lastDisplaySelection = self.preferences.displaySelection
                    guard let screen = displayChanged ? self.preferredScreen() : self.currentScreen() else { self.dismiss(); return }
                    self.screenID = NotchScreenLayout.screenID(for: screen)
                    self.layout(on: screen, animated: false)
                }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.wantsVisible, !self.suspended, let screen = self.currentScreen() else { return }
                self.screenID = NotchScreenLayout.screenID(for: screen)
                self.layout(on: screen, animated: false)
            }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.presentation.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    self?.presentation.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                }
            }
    }
}
#endif
