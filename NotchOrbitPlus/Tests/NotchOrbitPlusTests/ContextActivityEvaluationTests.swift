import AppKit
import Foundation
import SwiftUI
import Darwin
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class ContextActivityEvaluationTests: NativeImageFixtureCase, @unchecked Sendable {
    @MainActor
    func testDisabledServicesNeverStartObservationOrListenerWhenViewsBecomeVisible() throws {
        let name = "NotchOrbitPlus.ContextTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let context = ContextService(defaults: defaults)
        let downloads = DownloadsService(folderURL: fixtureDirectory)
        let commands = CommandsService()
        var proposals = 0
        context.onProposal = { _ in proposals += 1 }
        context.resume(); downloads.resume(); commands.resume()
        XCTAssertFalse(context.enabled); XCTAssertFalse(context.isSampling)
        XCTAssertTrue(context.rules.allSatisfy { !$0.enabled })
        XCTAssertFalse(downloads.enabled); XCTAssertFalse(downloads.isSampling)
        XCTAssertFalse(commands.enabled); XCTAssertFalse(commands.isListening)
        XCTAssertFalse(context.backgroundMonitoring); XCTAssertFalse(downloads.backgroundMonitoring); XCTAssertFalse(commands.backgroundMonitoring)
        XCTAssertEqual(proposals, 0)
        XCTAssertTrue(downloads.activities.isEmpty); XCTAssertTrue(commands.activities.isEmpty)
        context.shutdown(); downloads.shutdown(); commands.shutdown()
    }

    func testPrivateFolderObservationRetainsActualRenameAndNeverDeletesEitherFile() throws {
        let partial = fixtureDirectory.appendingPathComponent("artifact.zip.crdownload")
        let bytes = Data("a real partial download fixture".utf8)
        try bytes.write(to: partial)
        let prior = fixtureDirectory.appendingPathComponent("older.zip")
        let existing = Data("older file retained".utf8); try existing.write(to: prior)
        var tracker = DownloadActivityTracker()
        let sampleTime = Date(timeIntervalSince1970: 1_000)
        tracker.observe(try DownloadFolderReader.read(fixtureDirectory), at: sampleTime)
        XCTAssertEqual(tracker.activities.count, 1)
        XCTAssertEqual(tracker.activities.first?.byteCount, Int64(bytes.count))
        XCTAssertNil(tracker.activities.first?.progress)
        let activityID = try XCTUnwrap(tracker.activities.first?.id)
        try tracker.setExpectedTotal(Int64(bytes.count * 3), forID: activityID)
        let writer = try FileHandle(forWritingTo: partial)
        try writer.seekToEnd(); try writer.write(contentsOf: bytes); try writer.close()
        tracker.observe(try DownloadFolderReader.read(fixtureDirectory), at: sampleTime.addingTimeInterval(2))
        XCTAssertEqual(try XCTUnwrap(tracker.activities.first?.progress), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(tracker.activities.first?.bytesPerSecond, Double(bytes.count) / 2)
        XCTAssertEqual(tracker.activities.first?.estimatedRemaining, 2)
        let final = partial.deletingPathExtension()
        try FileManager.default.moveItem(at: partial, to: final)
        tracker.observe(try DownloadFolderReader.read(fixtureDirectory))
        XCTAssertEqual(tracker.activities.first?.state, .completed)
        XCTAssertEqual(tracker.activities.first?.outputURL, final)
        XCTAssertEqual(try Data(contentsOf: final), bytes + bytes)
        XCTAssertEqual(try Data(contentsOf: prior), existing)
    }

    @MainActor
    func testCommandListenerRapidHideShowAndDisableEnableHaveDeterministicTeardown() {
        let service = CommandsService()
        defer { service.shutdown() }
        service.resume(); service.enable()
        XCTAssertTrue(service.isListening, service.error ?? "Listener did not start")
        service.stop(); XCTAssertFalse(service.isListening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.socketURL.path))
        service.resume(); XCTAssertTrue(service.isListening, service.error ?? "Listener did not reopen")
        service.disable(); XCTAssertFalse(service.isListening)
        service.enable(); XCTAssertTrue(service.isListening, service.error ?? "Listener did not re-enable")
        service.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.socketURL.path))
    }

    func testInstalledHelpersReportRealExplicitCommandThroughOwnedPrivateSocket() async throws {
        let helpers = fixtureDirectory.appendingPathComponent("CLI", isDirectory: true)
        try CommandHelpers.install(in: helpers)
        let ledger = CommandSocketFixtureLedger()
        let listener = try CommandSocketListener(receive: { ledger.append($0) }, failure: { ledger.failure($0) })
        defer { listener.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: listener.socketURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, getuid())
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: CommandSocketListener.directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", helpers.appendingPathComponent("orbit-run").path, "--label", "Native fixture command", "--", "/usr/bin/true"]
        let diagnostics = Pipe(); process.standardError = diagnostics
        try process.run(); process.waitUntilExit()
        let diagnosticText = String(data: diagnostics.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, diagnosticText)
        for _ in 0..<20 {
            if ledger.snapshot().0.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let (messages, failures) = ledger.snapshot()
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: ", "))
        XCTAssertEqual(messages.count, 2, diagnosticText)
        let start = try CommandActivityMessage.decode(XCTUnwrap(messages.first))
        let finish = try CommandActivityMessage.decode(XCTUnwrap(messages.last))
        XCTAssertEqual(start.kind, .start); XCTAssertEqual(finish.kind, .finish)
        XCTAssertEqual(start.id, finish.id); XCTAssertEqual(finish.exitCode, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(finish.duration), 0)
        var tracker = CommandActivityTracker(); try tracker.accept(start); try tracker.accept(finish)
        XCTAssertEqual(tracker.activities.first?.state, .succeeded)
        // A command-shaped packet is rejected as metadata, with no execution API in the receiver.
        XCTAssertThrowsError(try CommandActivityMessage.decode(Data("{\"command\":\"arbitrary command\"}".utf8)))
    }

    @MainActor
    func testRealDefaultContextAndActivityViewsRenderWithoutEnablingServices() async throws {
        let name = "NotchOrbitPlus.ContextRender.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let context = ContextService(defaults: defaults)
        let downloads = DownloadsService(folderURL: fixtureDirectory)
        let commands = CommandsService()
        for (name, view) in [("Context", AnyView(ContextToolView(service: context))),
                             ("Downloads", AnyView(DownloadsToolView(service: downloads))),
                             ("Commands", AnyView(CommandsToolView(service: commands)))] {
            try await NativeFeatureEvaluation.render(AnyView(view.padding(16)), named: "NotchOrbitPlus-\(name)-disabled.png", size: NSSize(width: 560, height: 500))
        }
        XCTAssertFalse(context.isSampling); XCTAssertFalse(downloads.isSampling); XCTAssertFalse(commands.isListening)
        context.shutdown(); downloads.shutdown(); commands.shutdown()
    }
}

private final class CommandSocketFixtureLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Data] = []
    private var errors: [String] = []
    func append(_ bytes: Data) { lock.lock(); data.append(bytes); lock.unlock() }
    func failure(_ text: String) { lock.lock(); errors.append(text); lock.unlock() }
    func snapshot() -> ([Data], [String]) { lock.lock(); defer { lock.unlock() }; return (data, errors) }
}
