import AppKit

@MainActor
protocol CornerProfileContextSource: AnyObject {
    var currentBundleID: String? { get }
    func start(_ onChange: @escaping @MainActor (String?) -> Void)
    func stop()
}
private final class CornerProfileWorkspaceObservation: @unchecked Sendable {
    let token: any NSObjectProtocol
    let center: NotificationCenter
    init(token: any NSObjectProtocol, center: NotificationCenter) { self.token = token; self.center = center }
    deinit { center.removeObserver(token) }
}
@MainActor
final class CornerWorkspaceProfileContext: CornerProfileContextSource {
    private var observation: CornerProfileWorkspaceObservation?
    var currentBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    func start(_ onChange: @escaping @MainActor (String?) -> Void) {
        guard observation == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    let identifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                    onChange(identifier)
                }
            }
        observation = .init(token: token, center: center)
    }
    func stop() { observation = nil }
}
