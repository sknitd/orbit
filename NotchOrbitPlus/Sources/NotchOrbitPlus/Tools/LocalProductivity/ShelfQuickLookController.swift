import AppKit
import QuickLookUI

/// Owns a real shared Quick Look panel for one shelf item. The responder-chain
/// adapter and security access are restored when control ends or the app quits.
@MainActor
final class ShelfQuickLookController: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private(set) var previewURLs: [URL] = []
    private(set) var currentItemID: UUID?
    private weak var ownerWindow: NSWindow?
    private weak var previousResponder: NSResponder?
    private weak var controlledPanel: QLPreviewPanel?
    private var scopedURLs: [URL] = []
    private var closing = false

    deinit { for url in scopedURLs { url.stopAccessingSecurityScopedResource() } }

    func show(url: URL, itemID: UUID, ownerWindow suppliedWindow: NSWindow? = nil) throws {
        let host = (url.host ?? "").lowercased()
        guard url.isFileURL, host.isEmpty || host == "localhost",
              FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        // A second preview can be requested while Quick Look is key. Attach to
        // its original host window, never to the preview panel's own chain.
        let candidates = [suppliedWindow, ownerWindow, NSApp.keyWindow, NSApp.mainWindow]
        guard let window = candidates.compactMap({ $0 }).first(where: { !($0 is QLPreviewPanel) }) ??
                NSApp.windows.first(where: { $0.isVisible && !($0 is QLPreviewPanel) }) else {
            throw NSError(domain: "NotchOrbitPlus.QuickLook", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Open the File Shelf dashboard before previewing a file."])
        }
        guard let panel = QLPreviewPanel.shared() else {
            throw NSError(domain: "NotchOrbitPlus.QuickLook", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The macOS Quick Look panel is unavailable."])
        }
        close()
        previewURLs = [url]
        currentItemID = itemID
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        ownerWindow = window
        previousResponder = window.nextResponder
        nextResponder = window.nextResponder
        window.nextResponder = self
        controlledPanel = panel
        panel.updateController()
        // updateController normally invokes beginPreviewPanelControl through
        // the window's responder chain. Assign explicitly for a non-key host.
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func close(ifShowing itemID: UUID? = nil) {
        guard itemID == nil || itemID == currentItemID, !closing else { return }
        closing = true
        let panel = controlledPanel
        if let panel, panel.dataSource === self {
            panel.orderOut(nil)
            panel.dataSource = nil
            panel.delegate = nil
        }
        releaseControl()
        panel?.updateController()
        closing = false
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !previewURLs.isEmpty }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard let panel, !previewURLs.isEmpty else { return }
        controlledPanel = panel
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if let panel, panel.dataSource === self {
            panel.dataSource = nil
            panel.delegate = nil
        }
        releaseControl()
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as NSURL
    }
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? QLPreviewPanel, panel === controlledPanel else { return }
        close()
    }
    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? QLPreviewPanel, panel === controlledPanel, !panel.isVisible else { return }
        close()
    }
    private func releaseControl() {
        if let window = ownerWindow, window.nextResponder === self { window.nextResponder = previousResponder }
        nextResponder = nil
        ownerWindow = nil
        previousResponder = nil
        controlledPanel = nil
        previewURLs.removeAll()
        currentItemID = nil
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }
}
