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
        view.stopObserving()
        view.hiddenAction?()
    }
}

@MainActor
final class CaptureVisibilityView: NSView {
    var visibleAction: (() -> Void)?
    var hiddenAction: (() -> Void)?
    private var wasVisible: Bool?
    private var visibilityTimer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
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
    @objc private func windowClosing() {
        wasVisible = false; hiddenAction?()
    }
    @objc func checkVisibility() {
        let visible = window?.isVisible == true && window?.isOnActiveSpace == true && !isHiddenOrHasHiddenAncestor
        guard visible != wasVisible else { return }
        wasVisible = visible
        if visible { visibleAction?() } else { hiddenAction?() }
    }
}
