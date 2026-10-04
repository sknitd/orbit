import AppIntents
import AppKit
import NotchCore
import UniformTypeIdentifiers

@MainActor
final class PlusIntentCoordinator {
    static let shared = PlusIntentCoordinator()
    var toggleDashboard: (() -> Void)?
    func toggle() throws {
        guard let toggleDashboard else { throw PlusIntentFailure.invalid("Open NotchOrbitPlus before toggling the dashboard.") }
        toggleDashboard()
    }
    static func addFileToShelf(_ file: IntentFile, shelf: FileShelfToolStore = .shared) async throws -> FileShelfItem {
        try await withFile(file) { url in
            try await shelf.addManagedFile(url)
        }
    }
    static func withFile<T>(_ file: IntentFile, operation: @MainActor (URL) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        if let url = file.fileURL {
            guard url.isFileURL else { throw PlusIntentFailure.invalid("Choose a local file for this Shortcut.") }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, bytes >= 0, bytes <= PlusIntentValidation.maximumFileBytes else {
                throw PlusIntentFailure.invalid("Shortcut files must be regular files of at most 100 MB.")
            }
            return try await operation(url)
        }
        let name = try PlusIntentValidation.filename(file.filename)
        let bytes = file.data
        guard bytes.count <= PlusIntentValidation.maximumFileBytes else {
            throw PlusIntentFailure.invalid("Shortcut files must contain at most 100 MB.")
        }
        let directory = try LocalToolStorage.directory().appendingPathComponent("Intent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try await operation(url)
    }
}

struct StartFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Focus"
    static let description = IntentDescription("Start a local NotchOrbitPlus focus session.")
    static let openAppWhenRun = true
    @Parameter(title: "Minutes", default: 25) var minutes: Int
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let duration = try PlusIntentValidation.focusMinutes(minutes)
        FocusTimerService.shared.focusMinutes = duration
        FocusTimerService.shared.start()
        return .result(dialog: "Started a \(minutes)-minute focus session.")
    }
}

struct AddFileToShelfIntent: AppIntent {
    static let title: LocalizedStringResource = "Add File to Shelf"
    static let description = IntentDescription("Copy a chosen local file into NotchOrbitPlus File Shelf.")
    static let openAppWhenRun = true
    @Parameter(title: "File") var file: IntentFile
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await PlusIntentCoordinator.addFileToShelf(file)
        return .result(dialog: "Added the file to File Shelf.")
    }
}

struct WorkflowPresetEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workflow Preset")
    static let defaultQuery = WorkflowPresetQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WorkflowPresetQuery: EntityQuery, Sendable {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [WorkflowPresetEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    @MainActor
    func suggestedEntities() async throws -> [WorkflowPresetEntity] {
        WorkflowStore.shared.presets.map { WorkflowPresetEntity(id: $0.id.uuidString, name: $0.name) }
    }
}

struct RunWorkflowIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Workflow"
    static let description = IntentDescription("Run a saved NotchOrbitPlus image or video workflow on a chosen file.")
    static let openAppWhenRun = true
    @Parameter(title: "File") var file: IntentFile
    @Parameter(title: "Preset") var preset: WorkflowPresetEntity
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[IntentFile]> {
        let id = try PlusIntentValidation.presetID(preset.id)
        let destination: URL? = file.fileURL == nil
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first : nil
        if file.fileURL == nil, destination == nil {
            throw PlusIntentFailure.invalid("Downloads is unavailable for this Shortcut's workflow output.")
        }
        let outputs = try await PlusIntentCoordinator.withFile(file) { url in
            try await WorkflowStore.shared.runAndWaitExplicitly([url], presetID: id, outputDirectoryOverride: destination)
        }
        return .result(value: outputs.map { IntentFile(fileURL: $0) }, dialog: "Saved \(outputs.count) workflow output(s).")
    }
}

struct ToggleDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Dashboard"
    static let description = IntentDescription("Open or collapse the NotchOrbitPlus dashboard.")
    static let openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try PlusIntentCoordinator.shared.toggle()
        return .result(dialog: "Toggled the NotchOrbitPlus dashboard.")
    }
}

struct CaptureScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Screenshot"
    static let description = IntentDescription("Capture the selected display into File Shelf. Screen Recording access is requested only when you run this action.")
    static let openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await ScreenshotShelfStore.shared.captureFullScreenForIntent()
        return .result(dialog: "Captured the display into File Shelf.")
    }
}

struct PlusAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartFocusIntent(), phrases: ["Start focus in \(.applicationName)"], shortTitle: "Start Focus", systemImageName: "timer")
        AppShortcut(intent: AddFileToShelfIntent(), phrases: ["Add a file to \(.applicationName)"], shortTitle: "Add to Shelf", systemImageName: "tray.full")
        AppShortcut(intent: RunWorkflowIntent(), phrases: ["Run a workflow in \(.applicationName)"], shortTitle: "Run Workflow", systemImageName: "point.3.connected.trianglepath.dotted")
        AppShortcut(intent: ToggleDashboardIntent(), phrases: ["Toggle \(.applicationName) dashboard"], shortTitle: "Toggle Dashboard", systemImageName: "rectangle.topthird.inset.filled")
        AppShortcut(intent: CaptureScreenshotIntent(), phrases: ["Capture a screenshot in \(.applicationName)"], shortTitle: "Capture Screenshot", systemImageName: "camera.viewfinder")
    }
}
