import Combine
import ServiceManagement

enum CornerLoginStatus: Equatable, Sendable { case notRegistered, enabled, requiresApproval, notFound }
@MainActor
protocol CornerLoginBackend: AnyObject {
    var status: CornerLoginStatus { get }
    func register() throws
    func unregister() throws
    func openApprovalSettings()
}
@MainActor
private final class CornerSystemLoginBackend: CornerLoginBackend {
    var status: CornerLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
}
@MainActor
final class CornerLaunchAtLoginService: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var statusMessage = "Launch at login is off."
    @Published private(set) var errorMessage: String?
    let isPreview: Bool
    private let backend: (any CornerLoginBackend)?
    init(preview: Bool = false, backend: (any CornerLoginBackend)? = nil) {
        isPreview = preview; self.backend = preview ? nil : backend ?? CornerSystemLoginBackend()
        refresh()
    }
    func refresh() {
        guard let backend else { return }
        let status = backend.status; enabled = status == .enabled; requiresApproval = status == .requiresApproval
        switch status {
        case .notRegistered: statusMessage = "Launch at login is off."
        case .enabled: statusMessage = "macOS will open CornerOrbit when you log in."
        case .requiresApproval: statusMessage = "macOS requires approval in Login Items before launch at login can work."
        case .notFound: statusMessage = "macOS could not find this app for launch at login. Install it in Applications and try again."
        }
    }
    func setEnabled(_ value: Bool) async {
        guard !isPreview, let backend else { return }
        do {
            let status = backend.status
            if value && status != .enabled && status != .requiresApproval { try backend.register() }
            else if !value && (status == .enabled || status == .requiresApproval) { try backend.unregister() }
            errorMessage = nil; refresh()
        } catch { errorMessage = "Launch at login could not be changed: \(error.localizedDescription)"; refresh() }
    }
    func openApprovalSettings() { guard !isPreview else { return }; backend?.openApprovalSettings() }
}
