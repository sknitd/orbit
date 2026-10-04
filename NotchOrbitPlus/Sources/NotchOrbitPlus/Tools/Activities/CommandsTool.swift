import AppKit
import SwiftUI
import NotchCore

@MainActor
final class CommandsService: ObservableObject {
    static let shared = CommandsService()
    @Published private(set) var enabled = false
    @Published var backgroundMonitoring = false { didSet { reconcile() } }
    @Published private(set) var activities: [CommandActivity] = []
    @Published private(set) var error: String?
    @Published private(set) var status = "Command activity tracking is disabled."
    @Published private(set) var isListening = false
    var latestActive: CommandActivity? { activities.first { $0.state == .running } }
    var liveStatuses: [LiveNotchStatus] {
        guard enabled else { return [] }
        return Array(activities.filter { $0.state != .interrupted }.prefix(5)).map { activity in
            let detail = activity.state == .running ? "Running · Result pending" : "Exit \(activity.exitCode.map(String.init) ?? "unknown") · \(activity.duration.map { String(format: "%.2f s", $0) } ?? "Duration unknown")"
            return .init(id: "command:\(activity.id.uuidString)", kind: .command, title: activity.label, detail: detail, toolID: "commands")
        }
    }
    var socketURL: URL { CommandSocketListener.endpoint }
    var helperDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchOrbitPlus/CLI", isDirectory: true)
    }
    var shellSnippet: String { "\(CommandHelpers.shellQuote(helperDirectory.appendingPathComponent("orbit-run").path)) --label 'Build' -- /usr/bin/xcrun swift build" }
    var xcodeSnippet: String { "# Xcode Run Script phase: replace swift build with the command this phase runs.\n" + shellSnippet }
    private var visible = false
    private var listener: CommandSocketListener?
    private var generation = UUID()
    private var tracker = CommandActivityTracker()
    func enable() { enabled = true; reconcile() }
    func disable() { enabled = false; reconcile() }
    func resume() { visible = true; reconcile() }
    func stop() { visible = false; reconcile() }
    func shutdown() { visible = false; enabled = false; backgroundMonitoring = false; reconcile() }
    func clearRetained() { tracker.clearRetained(); activities = tracker.activities }
    func installHelpers() {
        do { try CommandHelpers.install(in: helperDirectory); status = "Installed orbit-notify and orbit-run. Python 3 is required; PATH was not changed."; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func reconcile() {
        guard enabled, visible || backgroundMonitoring else {
            generation = UUID(); listener?.stop(); listener = nil; isListening = false
            tracker.pause(); activities = tracker.activities
            status = enabled ? "Tracking paused while the dashboard is closed." : "Command activity tracking is disabled."
            return
        }
        guard listener == nil else { return }
        let token = UUID(); generation = token
        let owner = self
        do {
            listener = try CommandSocketListener(receive: { bytes in
                Task { @MainActor [owner] in
                    guard owner.generation == token, owner.isListening else { return }
                    do {
                        let message = try CommandActivityMessage.decode(bytes)
                        try owner.tracker.accept(message); owner.activities = owner.tracker.activities
                        owner.error = nil
                    } catch { owner.error = error.localizedDescription }
                }
            }, failure: { message in Task { @MainActor [owner] in if owner.generation == token { owner.error = message } } })
            isListening = true; status = "Listening for local activity metadata. Incoming messages cannot run commands."; error = nil
        } catch { self.error = error.localizedDescription; isListening = false }
    }
}
@MainActor
struct CommandsToolView: View {
    @ObservedObject private var service: CommandsService
    init(service: CommandsService = .shared) { self.service = service }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Command activities", systemImage: "terminal").font(.headline)
            HStack { Button(service.enabled ? "Disable" : "Enable") { if service.enabled { service.disable() } else { service.enable() } }; Button("Install User Helpers", action: service.installHelpers); Spacer(); Button("Clear Retained", action: service.clearRetained) }
            Toggle("Listen while dashboard is closed", isOn: Binding(get: { service.backgroundMonitoring }, set: { service.backgroundMonitoring = $0 })).disabled(!service.enabled)
            Text(service.status).font(.caption).foregroundStyle(.secondary)
            if !service.activities.isEmpty {
                List(service.activities) { activity in
                    VStack(alignment: .leading) {
                        Text(activity.label).lineLimit(1)
                        Text(description(activity)).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(height: 180)
            }
            Text("Helpers are installed only in your Application Support directory. They require Python 3. Incoming socket messages contain labels and results only; only your explicit orbit-run invocation starts your supplied command.").font(.caption).foregroundStyle(.secondary)
            Text(service.shellSnippet).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy Shell Example") { copy(service.shellSnippet) }
                Button("Copy Xcode Phase Example") { copy(service.xcodeSnippet) }
            }
            Text("Hiding pauses the listener unless background listening is enabled. Running entries become tracking-interrupted, without claiming an exit code. Disable never stops your process.").font(.caption).foregroundStyle(.secondary)
            LocalToolError(message: service.error)
        }.onAppear { service.resume() }.onDisappear { service.stop() }
            .background(OrbitNativeToolVisibility(onVisible: service.resume, onHidden: service.stop).frame(width: 0, height: 0))
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func description(_ value: CommandActivity) -> String {
        switch value.state {
        case .running: return "Running · Started \(value.startedAt.formatted(date: .omitted, time: .standard))"
        case .interrupted: return "Tracking interrupted · Exit result unknown"
        case .succeeded, .failed:
            return "Exit \(value.exitCode.map(String.init) ?? "unknown") · \(value.duration.map { String(format: "%.2f s", $0) } ?? "Duration unknown")"
        }
    }
}
