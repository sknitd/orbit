import AppKit
import Foundation
import NotchCore
import XCTest
@testable import NotchOrbitPlus

final class LauncherBookmarkTests: XCTestCase {
    func testRealFolderBookmarkRoundTripAndMissingTargetReporting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pin = try PlusLauncherBookmarks.makePin(at: directory, kind: .folder)
        let saved = try PlusLauncherPins.decode(PlusLauncherPins.encode([pin]))
        let resolved = try PlusLauncherBookmarks.resolve(try XCTUnwrap(saved.first))
        XCTAssertEqual(resolved.url.resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
        XCTAssertEqual(try resolved.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        try FileManager.default.removeItem(at: directory)
        XCTAssertThrowsError(try PlusLauncherBookmarks.resolve(pin))
    }

    func testRegularFileAndFolderCannotBePinnedAsApplications() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchLauncherTypes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.txt")
        try Data("original bytes".utf8).write(to: file)
        XCTAssertThrowsError(try PlusLauncherBookmarks.makePin(at: directory, kind: .application))
        XCTAssertThrowsError(try PlusLauncherBookmarks.makePin(at: file, kind: .application))
        XCTAssertThrowsError(try PlusLauncherBookmarks.makePin(at: file, kind: .folder))
        XCTAssertEqual(try Data(contentsOf: file), Data("original bytes".utf8))
    }

    @MainActor
    func testInstalledApplicationResolvesWithoutLaunchingIt() throws {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw XCTSkip("Terminal is unavailable on this runner.")
        }
        let before = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.Terminal" }.map(\.processIdentifier))
        let pin = try PlusLauncherBookmarks.makePin(at: application, kind: .application)
        let resolved = try PlusLauncherBookmarks.resolve(pin)
        XCTAssertEqual(Bundle(url: resolved.url)?.bundleIdentifier, "com.apple.Terminal")
        XCTAssertEqual(try resolved.url.resourceValues(forKeys: [.isApplicationKey]).isApplication, true)
        XCTAssertThrowsError(try PlusLauncherBookmarks.makePin(at: application, kind: .folder))
        XCTAssertEqual(Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.Terminal" }.map(\.processIdentifier)), before,
                       "Bookmark resolution must never launch an application")
    }
}
