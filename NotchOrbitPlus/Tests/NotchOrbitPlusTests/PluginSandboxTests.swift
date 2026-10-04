import Foundation
import NotchCore
import XCTest
@testable import NotchOrbitPlus

final class PluginSandboxTests: XCTestCase, @unchecked Sendable {
    func testBundledSamplesDecodeWithoutRunningOrImportingThem() throws {
        let root = try XCTUnwrap(Bundle.main.url(forResource: "Plugins", withExtension: nil))
        let hello = try PlusPluginFolderIO.readPackage(root.appendingPathComponent("HelloOrbit"))
        let clipboard = try PlusPluginFolderIO.readPackage(root.appendingPathComponent("ClipboardLength"))
        XCTAssertEqual(hello.manifest.id, "hello-orbit"); XCTAssertTrue(hello.manifest.permissions.isEmpty)
        XCTAssertEqual(clipboard.manifest.permissions, [.clipboardRead])
        XCTAssertNotNil(hello.scripts["hello.sh"]); XCTAssertNotNil(clipboard.scripts["count.sh"])
    }
    func testImporterRejectsSymlinkScriptAndProfileHasNoAmbientUserNetworkAccess() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = directory.appendingPathComponent("plugin"); try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: false)
        try manifest().write(to: plugin.appendingPathComponent("manifest.json"))
        let outside = directory.appendingPathComponent("outside.sh"); try Data("printf '{}'".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: plugin.appendingPathComponent("hello.sh"), withDestinationURL: outside)
        XCTAssertThrowsError(try PlusPluginFolderIO.readPackage(plugin))
        let profile = try PlusPluginSandbox.profile(folder: plugin, writable: false, readFolders: [])
        XCTAssertTrue(profile.contains("(deny default)")); XCTAssertFalse(profile.contains("network"))
        XCTAssertFalse(profile.contains("process-fork")); XCTAssertFalse(profile.contains("file-write"))
        XCTAssertFalse(profile.contains(FileManager.default.homeDirectoryForCurrentUser.path))
    }
    func testSandboxRunsActualJSONAndDeniesWritingOutsidePluginFolder() async throws {
        guard PlusPluginSandbox.available else { throw XCTSkip("macOS sandbox-exec unavailable; production fails closed") }
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = directory.appendingPathComponent("plugin"); try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: false)
        let script = plugin.appendingPathComponent("hello.sh")
        try Data("printf '%s' '{\"items\":[{\"kind\":\"text\",\"text\":\"Actual shell fixture\"}]}'".utf8).write(to: script)
        let declaration = try CorePluginManifest.decode(manifest())
        let data = try await PlusPluginProcess().run(folder: plugin, command: declaration.commands[0], grants: [], readFolders: [], clipboard: nil)
        XCTAssertEqual(try CorePluginOutput.decode(data, manifest: declaration).items[0].text, "Actual shell fixture")
        let outside = directory.appendingPathComponent("original.txt"); let original = Data("preserved original".utf8); try original.write(to: outside)
        try Data("if printf changed > '\(outside.path)'; then printf ALLOWED; else printf BLOCKED; fi".utf8).write(to: script)
        let denied = try await PlusPluginProcess().run(folder: plugin, command: declaration.commands[0], grants: [], readFolders: [], clipboard: nil)
        XCTAssertTrue(String(decoding: denied, as: UTF8.self).contains("BLOCKED"))
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }
    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitPluginFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); return root
    }
    private func manifest() -> Data {
        Data(#"{"version":1,"id":"fixture","name":"Fixture","permissions":[],"items":[],"commands":[{"id":"hello","script":"hello.sh"}]}"#.utf8)
    }
}
