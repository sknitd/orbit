import AppKit
import CryptoKit
import SwiftUI
import XCTest
import OrbitCore
import NotchCore
@testable import NotchOrbitPlus

final class DistributionEvaluationTests: NativeImageFixtureCase, @unchecked Sendable {
    @MainActor
    func testActualOnboardingAndUpdateSettingsRenderWithoutInvokingSetupActions() async throws {
        let onboarding = PlusOnboardingView(requestAccess: {
            XCTFail("Rendering onboarding must not request Input Monitoring")
        }, onFinish: { _ in
            XCTFail("Rendering onboarding must not finish the user's choices")
        })
        try await render(AnyView(onboarding), name: "NotchOrbitPlus-Onboarding.png")
        try await render(AnyView(PlusDistributionSettingsView()), name: "NotchOrbitPlus-Distribution.png")
    }

    @MainActor
    func testUnsignedArchiveCannotReplaceTheRunningAppAndItsBytesRemainIntact() async throws {
        let candidate = fixtureDirectory.appendingPathComponent("NotchOrbitPlus.app", isDirectory: true)
        let contents = candidate.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.sknitd.NotchOrbitPlus", "CFBundleExecutable": "NotchOrbitPlus",
            "CFBundleShortVersionString": "9.9.9", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let executable = executableDirectory.appendingPathComponent("NotchOrbitPlus")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let archiveResult = try await ArchiveEngine().perform(.zip, items: FileInspector.inspect([candidate]),
                                                              context: .init())
        let archive = try XCTUnwrap(archiveResult.outputs.first)
        let archiveBytes = try Data(contentsOf: archive)
        let feed = try updateFeed(archive: archiveBytes)
        let current = Bundle.main.bundleURL
        let currentInfoURL = current.appendingPathComponent("Contents/Info.plist")
        let currentExecutable = try XCTUnwrap(Bundle.main.executableURL)
        let infoBefore = try Data(contentsOf: currentInfoURL)
        let executableHash = SHA256.hash(data: try Data(contentsOf: currentExecutable))
        let trustedHost = (try? PlusUpdateInstaller.currentTrustedTeamIdentifier()) != nil
        for automatic in [false, true] {
            do {
                _ = try PlusUpdateInstaller.install(archive: archive, feed: feed, automatic: automatic)
                XCTFail("An unsigned archive must never replace the running application")
            } catch let failure as PlusUpdateInstallError {
                let expected: PlusUpdateInstallError = trustedHost
                    ? (automatic ? .notNotarized : .untrustedCandidate) : .untrustedCurrentApplication
                XCTAssertEqual(failure, expected)
            } catch { XCTFail("Unexpected installer failure: \(error.localizedDescription)") }
        }
        XCTAssertEqual(try Data(contentsOf: currentInfoURL), infoBefore)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: currentExecutable)), executableHash)
        XCTAssertEqual(try Data(contentsOf: archive), archiveBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    }

    private func updateFeed(archive: Data) throws -> CoreUpdateFeed {
        let source = String(repeating: "a", count: 40)
        let checksum = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let fields: [String: Any] = [
            "schema_version": 1, "product": "NotchOrbitPlus", "bundle_identifier": "com.sknitd.NotchOrbitPlus",
            "version": "9.9.9", "minimum_macos": "14.0", "source_commit": source,
            "archive_url": "https://raw.githubusercontent.com/sknitd/orbit/codex/notch-plus-updates/packages/9.9.9/\(source)/NotchOrbitPlus.app.zip",
            "archive_sha256": checksum, "archive_bytes": archive.count,
            "release_notes_url": "https://github.com/sknitd/orbit/tree/\(source)/NotchOrbitPlus",
            "published_at": "2026-10-04T00:00:00Z", "signing": ["kind": "adhoc", "notarized": false]
        ]
        return try CoreUpdateFeed.decode(JSONSerialization.data(withJSONObject: fields))
    }

    @MainActor
    private func render(_ view: AnyView, name: String) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 560)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 560)
        XCTAssertGreaterThan(png.count, 1_000)
        let directory = evaluationDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func evaluationDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["NOTCHORBITPLUS_EVAL_DIR"]
            ?? environment["TEST_RUNNER_NOTCHORBITPLUS_EVAL_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build", isDirectory: true).appendingPathComponent("evaluation", isDirectory: true)
    }
}
