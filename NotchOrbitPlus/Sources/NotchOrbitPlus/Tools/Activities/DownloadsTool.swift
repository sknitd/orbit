import AppKit
import SwiftUI
import NotchCore

enum DownloadFolderReader {
    static func read(_ folder: URL) throws -> [DownloadFileObservation] {
        try Task.checkCancellation()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        guard files.count <= 2_048 else { throw CommandActivityError.invalid("This folder has more than 2,048 visible entries; choose a smaller tracking folder.") }
        return try files.compactMap { url in
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true || (values.isDirectory == true && url.pathExtension.lowercased() == "download") else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return .init(url: url, identity: String(describing: attributes[.systemFileNumber] ?? url.path),
                         bytes: values.isRegularFile == true ? values.fileSize.map(Int64.init) : nil,
                         modifiedAt: values.contentModificationDate ?? .distantPast, isDirectory: values.isDirectory == true)
        }
    }
}
@MainActor
final class DownloadsService: ObservableObject {
    static let shared = DownloadsService()
    @Published private(set) var enabled = false
    @Published var backgroundMonitoring = false { didSet { reconcile() } }
    @Published private(set) var folderURL: URL?
    @Published private(set) var activities: [DownloadActivity] = []
    @Published private(set) var error: String?
    @Published private(set) var isSampling = false
    var latestActive: DownloadActivity? { activities.first { $0.state == .active } }
    var liveStatuses: [LiveNotchStatus] {
        guard enabled else { return [] }
        return Array(activities.filter { $0.state == .active || $0.state == .completed }.prefix(5)).map { activity in
            let bytes = activity.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unknown"
            let eta = activity.estimatedRemaining.map { String(format: "%.0f s ETA", ceil($0)) } ?? "ETA unknown"
            return .init(id: "download:\(activity.id)", kind: .downloads, title: activity.name,
                         detail: activity.state == .completed ? "Final file observed · \(bytes)" : activity.expectedTotalBytes == nil ? "Partial file · \(bytes) · Total/ETA unknown" : "Partial file · \(bytes) · \(eta) · Supplied total", toolID: "downloads", progress: activity.progress,
                         action: activity.state == .completed ? .revealFile : nil)
        }
    }
    private var visible = false
    private var task: Task<Void, Never>?
    private var tracker = DownloadActivityTracker()
    private var generation = UUID()
    init(folderURL: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first) { self.folderURL = folderURL }
    func chooseDownloads() { setFolder(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first) }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { setFolder(panel.url) }
    }
    func setFolder(_ folder: URL?) { enabled = false; reconcile(); folderURL = folder; tracker = .init(); activities = []; error = nil }
    func enable() { guard folderURL != nil else { error = "Choose a tracking folder first."; return }; enabled = true; reconcile() }
    func disable() { enabled = false; reconcile() }
    func resume() { visible = true; reconcile() }
    func stop() { visible = false; reconcile() }
    func shutdown() { visible = false; enabled = false; backgroundMonitoring = false; reconcile() }
    func clearRetained() { tracker.clearRetained(); activities = tracker.activities }
    func setExpectedTotal(_ bytes: Int64?, activityID: String) {
        do { try tracker.setExpectedTotal(bytes, forID: activityID); activities = tracker.activities; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func invalidExpectedTotal() { error = "Enter a positive whole number of expected bytes, or clear the field to leave the total unknown." }
    func reveal(_ activity: DownloadActivity) {
        guard let url = activity.outputURL, FileManager.default.fileExists(atPath: url.path) else { error = "The observed final file is no longer available."; return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func reveal(statusID: String) {
        guard let activity = activities.first(where: { "download:\($0.id)" == statusID && $0.state == .completed }) else { return }
        reveal(activity)
    }
    private func reconcile() {
        guard enabled, visible || backgroundMonitoring, let folder = folderURL else {
            generation = UUID(); task?.cancel(); task = nil; isSampling = false; tracker.pause(); activities = tracker.activities; return
        }
        guard task == nil else { return }
        let token = UUID(); generation = token; isSampling = true
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let read = Task.detached { try DownloadFolderReader.read(folder) }
                do {
                    let files = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
                    try Task.checkCancellation()
                    guard let self, self.generation == token else { return }
                    self.tracker.observe(files); self.activities = self.tracker.activities; self.error = nil
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError { return }
                catch {
                    guard let self, self.generation == token else { return }
                    self.error = error.localizedDescription; self.tracker.pause(); self.activities = self.tracker.activities
                    self.task = nil; self.isSampling = false; return
                }
            }
        }
    }
}
@MainActor
struct DownloadsToolView: View {
    @ObservedObject private var service: DownloadsService
    @State private var expectedEdits: [String: String] = [:]
    init(service: DownloadsService = .shared) { self.service = service }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Download activities", systemImage: "arrow.down.circle").font(.headline)
            HStack { Button("Downloads Folder", action: service.chooseDownloads); Button("Choose Folder…", action: service.chooseFolder); Spacer(); Button(service.enabled ? "Disable" : "Enable") { if service.enabled { service.disable() } else { service.enable() } } }
            Text(service.folderURL?.path ?? "No folder selected").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Toggle("Track while dashboard is closed", isOn: Binding(get: { service.backgroundMonitoring }, set: { service.backgroundMonitoring = $0 })).disabled(!service.enabled)
            if service.activities.isEmpty { Text("Enable to observe browser partial files (.crdownload, .part, .partial, .download). Existing finished files are not reported as new downloads.").font(.caption).foregroundStyle(.secondary) }
            else {
                List(service.activities) { activity in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(activity.name).lineLimit(1)
                            Text(description(activity)).font(.caption).foregroundStyle(.secondary)
                            if let progress = activity.progress { ProgressView(value: progress).help("Progress uses your supplied expected total.") }
                            if activity.state == .active {
                                HStack {
                                    TextField("Expected total bytes", text: Binding(get: { expectedEdits[activity.id] ?? activity.expectedTotalBytes.map(String.init) ?? "" }, set: { expectedEdits[activity.id] = $0 }))
                                        .textFieldStyle(.roundedBorder).frame(maxWidth: 190)
                                    Button("Set") { setTotal(activity) }
                                    if activity.expectedTotalBytes != nil { Button("Clear") { expectedEdits[activity.id] = ""; service.setExpectedTotal(nil, activityID: activity.id) } }
                                }
                            }
                        }
                        Spacer()
                        if activity.outputURL != nil { Button("Reveal") { service.reveal(activity) } }
                    }
                }.frame(height: 200)
            }
            Button("Clear Retained Activities", action: service.clearRetained)
            Text("Total is unknown unless you supply expected bytes. Progress and ETA then use that total and observed file growth; a stalled, reset, or paused file has no ETA. A matching final file is retained for Reveal. Disable pauses observation and never cancels or deletes a browser download.").font(.caption).foregroundStyle(.secondary)
            LocalToolError(message: service.error)
        }.onAppear { service.resume() }.onDisappear { service.stop() }
            .background(OrbitNativeToolVisibility(onVisible: service.resume, onHidden: service.stop).frame(width: 0, height: 0))
    }
    private func description(_ value: DownloadActivity) -> String {
        let bytes = value.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unknown"
        switch value.state {
        case .active:
            if let total = value.expectedTotalBytes {
                let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                let rate = value.bytesPerSecond.map { String(format: "%.0f bytes/s", $0) } ?? "Rate unknown"
                let eta = value.estimatedRemaining.map { String(format: "%.0f s ETA", ceil($0)) } ?? "ETA unknown"
                return "\(bytes) of user-supplied \(totalText) · \(rate) · \(eta)"
            }
            return "Partial file observed · \(bytes) · Total/ETA unknown"
        case .completed: return "Matching final file observed · \(bytes)"
        case .removed: return "Partial file removed · Completion unknown"
        case .paused: return "Tracking paused · \(bytes)"
        }
    }
    private func setTotal(_ value: DownloadActivity) {
        let text = (expectedEdits[value.id] ?? value.expectedTotalBytes.map(String.init) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { service.setExpectedTotal(nil, activityID: value.id) }
        else if let bytes = Int64(text) { service.setExpectedTotal(bytes, activityID: value.id) }
        else { service.invalidExpectedTotal() }
    }
}
