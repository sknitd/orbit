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
    }
    static func dismantleNSView(_ view: OrbitNativeVisibilityView, coordinator: ()) {
        view.hiddenAction?()
        NotificationCenter.default.removeObserver(view)
    }
}

@MainActor
final class OrbitNativeVisibilityView: NSView {
    var visibleAction: (() -> Void)?
    var hiddenAction: (() -> Void)?
    private var wasVisible: Bool?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(checkVisibility), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(hidden), name: NSWindow.willCloseNotification, object: window)
        }
        checkVisibility()
    }
    @objc private func hidden() { wasVisible = false; hiddenAction?() }
    @objc private func checkVisibility() {
        let visible = window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        guard visible != wasVisible else { return }
        wasVisible = visible
        if visible { visibleAction?() } else { hiddenAction?() }
    }
}
