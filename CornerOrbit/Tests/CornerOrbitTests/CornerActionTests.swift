import Foundation
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
}

@MainActor
private final class CornerWorkspaceFixture: CornerWorkspaceAccessing {
    enum Event: Equatable { case lookup(String), application(URL), website(URL, URL), directory(URL) }
    var applications: [String: URL] = [:]
    var events: [Event] = []
    var failure: CornerActionExecutionError?
    func applicationURL(bundleID: String) -> URL? { events.append(.lookup(bundleID)); return applications[bundleID] }
    func openApplication(at url: URL) async throws { events.append(.application(url)); if let failure { throw failure } }
    func openWebsite(_ url: URL, in application: URL) async throws { events.append(.website(url, application)); if let failure { throw failure } }
    func openDirectory(_ url: URL) async throws { events.append(.directory(url)); if let failure { throw failure } }
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
