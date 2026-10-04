import Foundation

/// Clipboard's lazy singleton remains off until the user explicitly opts in.
/// Shelf expiry continues independently of which dashboard tool is visible.
@MainActor
enum LocalProductivityLifecycle {
    static func start() { FileShelfToolStore.shared.pruneExpired() }
    static func shutdown() {
        ClipboardToolStore.shutdownIfInitialized()
        FileShelfToolStore.shutdownIfInitialized()
    }
}
