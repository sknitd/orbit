import Foundation
import XCTest
@testable import NotchCore

final class ContextActivityTests: XCTestCase {
    func testExplicitDownloadTotalProducesMeasuredProgressAndETAButRejectsInvalidEstimates() throws {
        let url = URL(fileURLWithPath: "/fixture/video.mov.part")
        let date = Date(timeIntervalSince1970: 1_000)
        var tracker = DownloadActivityTracker()
        tracker.observe([.init(url: url, identity: "same", bytes: 100, modifiedAt: date)], at: date)
        let id = try XCTUnwrap(tracker.activities.first?.id)
        try tracker.setExpectedTotal(200, forID: id)
        XCTAssertEqual(tracker.activities.first?.progress, 0.5)
        XCTAssertNil(tracker.activities.first?.estimatedRemaining)
        tracker.observe([.init(url: url, identity: "same", bytes: 150, modifiedAt: date.addingTimeInterval(2))], at: date.addingTimeInterval(2))
        XCTAssertEqual(tracker.activities.first?.bytesPerSecond, 25)
        XCTAssertEqual(tracker.activities.first?.progress, 0.75)
        XCTAssertEqual(tracker.activities.first?.estimatedRemaining, 2)
        for invalid: Int64 in [0, -1, 149, Int64.max] { XCTAssertThrowsError(try tracker.setExpectedTotal(invalid, forID: id)) }
        tracker.observe([.init(url: url, identity: "same", bytes: 150, modifiedAt: date.addingTimeInterval(3))], at: date.addingTimeInterval(3))
        XCTAssertEqual(tracker.activities.first?.bytesPerSecond, 0); XCTAssertNil(tracker.activities.first?.estimatedRemaining)
        tracker.observe([.init(url: url, identity: "same", bytes: 220, modifiedAt: date.addingTimeInterval(4))], at: date.addingTimeInterval(4))
        XCTAssertNil(tracker.activities.first?.progress); XCTAssertNil(tracker.activities.first?.estimatedRemaining)
        tracker.pause(); XCTAssertNil(tracker.activities.first?.bytesPerSecond)
    }
    func testContextUsesStablePriorityAndIgnoresDisabledOrHiddenTools() throws {
        XCTAssertFalse(ContextRule.defaults.isEmpty)
        XCTAssertTrue(ContextRule.defaults.allSatisfy { !$0.enabled })
        let first = ContextRule(name: "Meeting", trigger: .frontmostApp, appBundleID: "us.zoom.xos", toolID: "teleprompter")
        let music = ContextRule(name: "Music", trigger: .musicPlaying, toolID: "nowPlaying")
        let observation = ContextObservation(frontmostApp: "us.zoom.xos", runningApps: ["us.zoom.xos"], signals: .init(musicPlaying: true))
        XCTAssertEqual(ContextRuleSelection.proposal(rules: [first, music], observation: observation, visibleToolIDs: ["teleprompter", "nowPlaying"])?.id, first.id)
        XCTAssertEqual(ContextRuleSelection.proposal(rules: [first, music], observation: observation, visibleToolIDs: ["nowPlaying"])?.id, music.id)
        var disabled = first; disabled.enabled = false
        XCTAssertNil(ContextRuleSelection.proposal(rules: [disabled], observation: observation, visibleToolIDs: ["teleprompter"]))
        XCTAssertEqual(try JSONDecoder().decode(ContextRule.self, from: JSONEncoder().encode(first)), first)
    }
    func testFinderRuleNeedsActualInjectedDragAndRuleValidationRejectsUnsafeIdentifiers() {
        let rule = ContextRule(name: "Finder", trigger: .finderDrag, toolID: "workflows")
        XCTAssertNil(ContextRuleSelection.proposal(rules: [rule], observation: .init(frontmostApp: "com.apple.finder", runningApps: []), visibleToolIDs: ["workflows"]))
        XCTAssertEqual(ContextRuleSelection.proposal(rules: [rule], observation: .init(frontmostApp: "com.apple.finder", runningApps: [], signals: .init(finderDrag: true)), visibleToolIDs: ["workflows"])?.toolID, "workflows")
        XCTAssertThrowsError(try ContextRule(name: "Rule", trigger: .frontmostApp, appBundleID: "", toolID: "workflows").validated())
        XCTAssertThrowsError(try ContextRule(name: "Rule", trigger: .musicPlaying, toolID: "run /bin/sh").validated())
    }
    func testObservedPartialRenameRetainsRealFinalButNeverInventsTotalOrETA() {
        let partial = URL(fileURLWithPath: "/fixture/archive.zip.crdownload")
        let final = partial.deletingPathExtension()
        let date = Date(timeIntervalSince1970: 1_000)
        var tracker = DownloadActivityTracker()
        tracker.observe([.init(url: partial, identity: "1", bytes: 12, modifiedAt: date)], at: date)
        XCTAssertEqual(tracker.activities.first?.state, .active)
        XCTAssertNil(tracker.activities.first?.progress); XCTAssertNil(tracker.activities.first?.estimatedRemaining)
        tracker.observe([.init(url: final, identity: "1", bytes: 24, modifiedAt: date.addingTimeInterval(1))], at: date.addingTimeInterval(1))
        XCTAssertEqual(tracker.activities.first?.state, .completed)
        XCTAssertEqual(tracker.activities.first?.outputURL, final)
        XCTAssertEqual(tracker.activities.first?.byteCount, 24)
    }
    func testUnchangedPreexistingFinalAndRemovedPartialDoNotClaimCompletion() {
        let partial = URL(fileURLWithPath: "/fixture/file.zip.part")
        let final = DownloadFileObservation(url: partial.deletingPathExtension(), identity: "old", bytes: 20, modifiedAt: .distantPast)
        var tracker = DownloadActivityTracker()
        tracker.observe([final, .init(url: partial, identity: "new", bytes: 2, modifiedAt: Date())])
        tracker.observe([final])
        XCTAssertEqual(tracker.activities.first?.state, .removed)
        XCTAssertNil(tracker.activities.first?.outputURL)
        tracker.observe([.init(url: partial, identity: "new", bytes: 3, modifiedAt: Date())])
        tracker.pause(); XCTAssertEqual(tracker.activities.first?.state, .paused)
        tracker.observe([final]); XCTAssertEqual(tracker.activities.first?.state, .paused)
    }
    func testDirectoryPartialHasUnknownBytesAndExistingFinishedFilesDoNotBecomeActivities() {
        let date = Date()
        var tracker = DownloadActivityTracker()
        tracker.observe([.init(url: URL(fileURLWithPath: "/fixture/finished.zip"), identity: "1", bytes: 20, modifiedAt: date)])
        XCTAssertTrue(tracker.activities.isEmpty)
        tracker.observe([.init(url: URL(fileURLWithPath: "/fixture/movie.mov.download"), identity: "2", bytes: nil, modifiedAt: date, isDirectory: true)])
        XCTAssertNil(tracker.activities.first?.byteCount)
    }
    func testCommandMetadataRejectsOversizeUnknownKeysControlTextAndInvalidResults() throws {
        let now = Date(timeIntervalSince1970: 1_000); let id = UUID()
        let valid = CommandActivityMessage(kind: .start, id: id, label: "Build", at: 1_000)
        XCTAssertEqual(try CommandActivityMessage.decode(JSONEncoder().encode(valid), now: now), valid)
        XCTAssertThrowsError(try CommandActivityMessage.decode(Data(repeating: 32, count: 4_097), now: now))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["command"] = "arbitrary incoming command"
        XCTAssertThrowsError(try CommandActivityMessage.decode(JSONSerialization.data(withJSONObject: object), now: now))
        for message in [CommandActivityMessage(kind: .start, id: id, label: "two\nlines", at: 1_000),
                        .init(kind: .start, id: id, label: "Build", at: 1_301),
                        .init(kind: .finish, id: id, label: "Build", at: 1_000, exitCode: 256, duration: 1),
                        .init(kind: .finish, id: id, label: "Build", at: 1_000, exitCode: 0, duration: -.infinity)] {
            XCTAssertThrowsError(try message.validated(now: now))
        }
    }
    func testCommandFinishMustMatchObservedStartAndPauseDoesNotInventExit() throws {
        let now = Date(timeIntervalSince1970: 1_000); let id = UUID()
        var tracker = CommandActivityTracker()
        XCTAssertThrowsError(try tracker.accept(.init(kind: .finish, id: id, label: "Build", at: 1_001, exitCode: 0, duration: 1), now: now))
        try tracker.accept(.init(kind: .start, id: id, label: "Build", at: 1_000), now: now)
        XCTAssertThrowsError(try tracker.accept(.init(kind: .start, id: id, label: "Build", at: 1_000), now: now))
        try tracker.accept(.init(kind: .finish, id: id, label: "Build", at: 1_002, exitCode: 2, duration: 2), now: now)
        XCTAssertEqual(tracker.activities.first?.state, .failed)
        XCTAssertEqual(tracker.activities.first?.duration, 2)
        let running = UUID(); try tracker.accept(.init(kind: .start, id: running, label: "Tests", at: 1_000), now: now)
        tracker.pause(); XCTAssertEqual(tracker.activities.first?.state, .interrupted)
        XCTAssertNil(tracker.activities.first?.exitCode); XCTAssertNil(tracker.activities.first?.duration)
    }
}
