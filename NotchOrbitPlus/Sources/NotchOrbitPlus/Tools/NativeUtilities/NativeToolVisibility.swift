import SwiftUI
import AppKit

/// Stops sampling/capture when the containing panel is ordered out, even when
/// its SwiftUI content remains retained and onDisappear is not delivered.
@MainActor
struct OrbitNativeToolVisibility: NSViewRepresentable {
    let onVisible: () -> Void
    let onHidden: () -> Void
    func makeNSView(context: Context) -> OrbitNativeVisibilityView {
        let view = OrbitNativeVisibilityView()
        view.visibleAction = onVisible; view.hiddenAction = onHidden
        return view
    }
    func updateNSView(_ view: OrbitNativeVisibilityView, context: Context) {
        view.visibleAction = onVisible; view.hiddenAction = onHidden
        view.checkVisibility()
    }
    static func dismantleNSView(_ view: OrbitNativeVisibilityView, coordinator: ()) {
        view.dismantle()
    }
}

@MainActor
final class OrbitNativeVisibilityView: NSView {
    var visibleAction: (() -> Void)?
    var hiddenAction: (() -> Void)?
    private var wasVisible: Bool?
    private var delivery: Task<Void, Never>?
    private var generation = UUID()
    private var dismantled = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !dismantled else { return }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(checkVisibility), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(hidden), name: NSWindow.willCloseNotification, object: window)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(checkVisibility), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        }
        checkVisibility()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        checkVisibility()
    }
    func dismantle() {
        guard !dismantled else { return }
        dismantled = true; generation = UUID()
        delivery?.cancel(); delivery = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        let action = hiddenAction
        visibleAction = nil; hiddenAction = nil
        // Publishing from dismantle re-enters SwiftUI's graph invalidation.
        // Deliver after that synchronous transaction has unwound.
        Task { @MainActor in action?() }
    }
    @objc private func hidden() { enqueue(false) }
    @objc func checkVisibility() {
        let visible = window?.isVisible == true && window?.isOnActiveSpace == true
            && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        enqueue(visible)
    }
    private func enqueue(_ visible: Bool) {
        guard !dismantled else { return }
        guard visible != wasVisible else { return }
        wasVisible = visible
        delivery?.cancel()
        let token = UUID(); generation = token
        delivery = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, !dismantled, generation == token else { return }
            delivery = nil
            if visible { visibleAction?() } else { hiddenAction?() }
        }
    }
}
