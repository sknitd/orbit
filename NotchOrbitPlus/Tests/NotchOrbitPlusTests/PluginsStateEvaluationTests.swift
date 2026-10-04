import AppKit
import SwiftUI
import XCTest
@testable import NotchOrbitPlus

final class PluginsStateEvaluationTests: XCTestCase {
    @MainActor
    func testDisablingImmediatelyAfterImportStartsCannotPublishPluginFilesOrDeclarations() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = PlusPluginsStore(storageDirectory: fixture.storage, loadSaved: false)
        defer { store.shutdown() }
        XCTAssertFalse(store.enabled); XCTAssertTrue(store.plugins.isEmpty)
        store.install(fixture.source)
        XCTAssertFalse(store.installing, "Disabled installation must not schedule any file import")
        store.enabled = true; store.install(fixture.source)
        XCTAssertTrue(store.installing)
        store.enabled = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(store.busy); XCTAssertTrue(store.plugins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storage.appendingPathComponent("installed.json").path))
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.storage.path)
        XCTAssertTrue(entries.isEmpty, "Cancellation before publication must leave no imported folder")
        XCTAssertTrue(store.output.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent("manifest.json")), fixture.manifest)
    }

    @MainActor
    func testRegistryPublicationObstructionRollsBackOnlyTheNewPluginAndKeepsTheObstruction() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let obstruction = fixture.storage.appendingPathComponent("installed.json", isDirectory: true)
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: false)
        let preserved = Data("Do not replace this unrelated directory".utf8)
        try preserved.write(to: obstruction.appendingPathComponent("original.txt"))
        let store = PlusPluginsStore(storageDirectory: fixture.storage, loadSaved: false)
        defer { store.shutdown() }
        store.enabled = true; store.install(fixture.source)
        try await NativeFeatureEvaluation.waitUntil("The obstructed import finishes safely", condition: { !store.busy })
        XCTAssertTrue(store.plugins.isEmpty, "A failed save must not leave a dangling in-memory plugin")
        XCTAssertNotNil(store.message)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.storage.path)), ["installed.json"])
        XCTAssertEqual(try Data(contentsOf: obstruction.appendingPathComponent("original.txt")), preserved)
        XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent("manifest.json")), fixture.manifest)
    }

    @MainActor
    func testMalformedRegistryBlocksImportsUntilExplicitResetKeepsExactBackup() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = Data("{ malformed original declarations".utf8)
        let index = fixture.storage.appendingPathComponent("installed.json")
        try original.write(to: index)
        let store = PlusPluginsStore(storageDirectory: fixture.storage)
        defer { store.shutdown() }
        XCTAssertTrue(store.requiresReset); XCTAssertTrue(store.plugins.isEmpty)
        XCTAssertEqual(try Data(contentsOf: index), original)
        store.enabled = true; store.install(fixture.source)
        XCTAssertFalse(store.installing)
        XCTAssertEqual(try Data(contentsOf: index), original)
        try await NativeFeatureEvaluation.render(AnyView(PluginsToolView(store: store)),
            named: "NotchOrbitPlus-Plugins-fixture-preserved-registry.png")
        // Let the owned window's deferred final-hidden callback finish before a new explicit import.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(try Data(contentsOf: index), original, "Viewing repair controls must never write the registry")
        store.resetWithBackup()
        XCTAssertFalse(store.requiresReset)
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.storage, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("installed-") && $0.lastPathComponent.hasSuffix(".backup.json") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        XCTAssertEqual(try Data(contentsOf: index), Data("[]".utf8))
        store.install(fixture.source)
        try await NativeFeatureEvaluation.waitUntil("The explicit import succeeds after backed-up reset", condition: { !store.busy })
        XCTAssertEqual(store.plugins.count, 1)
        XCTAssertEqual(store.plugins.first?.manifest.id, "evaluation-only")
        XCTAssertTrue(try XCTUnwrap(store.plugins.first).grants.isEmpty)
        XCTAssertEqual(try Data(contentsOf: backups[0]), original)
        XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent("manifest.json")), fixture.manifest)
    }

    private func makeFixture() throws -> (root: URL, source: URL, storage: URL, manifest: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginStateEvaluation-\(UUID())", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let storage = root.appendingPathComponent("Stored", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let manifest = Data("{\"version\":1,\"id\":\"evaluation-only\",\"name\":\"Evaluation fixture\",\"permissions\":[],\"items\":[{\"kind\":\"text\",\"text\":\"No command or private inputs\"}],\"commands\":[]}".utf8)
        try manifest.write(to: source.appendingPathComponent("manifest.json"))
        return (root, source, storage, manifest)
    }
}
