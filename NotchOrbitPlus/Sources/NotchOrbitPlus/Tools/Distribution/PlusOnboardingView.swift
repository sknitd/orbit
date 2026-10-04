import AppKit
import ServiceManagement
import SwiftUI
import NotchCore

@MainActor
final class PlusLoginItemService: ObservableObject {
    static let shared = PlusLoginItemService()
    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var requiresApproval = SMAppService.mainApp.status == .requiresApproval
    @Published private(set) var message: String?
    func setEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch { message = error.localizedDescription }
        refresh()
    }
    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
        requiresApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
struct PlusOnboardingView: View {
    let requestAccess: @MainActor () -> Void
    let onFinish: @MainActor ([String]) -> Void
    @State private var step = 0
    @State private var selected = Set(PlusTool.defaultOrder.map(\.rawValue))
    @ObservedObject private var login = PlusLoginItemService.shared
    @ObservedObject private var updates = PlusUpdateService.shared
    init(requestAccess: @escaping @MainActor () -> Void = {}, onFinish: @escaping @MainActor ([String]) -> Void = { _ in }) {
        self.requestAccess = requestAccess; self.onFinish = onFinish
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to NotchOrbitPlus").font(.title2.weight(.semibold))
                    Text("\(step + 1) of 3 · \(["Get started", "Choose your tools", "Access and preferences"][step])")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case 0:
                        Text("Your tools, one notch away.").font(.title3.weight(.semibold))
                        Text("Hover or click the strip below your notch, or press ⌘⌃N. A display without a notch uses its top center.")
                        Label("Drag files toward the notch for conversions and file actions.", systemImage: "doc.badge.arrow.up")
                        Label("Pin the dashboard while you write, read or work.", systemImage: "pin")
                        Text("Start with local tools. Calendar, camera, player control and online services connect only when you explicitly enable them.")
                            .foregroundStyle(.secondary)
                    case 1:
                        Text("Choose what appears in your dashboard. You can change this later in Settings.").foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                            ForEach(PlusTool.defaultOrder, id: \.rawValue) { tool in
                                Toggle(isOn: Binding(get: { selected.contains(tool.rawValue) }, set: { value in
                                    if value { selected.insert(tool.rawValue) } else { selected.remove(tool.rawValue) }
                                })) { Label(tool.title, systemImage: tool.symbol) }
                            }
                        }
                        if selected.isEmpty { Text("Choose at least one tool.").foregroundStyle(.orange) }
                    default:
                        Text("Enable only the access you need.").font(.headline)
                        Button("Enable automatic file-drag detection") { requestAccess() }.buttonStyle(.borderedProminent)
                        Text("This opens Input Monitoring access for file gestures. Other permissions are requested when you use their tools.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Toggle("Launch at login", isOn: Binding(get: { login.enabled }, set: { login.setEnabled($0) }))
                        if login.requiresApproval { Button("Open Login Items Settings") { login.openApprovalSettings() } }
                        if let message = login.message { Text(message).font(.caption).foregroundStyle(.orange) }
                        Toggle("Check for updates automatically every six hours", isOn: $updates.automaticallyCheck)
                        Text("Local tools work without an account. Optional folder sync is configured in Settings; clipboard history and service credentials stay on this Mac. Clipboard observation begins only when you enable it.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Ask Orbit uses Apple Intelligence on eligible Macs with macOS 26. Connected tools keep their own setup controls.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step == 2 ? "Start using NotchOrbitPlus" : "Continue") {
                    if step < 2 { step += 1 }
                    else { onFinish(PlusTool.defaultOrder.map(\.rawValue).filter { selected.contains($0) }) }
                }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            }
        }.padding(24).frame(width: 560, height: 560)
    }
}

@MainActor
struct PlusDistributionSettingsView: View {
    @ObservedObject private var updates = PlusUpdateService.shared
    @ObservedObject private var login = PlusLoginItemService.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Startup and updates", systemImage: "arrow.triangle.2.circlepath").font(.title2.weight(.semibold))
                Text("NotchOrbitPlus \(updates.currentVersion)").foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: Binding(get: { login.enabled }, set: { login.setEnabled($0) }))
                if login.requiresApproval { Button("Approve in Login Items Settings") { login.openApprovalSettings() } }
                if let message = login.message { Text(message).foregroundStyle(.orange).font(.caption) }
                Divider()
                Toggle("Automatically check every six hours", isOn: $updates.automaticallyCheck)
                Toggle("Automatically download checksum-verified updates", isOn: $updates.automaticallyDownload)
                    .disabled(!updates.automaticallyCheck)
                Toggle("Automatically install trusted, notarized updates", isOn: $updates.automaticallyInstall)
                    .disabled(!updates.automaticallyCheck || !updates.automaticallyDownload || !updates.trustedInstallationAvailable)
                if !updates.trustedInstallationAvailable {
                    Text("This build is not Developer ID signed. Checks and verified downloads work; automatic installation requires a trusted Developer ID build.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(updates.status).textSelection(.enabled)
                if updates.working { ProgressView(value: updates.progress); Button("Cancel") { updates.cancel() } }
                HStack {
                    Button("Check for Updates") { updates.check() }.disabled(updates.working)
                    if updates.available != nil {
                        Button("Download Update") { updates.download() }.disabled(updates.working)
                    }
                    if let file = updates.downloadedArchive {
                        Button("Show Download") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        Button("Install and Relaunch") { updates.install() }
                            .disabled(updates.working || !updates.trustedInstallationAvailable)
                    }
                }
                if let feed = updates.available { Link("Build source and release notes", destination: feed.releaseNotesURL) }
                if let date = updates.lastChecked { Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                Text("The public GitHub channel supplies version, source and SHA-256. Installation verifies Apple’s Developer ID signature against this running app’s Team ID. Automatic installation also requires Apple’s notarized-app assessment.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { login.refresh() }
    }
}
