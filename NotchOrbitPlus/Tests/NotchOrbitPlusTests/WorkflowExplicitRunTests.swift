import Foundation
import NotchCore
import OrbitCore
import XCTest
@testable import NotchOrbitPlus

final class WorkflowExplicitRunTests: NativeImageFixtureCase, @unchecked Sendable {
    @MainActor
    func testExplicitAwaitPublishesDurableOutputOutsideTemporaryInputAndPreservesPreference() async throws {
        let suite = "NotchOrbitPlus.ExplicitWorkflow.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkflowStore(defaults: defaults, onPortableChange: {})
        let preset = WorkflowPreset(name: "Capture bundle", steps: [.zip]); XCTAssertTrue(store.save(preset))
        let temporaryInput = fixtureDirectory.appendingPathComponent("intent-staging", isDirectory: true)
        let durable = fixtureDirectory.appendingPathComponent("durable", isDirectory: true)
        let preference = fixtureDirectory.appendingPathComponent("preference", isDirectory: true)
        for directory in [temporaryInput, durable, preference] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        let fixture = try rasterFile(named: "original.png", width: 32, height: 16)
        let source = temporaryInput.appendingPathComponent("memory.png"); try FileManager.default.copyItem(at: fixture, to: source)
        let original = try Data(contentsOf: source); store.outputDirectory = preference
        let outputs = try await store.runAndWaitExplicitly([source], presetID: preset.id, outputDirectoryOverride: durable)
        let result = try XCTUnwrap(outputs.first)
        XCTAssertEqual(result.deletingLastPathComponent().resolvingSymlinksInPath(), durable.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: source), original); XCTAssertEqual(store.outputDirectory, preference)
        XCTAssertFalse(store.isRunning); XCTAssertNil(store.error); XCTAssertEqual(store.outputURLs, outputs)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: preference.path).isEmpty)
        try FileManager.default.removeItem(at: temporaryInput)
        XCTAssertGreaterThan(try ZIPInspector.inspect(result).entryCount, 0)
    }
    @MainActor
    func testExplicitAwaitForwardsPublicationFailureWithoutSuccessCallbackOrSourceReplacement() async throws {
        let suite = "NotchOrbitPlus.ExplicitFailure.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkflowStore(defaults: defaults, onPortableChange: {})
        let preset = WorkflowPreset(name: "Capture delivery", steps: [.convert(format: .jpeg)]); XCTAssertTrue(store.save(preset))
        let source = try rasterFile(named: "source.png", width: 32, height: 16), original = try Data(contentsOf: source)
        let blocker = fixtureDirectory.appendingPathComponent("output-is-a-file"), blockingBytes = Data("preserve blocking file".utf8)
        try blockingBytes.write(to: blocker)
        var completions = 0; store.onCompleted = { _ in completions += 1 }
        do { _ = try await store.runAndWaitExplicitly([source], presetID: preset.id, outputDirectoryOverride: blocker); XCTFail("Expected actual publication failure") }
        catch { XCTAssertNotNil(store.error) }
        XCTAssertEqual(completions, 0); XCTAssertFalse(store.isRunning); XCTAssertTrue(store.outputURLs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original); XCTAssertEqual(try Data(contentsOf: blocker), blockingBytes)
    }
}
