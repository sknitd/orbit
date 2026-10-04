import Foundation
import Darwin
import AppKit
import XCTest
import CornerCore
@testable import CornerOrbit

final class CornerActionTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testDisabledAutomationAndMalformedActionsNeverResolveLaunchOrScript() async throws {
        let workspace = CornerWorkspaceFixture(), scripts = CornerScriptFixture()
        let runner = CornerActionRunner(workspace: workspace, scripts: scripts)
        do {
            _ = try await runner.run(.init(kind: .newWord), automationEnabled: false)
            XCTFail("Automation must require explicit enabling")
        } catch CornerActionExecutionError.automationDisabled(let title) { XCTAssertEqual(title, "New Word Document") }
        for source in ["javascript:alert(1)", "file:///tmp/fixture", "https://user:secret@example.com", "https://example.com/a\nb"] {
            do { _ = try await runner.run(.init(kind: .openURL, url: source), automationEnabled: true); XCTFail("Invalid URL must fail") }
            catch is CornerActionError {}
        }
        XCTAssertTrue(workspace.events.isEmpty)
        let requests = await scripts.snapshot(); XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testFourDocumentActionsConstructDistinctFixedRequestsWithoutKeystrokes() async throws {
        let workspace = CornerWorkspaceFixture(), scripts = CornerScriptFixture()
        let runner = CornerActionRunner(workspace: workspace, scripts: scripts)
        let cases: [(CornerActionKind, String, String)] = [
            (.newWord, "com.microsoft.Word", "make new document"),
            (.newExcel, "com.microsoft.Excel", "make new workbook"),
            (.newPowerPoint, "com.microsoft.Powerpoint", "make new presentation"),
            (.newTextEdit, "com.apple.TextEdit", "make new document")
        ]
        for (kind, id, _) in cases {
            workspace.applications[id] = URL(fileURLWithPath: "/Applications/Fixture-\(kind.rawValue).app")
            let result = try await runner.run(.init(kind: kind), automationEnabled: true)
            XCTAssertEqual(result, .performed(title: kind.title))
        }
        let requests = await scripts.snapshot()
        XCTAssertEqual(requests.count, 4); XCTAssertEqual(Set(requests.map(\.source)).count, 4)
        for (index, (_, id, command)) in cases.enumerated() {
            XCTAssertEqual(requests[index].targetBundleID, id)
            XCTAssertTrue(requests[index].source.contains("tell application id \"\(id)\""))
            XCTAssertTrue(requests[index].source.contains(command))
            XCTAssertFalse(requests[index].source.contains("System Events"))
            XCTAssertFalse(requests[index].source.contains("keystroke"))
            XCTAssertFalse(requests[index].source.contains("save"))
        }
        XCTAssertEqual(workspace.events.filter { if case .application = $0 { return true }; return false }.count, 4)
    }

