import Foundation
import XCTest
@testable import NotchCore

final class PlatformBehaviorTests: XCTestCase {
    func testFocusPreviewExcludesSelfHiddenUnchosenAndDuplicateProcesses() throws {
        let config = FocusAppConfiguration(enabled: true, bundleIDs: ["com.example.Editor"])
        try config.validate()
        let values = [FocusAppSnapshot(processID: 1, bundleID: "com.example.Editor", hidden: false, launchDate: Date(timeIntervalSince1970: 1)),
                      .init(processID: 2, bundleID: "com.example.Editor", hidden: true, launchDate: Date(timeIntervalSince1970: 1)),
                      .init(processID: 3, bundleID: "com.example.Other", hidden: false, launchDate: Date(timeIntervalSince1970: 1)),
                      .init(processID: 4, bundleID: "com.example.Editor", hidden: false, launchDate: Date(timeIntervalSince1970: 1))]
        XCTAssertEqual(FocusAppPolicy.hideCandidates(configuration: config, running: values + values, ownProcessID: 1).map(\.processID), [4])
        XCTAssertTrue(FocusAppPolicy.hideCandidates(configuration: .init(), running: values, ownProcessID: 0).isEmpty)
    }
    func testFocusRestoreOnlyOwnsSameProcessAndBundleStillHidden() {
        let owned = [FocusAppSnapshot(processID: 4, bundleID: "com.example.Editor", hidden: false, launchDate: Date(timeIntervalSince1970: 1))]
        XCTAssertTrue(FocusAppPolicy.restoreCandidates(owned: owned, running: [.init(processID: 4, bundleID: "com.example.Other", hidden: true, launchDate: Date(timeIntervalSince1970: 1))]).isEmpty)
        XCTAssertTrue(FocusAppPolicy.restoreCandidates(owned: owned, running: [.init(processID: 4, bundleID: "com.example.Editor", hidden: false, launchDate: Date(timeIntervalSince1970: 1))]).isEmpty)
        XCTAssertEqual(FocusAppPolicy.restoreCandidates(owned: owned, running: [.init(processID: 4, bundleID: "com.example.Editor", hidden: true, launchDate: Date(timeIntervalSince1970: 1))]).count, 1)
    }
    func testFocusSettingsBoundAndValidateIdentifiers() throws {
        let value = FocusAppConfiguration(enabled: true, bundleIDs: ["com.example.Editor"])
        XCTAssertEqual(try FocusAppConfiguration.decode(JSONEncoder().encode(value)), value)
        XCTAssertThrowsError(try FocusAppConfiguration(bundleIDs: ["../bad"]).validate())
        XCTAssertThrowsError(try FocusAppConfiguration(bundleIDs: ["com.a.App", "com.a.App"]).validate())
    }
    func testLauncherDropRejectsNonAppsRemoteURLsAndDuplicateInput() throws {
        let file = URL(fileURLWithPath: "/tmp/input.txt")
        try LauncherDropPolicy.validate(kind: .application, urls: [file])
        XCTAssertThrowsError(try LauncherDropPolicy.validate(kind: .folder, urls: [file]))
        XCTAssertThrowsError(try LauncherDropPolicy.validate(kind: .application, urls: [file, file]))
        XCTAssertThrowsError(try LauncherDropPolicy.validate(kind: .application, urls: [URL(string: "https://example.com/file")!]))
    }
    func testLegacyPriorityMigratesWithoutChangingExistingRelativeOrder() throws {
        let legacy = ["music", "meeting", "focus", "processing", "hud", "devices", "status"]
        let data = try JSONSerialization.data(withJSONObject: ["order": legacy])
        let value = try LiveNotchPriorityConfiguration.decode(data)
        XCTAssertEqual(Array(value.order.prefix(7)).map(\.rawValue), legacy)
        XCTAssertEqual(Set(value.order), Set(LiveNotchKind.allCases))
        XCTAssertThrowsError(try LiveNotchPriorityConfiguration.decode(Data("{\"order\":[\"music\",\"music\"]}".utf8)))
    }
    func testNewActivitiesRespectCustomPriorityAndBoundActualWaveform() throws {
        let code = LiveNotchStatus(id: "code", kind: .verificationCode, title: "123456", toolID: "verificationCodes")
        let download = LiveNotchStatus(id: "download", kind: .downloads, title: "archive", toolID: "downloads")
        let order = [.downloads] + LiveNotchKind.defaultOrder.filter { $0 != .downloads }
        XCTAssertEqual(LiveNotchSelection.ordered([code, download], priorityOrder: order).first?.kind, .downloads)
        let wave = LiveNotchStatus(id: "voice", kind: .dictation, title: "Recording", toolID: "dictation", waveform: [.nan, -.infinity, -1, 0.5, 2])
        XCTAssertEqual(wave.waveform, [0, 0.5, 1])
    }
}
