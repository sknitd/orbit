import AppKit
import SwiftUI

/// Tracks actual retained-panel visibility without treating a picker/selection
/// overlay as a hidden tool. Continuous capture still stops on orderOut/Spaces.
@MainActor
struct CaptureToolVisibility: NSViewRepresentable {
    let onVisible: () -> Void
    let onHidden: () -> Void
    func makeNSView(context: Context) -> CaptureVisibilityView {
        let view = CaptureVisibilityView()
        view.visibleAction = onVisible; view.hiddenAction = onHidden
        return view
    }
    func updateNSView(_ view: CaptureVisibilityView, context: Context) {
        view.visibleAction = onVisible; view.hiddenAction = onHidden
        view.checkVisibility()
    }
    static func dismantleNSView(_ view: CaptureVisibilityView, coordinator: ()) {
        view.dismantle()
    }
}

@MainActor
final class CaptureVisibilityView: NSView {
    var visibleAction: (() -> Void)?
    var hiddenAction: (() -> Void)?
    private var observedVisible: Bool?
    private var deliveredVisible: Bool?
    private var visibilityTimer: Timer?
    private var delivery: Task<Void, Never>?
    private var revision = UUID()
    private var isDismantled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard !isDismantled else { return }
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(checkVisibility),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosing),
                name: NSWindow.willCloseNotification, object: window)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(checkVisibility),
                name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            // Hidden ancestors can change without a window notification.
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkVisibility() }
            }
            RunLoop.main.add(timer, forMode: .common)
            visibilityTimer = timer
        }
        checkVisibility()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        checkVisibility()
    }
    func stopObserving() {
        visibilityTimer?.invalidate(); visibilityTimer = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    /// SwiftUI may call dismantle while its graph has an exclusive mutation.
    /// Queue the final stop after that stack unwinds and permanently reject revival.
    func dismantle() {
        guard !isDismantled else { return }
        isDismantled = true
        stopObserving()
        enqueueVisibility(false, force: true)
    }
    @objc private func windowClosing() { enqueueVisibility(false) }
    @objc func checkVisibility() {
        guard !isDismantled else { return }
        enqueueVisibility(actualVisibility)
    }
    private var actualVisibility: Bool {
        !isDismantled && window?.isVisible == true && window?.isOnActiveSpace == true && !isHiddenOrHasHiddenAncestor
    }
    private func enqueueVisibility(_ visible: Bool, force: Bool = false) {
        guard observedVisible != visible || force else { return }
        observedVisible = visible
        let token = UUID(); revision = token
        delivery?.cancel()
        // A strong reference keeps the final hidden callback alive through teardown.
        // Cancellation/revision checks discard obsolete visible notifications.
        delivery = Task { @MainActor [self] in
            await Task.yield()
            guard !Task.isCancelled, revision == token else { return }
            delivery = nil
            let current = actualVisibility
            observedVisible = current
            guard deliveredVisible != current || force else { return }
            deliveredVisible = current
            if current { visibleAction?() } else { hiddenAction?() }
        }
    }
}