    @MainActor
    func testChromeNewTabCreatesWindowOnlyWhenNeededAndNeverContainsUserInput() async throws {
        let workspace = CornerWorkspaceFixture(), scripts = CornerScriptFixture()
        workspace.applications["com.google.Chrome"] = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        _ = try await CornerActionRunner(workspace: workspace, scripts: scripts).run(.init(kind: .chromeNewTab), automationEnabled: true)
        let requests = await scripts.snapshot()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.targetBundleID, "com.google.Chrome")
        XCTAssertTrue(request.source.contains("if (count of windows) is 0"))
        XCTAssertTrue(request.source.contains("make new window"))
        XCTAssertTrue(request.source.contains("make new tab with properties {URL:\"chrome://newtab/\"}"))
    }

    @MainActor
    func testConfiguredURLAndWhatsAppAreWorkspaceChromeRequestsWithoutScripts() async throws {
        let workspace = CornerWorkspaceFixture(), scripts = CornerScriptFixture()
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        workspace.applications["com.google.Chrome"] = chrome
        let runner = CornerActionRunner(workspace: workspace, scripts: scripts)
        let input = "HTTPS://Example.com/?q=%22do%20shell%20script%22&value=%5C"
        let expected = try CornerURLValidation.webURL(input)
        _ = try await runner.run(.init(kind: .openURL, url: input), automationEnabled: false)
        _ = try await runner.run(.init(kind: .whatsAppWeb), automationEnabled: false)
        XCTAssertTrue(workspace.events.contains(.website(expected, chrome)))
        XCTAssertTrue(workspace.events.contains(.website(try XCTUnwrap(URL(string: "https://web.whatsapp.com/")), chrome)))
        let requests = await scripts.snapshot(); XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testMissingDesktopAppsDoNotBecomeWebsitesAndNativeErrorsPropagate() async throws {
        let workspace = CornerWorkspaceFixture(), scripts = CornerScriptFixture()
        let runner = CornerActionRunner(workspace: workspace, scripts: scripts)
        for (kind, id) in [(CornerActionKind.chatGPT, "com.openai.chat"), (.claude, "com.anthropic.claudefordesktop")] {
            do { _ = try await runner.run(.init(kind: kind), automationEnabled: false); XCTFail("Missing app must be visible") }
            catch CornerActionExecutionError.applicationMissing(_, let bundleID) { XCTAssertEqual(bundleID, id) }
        }
        XCTAssertEqual(workspace.events, [.lookup("com.openai.chat"), .lookup("com.anthropic.claudefordesktop")])
        workspace.applications["com.apple.finder"] = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        workspace.failure = .launchFailed("Fixture native failure")
        do { _ = try await runner.run(.init(kind: .finder), automationEnabled: false); XCTFail("Launch failure must propagate") }
        catch CornerActionExecutionError.launchFailed(let message) { XCTAssertEqual(message, "Fixture native failure") }
        let requests = await scripts.snapshot(); XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testDropdownRoutesArePureAndCancellationStopsScriptWork() async throws {
        let workspace = CornerWorkspaceFixture(), scripts = CornerScriptFixture()
        let runner = CornerActionRunner(workspace: workspace, scripts: scripts)
        let history = try await runner.run(.init(kind: .chromeHistory), automationEnabled: false)
        let recent = try await runner.run(.init(kind: .recentWebsites), automationEnabled: false)
        XCTAssertEqual(history, .showChromeHistory)
        XCTAssertEqual(recent, .showRecentWebsites)
        XCTAssertTrue(workspace.events.isEmpty)
        workspace.applications["com.apple.TextEdit"] = URL(fileURLWithPath: "/Applications/TextEdit.app")
        await scripts.setWait(true)
        let operation = Task { try await runner.run(.init(kind: .newTextEdit), automationEnabled: true) }
        for _ in 0..<50 {
            if await scripts.snapshot().count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected propagated cancellation") }
        catch is CancellationError {}
        let cancelled = await scripts.wasCancelled(); XCTAssertTrue(cancelled)
    }

    func testNativeScriptTimeoutCancellationAndErrorsWithoutTargetingApplications() async throws {
        // Builtin AppleScript only: no tell application, accounts, or permissions.
        let delay = CornerAppleScriptRequest(targetBundleID: "fixture", source: "delay 10")
        let beforeTimeout = Date()
        do { try await CornerAppleScriptExecutor(timeout: 0.1).execute(delay); XCTFail("Delay must time out") }
        catch CornerActionExecutionError.scriptTimedOut(let seconds) { XCTAssertEqual(seconds, 0.1) }
        XCTAssertLessThan(Date().timeIntervalSince(beforeTimeout), 3)
        let operation = Task { try await CornerAppleScriptExecutor(timeout: 30).execute(delay) }
        try await Task.sleep(for: .milliseconds(100)); let beforeCancel = Date(); operation.cancel()
        do { try await operation.value; XCTFail("Expected subprocess cancellation") }
        catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(beforeCancel), 3)
        let refusal = CornerAppleScriptRequest(targetBundleID: "fixture", source: "error \"CornerOrbit fixture refusal\" number -2700")
        do { try await CornerAppleScriptExecutor().execute(refusal); XCTFail("Real interpreter error must propagate") }
        catch CornerActionExecutionError.scriptFailed(let status, let diagnostic) {
            XCTAssertNotEqual(status, 0); XCTAssertTrue(diagnostic.contains("CornerOrbit fixture refusal"))
        }
    }

    func testNativeScriptOutputIsBoundedWithoutLaunchingApplications() async throws {
        let output = CornerAppleScriptRequest(targetBundleID: "fixture", source: "repeat 1024 times\nlog \"CornerOrbit output fixture\"\nend repeat")
        do { try await CornerAppleScriptExecutor(timeout: 5, outputLimit: 1_024).execute(output); XCTFail("Unbounded output must fail") }
        catch CornerActionExecutionError.scriptOutputLimit {}
    }
    @MainActor
    func testExpandedFixedAutomationCatalogGatesBeforeAnyExternalWork() async throws {
        let workspace = CornerWorkspaceFixture(), scripts = CornerScriptFixture()
        let runner = CornerActionRunner(workspace: workspace, scripts: scripts)
        let kinds: [CornerActionKind] = [.chromePrivateWindow, .safariNewTab, .finderNewWindow, .newPages, .newNumbers, .newKeynote]
        for kind in kinds {
            do { _ = try await runner.run(.init(kind: kind), automationEnabled: false); XCTFail("Consent must remain opt-in") }
            catch CornerActionExecutionError.automationDisabled(let title) { XCTAssertEqual(title, kind.title) }
        }
        XCTAssertTrue(workspace.events.isEmpty)
        for kind in kinds {
            let id = try XCTUnwrap(kind.defaultBundleID)
            workspace.applications[id] = URL(fileURLWithPath: "/Applications/Fixture-" + kind.rawValue + ".app")
            _ = try await runner.run(.init(kind: kind), automationEnabled: true)
        }
        let requests = await scripts.snapshot(); XCTAssertEqual(requests.count, 6)
        XCTAssertTrue(requests[0].source.contains("{mode:\"incognito\"}"))
        XCTAssertTrue(requests[1].source.contains("about:blank"))
        XCTAssertTrue(requests[2].source.contains("make new Finder window"))
        for request in requests {
            XCTAssertFalse(request.source.contains("System Events")); XCTAssertFalse(request.source.contains("keystroke"))
            XCTAssertFalse(request.source.contains("do shell script")); XCTAssertFalse(request.source.contains("save"))
        }
    }

    @MainActor
    func testClipboardSearchReadsOnlyOnRunAndEncodesOneNamedProviderQuery() async throws {
        let workspace = CornerWorkspaceFixture(), clipboard = CornerClipboardFixture("a&b=1; $(command) 😀")
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        workspace.applications["com.google.Chrome"] = chrome
        let runner = CornerActionRunner(workspace: workspace, clipboard: clipboard)
        XCTAssertEqual(clipboard.readCount, 0)
        _ = try await runner.run(.init(kind: .favoriteWebsites), automationEnabled: false)
        XCTAssertEqual(clipboard.readCount, 0)
        _ = try await runner.run(.init(kind: .chromeSearchClipboard), automationEnabled: false)
        XCTAssertEqual(clipboard.readCount, 1)
        let expected = try CornerClipboardActionText.googleSearchURL(clipboard.text)
        XCTAssertTrue(workspace.events.contains(.website(expected, chrome)))
        clipboard.text = String(repeating: "é", count: 32_769)
        let before = workspace.events.filter { if case .website = $0 { true } else { false } }.count
        do { _ = try await runner.run(.init(kind: .chromeSearchClipboard), automationEnabled: false); XCTFail("Oversized clipboard must fail") }
        catch is CornerActionError {}
        XCTAssertEqual(workspace.events.filter { if case .website = $0 { true } else { false } }.count, before)
    }

    @MainActor
    func testMissingClipboardTargetFailsBeforeClipboardReadAndNativeLaunchErrorsRemainVisible() async throws {
        let workspace = CornerWorkspaceFixture(), clipboard = CornerClipboardFixture("private fixture")
        let runner = CornerActionRunner(workspace: workspace, clipboard: clipboard)
        for kind in [CornerActionKind.chromeSearchClipboard, .textEditFromClipboard, .screenshotToolbar, .screenSaver] {
            do { _ = try await runner.run(.init(kind: kind), automationEnabled: false); XCTFail("Missing target must be visible") }
            catch CornerActionExecutionError.applicationMissing {}
        }
        XCTAssertEqual(clipboard.readCount, 0)
        workspace.applications["com.apple.screencaptureui"] = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        _ = try await runner.run(.init(kind: .screenshotToolbar), automationEnabled: false)
        XCTAssertEqual(clipboard.readCount, 0)
    }

    @MainActor
    func testClipboardDraftOpensNewPrivateFileInTextEditWithoutAutomationOrUserCode() async throws {
        let workspace = CornerWorkspaceFixture(), clipboard = CornerClipboardFixture("quoted \"text\"; do shell script \"fixture\"")
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let draftURL = URL(fileURLWithPath: "/tmp/CornerOrbit-fixture/new-draft.txt")
        workspace.applications["com.apple.TextEdit"] = textEdit
        let drafts = CornerDraftFixture(output: draftURL), scripts = CornerScriptFixture()
        let runner = CornerActionRunner(workspace: workspace, scripts: scripts, clipboard: clipboard, drafts: drafts)
        _ = try await runner.run(.init(kind: .textEditFromClipboard), automationEnabled: false)
        let written = await drafts.snapshot(); XCTAssertEqual(written, [clipboard.text])
        XCTAssertTrue(workspace.events.contains(.file(draftURL, textEdit)))
        let requests = await scripts.snapshot(); XCTAssertTrue(requests.isEmpty)
    }

    func testNativeDraftWriterCreatesPrivateUniqueFilesPreservesOriginalAndRejectsSymlinkFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CornerOrbit-draft-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt"), bytes = Data("original fixture".utf8)
        try bytes.write(to: original)
        let folder = root.appendingPathComponent("Drafts", isDirectory: true)
        let writer = CornerTextDraftWriter(directory: folder)
        let first = try await writer.create(text: "first 😀"), second = try await writer.create(text: "second")
        XCTAssertNotEqual(first, second); XCTAssertEqual(first.deletingLastPathComponent(), folder)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first 😀")
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let alias = root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        do { _ = try await CornerTextDraftWriter(directory: alias).create(text: "must not write"); XCTFail("Application draft folder cannot be a symlink") }
        catch is CornerActionError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }

    @MainActor
    func testWindowClipboardAndLibraryRoutesUseInjectedOwnersWithoutOtherInputs() async throws {
        let workspace = CornerWorkspaceFixture(), clipboard = CornerClipboardFixture("unread")
        let windows = CornerWindowFixture(), shortcuts = CornerShortcutFixture()
        let runner = CornerActionRunner(workspace: workspace, clipboard: clipboard, shortcuts: shortcuts, windows: windows)
        for kind in CornerActionCatalog.all where kind.isWindowAction {
            let result = try await runner.run(.init(kind: kind), automationEnabled: false)
            XCTAssertEqual(result, .performed(title: kind.title))
        }
        XCTAssertEqual(windows.kinds.count, 10)
        for kind in CornerActionCatalog.all where kind.isClipboardTransform {
            let result = try await runner.run(.init(kind: kind), automationEnabled: false)
            XCTAssertEqual(result, .transformClipboard(kind: kind))
        }
        let group = UUID().uuidString
        let groupResult = try await runner.run(.init(kind: .openURLGroup, argument: group), automationEnabled: false)
        XCTAssertEqual(groupResult, .openURLGroup(id: group))
        let favorites = try await runner.run(.init(kind: .favoriteWebsites), automationEnabled: false)
        let clipboardRoute = try await runner.run(.init(kind: .clipboardWorkspace), automationEnabled: false)
        XCTAssertEqual(favorites, .showFavorites); XCTAssertEqual(clipboardRoute, .showClipboard)
        XCTAssertTrue(workspace.events.isEmpty); XCTAssertEqual(clipboard.readCount, 0)
    }

    @MainActor
    func testFileAndShortcutArgumentsRemainTypedAndShortcutCancellationPropagates() async throws {
        let workspace = CornerWorkspaceFixture(), shortcuts = CornerShortcutFixture()
        let runner = CornerActionRunner(workspace: workspace, shortcuts: shortcuts)
        let path = "/tmp/A folder/quoted \"file\".txt"
        _ = try await runner.run(.init(kind: .openFile, argument: path), automationEnabled: false)
        XCTAssertEqual(workspace.events, [.file(URL(fileURLWithPath: path), nil)])
        let name = "Quoted \"Shortcut\"; $(not-a-shell)"
        XCTAssertEqual(try CornerShortcutsRunner.arguments(for: name), ["run", name])
        XCTAssertThrowsError(try CornerShortcutsRunner.arguments(for: "--input-path"))
        await shortcuts.setWait(true)
        let operation = Task { try await runner.run(.init(kind: .runShortcut, argument: name), automationEnabled: false) }
        for _ in 0..<50 {
            if await shortcuts.snapshot().count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Shortcut task must propagate cancellation") }
        catch is CancellationError {}
        let names = await shortcuts.snapshot(); XCTAssertEqual(names, [name])
        let cancelled = await shortcuts.wasCancelled(); XCTAssertTrue(cancelled)
    }

    func testActualBoundedProcessPreservesArgumentsWithoutAShell() async throws {
        let literal = "a space; $(echo injected) \"quote\""
        let data = try await CornerCommandProcess(timeout: 5, outputLimit: 1_024).run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", literal])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), literal)
    }

    func testDescendantHoldingOutputPipeCannotExtendChildExitTimeoutOrCancellation() async throws {
        // Fixed fixture shell only. Each inherited writer is a tracked private
        // sleep process, killed below; no app scripts, accounts, or user inputs.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CornerOrbit-pipe-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = (0..<3).map { directory.appendingPathComponent("child-\($0).pid") }
        defer {
            for file in files {
                if let bytes = try? Data(contentsOf: file), let pid = Int32(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let exited = "/bin/sleep 30 & child=$!; printf '%s' \"$child\" > \"$1\"; printf 'fixture-output'; exit 0"
        let waiting = "/bin/sleep 30 & child=$!; printf '%s' \"$child\" > \"$1\"; printf 'fixture-output'; wait"
        let beforeExit = Date()
        let bytes = try await CornerCommandProcess(timeout: 5, outputLimit: 1_024).run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", exited, "CornerOrbit-pipe-fixture", files[0].path])
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "fixture-output")
        XCTAssertLessThan(Date().timeIntervalSince(beforeExit), 2, "Tracked child exit must not wait for a descendant's EOF")
        let writer = try XCTUnwrap(Int32(String(decoding: Data(contentsOf: files[0]), as: UTF8.self)))
        XCTAssertEqual(Darwin.kill(writer, 0), 0, "Fixture descendant must still hold the pipe when the parent operation completes")

        let beforeTimeout = Date()
        do {
            _ = try await CornerCommandProcess(timeout: 0.15, outputLimit: 1_024).run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", waiting, "CornerOrbit-pipe-fixture", files[1].path])
            XCTFail("A waiting child must time out even when its descendant holds output")
        } catch CornerActionExecutionError.scriptTimedOut(let seconds) { XCTAssertEqual(seconds, 0.15) }
        XCTAssertLessThan(Date().timeIntervalSince(beforeTimeout), 2)

        let operation = Task {
            try await CornerCommandProcess(timeout: 10, outputLimit: 1_024).run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", waiting, "CornerOrbit-pipe-fixture", files[2].path])
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: files[2].path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[2].path))
        let beforeCancel = Date(); operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancellation must not wait for descendant EOF") }
        catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(beforeCancel), 2)
    }

}

@MainActor
private final class CornerWorkspaceFixture: CornerWorkspaceAccessing {
    enum Event: Equatable { case lookup(String), application(URL), website(URL, URL), directory(URL), file(URL, URL?) }
    var applications: [String: URL] = [:]
    var events: [Event] = []
    var failure: CornerActionExecutionError?
    func applicationURL(bundleID: String) -> URL? { events.append(.lookup(bundleID)); return applications[bundleID] }
    func openApplication(at url: URL) async throws { events.append(.application(url)); if let failure { throw failure } }
    func openWebsite(_ url: URL, in application: URL) async throws { events.append(.website(url, application)); if let failure { throw failure } }
    func openDirectory(_ url: URL) async throws { events.append(.directory(url)); if let failure { throw failure } }
    func openFile(_ url: URL) async throws { events.append(.file(url, nil)); if let failure { throw failure } }
    func openFile(_ url: URL, in application: URL) async throws { events.append(.file(url, application)); if let failure { throw failure } }
}

private actor CornerScriptFixture: CornerScriptExecuting {
    private var requests: [CornerAppleScriptRequest] = []
    private var wait = false
    private var cancelled = false
    func execute(_ request: CornerAppleScriptRequest) async throws {
        requests.append(request)
        if wait {
            do { try await Task.sleep(for: .seconds(30)) }
            catch is CancellationError { cancelled = true; throw CancellationError() }
        }
    }
    func snapshot() -> [CornerAppleScriptRequest] { requests }
    func setWait(_ wait: Bool) { self.wait = wait }
    func wasCancelled() -> Bool { cancelled }
}

@MainActor
private final class CornerClipboardFixture: CornerClipboardReading {
    var text: String
    var readCount = 0
    init(_ text: String) { self.text = text }
    func readPlainText() throws -> String { readCount += 1; return text }
}
private actor CornerDraftFixture: CornerDraftWriting {
    let output: URL
    private var texts: [String] = []
    init(output: URL) { self.output = output }
    func create(text: String) async throws -> URL { texts.append(text); return output }
    func snapshot() -> [String] { texts }
}
@MainActor
private final class CornerWindowFixture: CornerWindowActionRunning {
    var kinds: [CornerActionKind] = []
    func run(_ kind: CornerActionKind) async throws -> String { kinds.append(kind); return kind.title }
}
private actor CornerShortcutFixture: CornerShortcutsExecuting {
    private var names: [String] = []
    private var wait = false
    private var cancelled = false
    func run(name: String) async throws {
        names.append(name)
        if wait {
            do { try await Task.sleep(for: .seconds(30)) }
            catch is CancellationError { cancelled = true; throw CancellationError() }
        }
    }
    func snapshot() -> [String] { names }
    func setWait(_ value: Bool) { wait = value }
    func wasCancelled() -> Bool { cancelled }
}
