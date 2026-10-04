import Foundation
import AppKit
import CornerCore

enum CornerActionExecution: Equatable, Sendable {
    case performed(title: String)
    case showChromeHistory
    case showRecentWebsites
}

enum CornerActionExecutionError: LocalizedError, Equatable, Sendable {
    case automationDisabled(String)
    case applicationMissing(name: String, bundleID: String)
    case invalidApplication
    case launchFailed(String)
    case launchTimedOut
    case scriptFailed(status: Int32, diagnostic: String)
    case scriptTimedOut(TimeInterval)
    case scriptOutputLimit
    var errorDescription: String? {
        switch self {
        case .automationDisabled(let title): "\(title) requires Automation. Enable the Automation option in CornerOrbit Settings, then explicitly run this action to let macOS ask for access."
        case .applicationMissing(let name, let bundleID): "\(name) is not installed or could not be found (\(bundleID)). Choose an installed app with Custom Application in Settings."
        case .invalidApplication: "The selected application could not be resolved to a local app."
        case .launchFailed(let message): "macOS could not open the requested target: \(message)"
        case .launchTimedOut: "macOS did not complete the application request within 15 seconds."
        case .scriptFailed(let status, let diagnostic): diagnostic.isEmpty ? "The application command failed with status \(status)." : "The application command failed: \(diagnostic)"
        case .scriptTimedOut(let seconds): "The application command did not finish within \(seconds.formatted()) seconds and was stopped."
        case .scriptOutputLimit: "The application command exceeded the output limit and was stopped."
        }
    }
}

struct CornerAppleScriptRequest: Equatable, Sendable {
    let targetBundleID: String
    let source: String
}

enum CornerActionScripts {
    /// Only this fixed catalog can create a script from a configured action.
    /// Custom application identifiers and website strings never become code.
    static func request(for kind: CornerActionKind) -> CornerAppleScriptRequest? {
        let target: String
        let command: String
        switch kind {
        case .chromeNewTab:
            target = "com.google.Chrome"
            command = """
            if (count of windows) is 0 then
                make new window
            else
                tell front window to make new tab with properties {URL:"chrome://newtab/"}
            end if
            """
        case .newWord: target = "com.microsoft.Word"; command = "make new document"
        case .newExcel: target = "com.microsoft.Excel"; command = "make new workbook"
        case .newPowerPoint: target = "com.microsoft.Powerpoint"; command = "make new presentation"
        case .newTextEdit: target = "com.apple.TextEdit"; command = "make new document"
        default: return nil
        }
        return .init(targetBundleID: target, source: "tell application id \"\(target)\"\nactivate\n\(command)\nend tell")
    }
}

@MainActor
final class CornerActionRunner {
    private let workspace: any CornerWorkspaceAccessing
    private let scripts: any CornerScriptExecuting
    init(workspace: any CornerWorkspaceAccessing = CornerNativeWorkspace(), scripts: any CornerScriptExecuting = CornerAppleScriptExecutor()) {
        self.workspace = workspace; self.scripts = scripts
    }
    func run(_ action: CornerAction, automationEnabled: Bool) async throws -> CornerActionExecution {
        try Task.checkCancellation()
        let action = try action.validated()
        if let script = CornerActionScripts.request(for: action.kind) {
            guard automationEnabled else { throw CornerActionExecutionError.automationDisabled(action.kind.title) }
            let application = try applicationURL(name: applicationName(for: action.kind), bundleID: script.targetBundleID)
            try await workspace.openApplication(at: application)
            try Task.checkCancellation()
            try await scripts.execute(script)
            try Task.checkCancellation()
            return .performed(title: action.kind.title)
        }
        switch action.kind {
        case .none: return .performed(title: "No action configured")
        case .chromeHistory: return .showChromeHistory
        case .recentWebsites: return .showRecentWebsites
        case .whatsAppWeb, .openURL:
            guard let url = action.webURL else { throw CornerActionError.invalid("Choose a valid HTTP or HTTPS website.") }
            let validated = try CornerURLValidation.webURL(url.absoluteString)
            let application = try applicationURL(name: "Google Chrome", bundleID: "com.google.Chrome")
            try await workspace.openWebsite(validated, in: application)
        case .chatGPT, .claude, .spotify, .activityMonitor, .finder, .openSystemSettings, .openApplication:
            let bundleID: String
            switch action.kind {
            case .chatGPT: bundleID = "com.openai.chat"
            case .claude: bundleID = "com.anthropic.claudefordesktop"
            case .openApplication:
                guard let configured = action.bundleID else { throw CornerActionError.invalid("Choose an installed application.") }
                bundleID = configured
            default:
                guard let configured = action.kind.defaultBundleID else { throw CornerActionError.invalid("This application action is unavailable.") }
                bundleID = configured
            }
            let application = try applicationURL(name: applicationName(for: action.kind), bundleID: bundleID)
            try await workspace.openApplication(at: application)
        case .openDownloads:
            guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                throw CornerActionError.invalid("The Downloads folder is unavailable.")
            }
            try await workspace.openDirectory(folder)
        case .openApplications: try await workspace.openDirectory(URL(fileURLWithPath: "/Applications", isDirectory: true))
        case .chromeNewTab, .newWord, .newExcel, .newPowerPoint, .newTextEdit:
            throw CornerActionError.invalid("This Automation action is unavailable.")
        }
        try Task.checkCancellation()
        return .performed(title: action.kind.title)
    }
    private func applicationURL(name: String, bundleID: String) throws -> URL {
        guard let url = workspace.applicationURL(bundleID: bundleID) else {
            throw CornerActionExecutionError.applicationMissing(name: name, bundleID: bundleID)
        }
        guard url.isFileURL else { throw CornerActionExecutionError.invalidApplication }
        return url
    }
    private func applicationName(for kind: CornerActionKind) -> String {
        switch kind {
        case .chromeNewTab: "Google Chrome"
        case .newWord: "Microsoft Word"
        case .newExcel: "Microsoft Excel"
        case .newPowerPoint: "Microsoft PowerPoint"
        case .newTextEdit: "TextEdit"
        default: kind.title
        }
    }
}
