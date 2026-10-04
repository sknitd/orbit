import AppIntents
import Foundation
import UniformTypeIdentifiers
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class AppIntentEvaluationTests: NativeImageFixtureCase, @unchecked Sendable {
    @MainActor
    func testShortcutRegistryAndDashboardActionRequireAnInstalledHandler() throws {
        XCTAssertEqual(PlusAppShortcuts.appShortcuts.count, 5)
        let coordinator = PlusIntentCoordinator()
        XCTAssertThrowsError(try coordinator.toggle())
        var called = 0
        coordinator.toggleDashboard = { called += 1 }
        try coordinator.toggle()
        XCTAssertEqual(called, 1)
    }
    @MainActor
    func testMemoryFileIsMaterializedOnlyDuringTheExplicitAction() async throws {
        let original = Data("Shortcut fixture".utf8)
        let file = IntentFile(data: original, filename: "fixture.txt", type: .plainText)
        let temporary = try await PlusIntentCoordinator.withFile(file) { url in
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(url.lastPathComponent, "fixture.txt")
            return url
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
    }
    @MainActor
    func testRealFileIsPreservedAndOversizedOrLinkedInputsNeverReachTheAction() async throws {
        let source = fixtureDirectory.appendingPathComponent("source.txt")
        let bytes = Data("Untouched original".utf8)
        try bytes.write(to: source)
        let result = try await PlusIntentCoordinator.withFile(IntentFile(fileURL: source)) { url in
            XCTAssertEqual(url, source)
            return try Data(contentsOf: url)
        }
        XCTAssertEqual(result, bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let linked = fixtureDirectory.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
        let oversized = fixtureDirectory.appendingPathComponent("oversized.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(PlusIntentValidation.maximumFileBytes + 1)); try handle.close()
        for url in [linked, oversized] {
            do {
                _ = try await PlusIntentCoordinator.withFile(IntentFile(fileURL: url)) { _ in
                    XCTFail("Invalid inputs must not invoke the Shortcut action")
                    return false
                }
                XCTFail("Expected invalid Shortcut file")
            } catch { XCTAssertTrue(error is PlusIntentFailure) }
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
}
