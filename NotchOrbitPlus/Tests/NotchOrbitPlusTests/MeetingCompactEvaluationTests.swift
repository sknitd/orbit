import AppKit
import SwiftUI
import XCTest
import EventKit
import NotchCore
@testable import NotchOrbitPlus

final class MeetingCompactEvaluationTests: XCTestCase {
    @MainActor
    func testMeetingInitializationAndRefreshNeverOpenAJoinLink() throws {
        let suite = "MeetingExplicitJoin-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var opened: [URL] = []
        let service = PlusMeetingService(defaults: defaults, opener: { opened.append($0); return true })
        XCTAssertFalse(service.liveEnabled)
        service.start(); service.refresh(); service.shutdown()
        XCTAssertTrue(opened.isEmpty)
        let now = Date(timeIntervalSince1970: 20_000)
        let url = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
        let meeting = OrbitMeeting(id: "upcoming", title: "Design review", start: now.addingTimeInterval(300),
                                   end: now.addingTimeInterval(3_600), joinURL: url)
        XCTAssertTrue(service.join(meeting, at: now))
        XCTAssertEqual(opened, [url])
        XCTAssertFalse(service.join(meeting, at: now.addingTimeInterval(3_600)))
        XCTAssertEqual(opened, [url])
    }

    @MainActor
    func testUnsafeOrMissingMeetingLinksAndFailedOpenCannotReportJoined() throws {
        let suite = "MeetingRejectedJoin-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let service = PlusMeetingService(defaults: defaults, opener: { _ in calls += 1; return false })
        let now = Date()
        for value in [nil, URL(string: "file:///tmp/run"), URL(string: "https://meet.google.com.evil.example/room")] {
            XCTAssertFalse(service.join(OrbitMeeting(id: "invalid", title: "Rejected", start: now,
                end: now.addingTimeInterval(600), joinURL: value), at: now))
        }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(service.join(OrbitMeeting(id: "valid", title: "Unavailable browser", start: now,
            end: now.addingTimeInterval(600), joinURL: URL(string: "https://zoom.us/j/123")), at: now))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(service.status.contains("could not open"))
    }

    @MainActor
    func testActualEventKitProjectionExtractsMeetingLinksFromNotes() throws {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "Calendar projection"
        event.startDate = Date(timeIntervalSince1970: 100_000)
        event.endDate = event.startDate.addingTimeInterval(1_800)
        event.notes = "Join our review: https://teams.microsoft.com/l/meetup-join/fixture"
        let projected = try XCTUnwrap(PlusMeetingService.meeting(from: event))
        XCTAssertEqual(projected.title, event.title)
        XCTAssertEqual(projected.joinURL?.host, "teams.microsoft.com")
        XCTAssertEqual(MeetingPlanner.upcoming([projected], at: event.startDate).count, 1)
        event.isAllDay = true
        XCTAssertTrue(MeetingPlanner.upcoming([try XCTUnwrap(PlusMeetingService.meeting(from: event))], at: event.startDate).isEmpty)
    }

    @MainActor
    func testNativeCompactFixturesRenderAllActivitiesAndPriorityTransitions() throws {
        let music = LiveNotchStatus(id: "music", kind: .music, title: "Fixture song", detail: "Fixture artist", toolID: "nowPlaying")
        let meeting = LiveNotchStatus(id: "meeting", kind: .meeting, title: "Fixture review", detail: "in 5m", toolID: "calendar")
        let focus = LiveNotchStatus(id: "focus", kind: .focus, title: "24:30", detail: "Focus", toolID: "timers")
        let processing = LiveNotchStatus(id: "job", kind: .processing, title: "Compressing photos", detail: "3 of 5", toolID: "workflows", progress: 0.6)
        let fixtures: [(String, [LiveNotchStatus])] = [
            ("idle", []), ("music", [music]), ("meeting", [meeting, music]),
            ("processing", [music, focus, meeting, processing]), ("completed", [music, focus, meeting])
        ]
        let environment = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: environment["NOTCHORBITPLUS_EVAL_DIR"]
            ?? environment["TEST_RUNNER_NOTCHORBITPLUS_EVAL_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("NotchOrbitPlus-evaluation").path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, statuses) in fixtures {
            let view = NSHostingView(rootView: LiveCompactContent(statuses: statuses)
                .padding(.horizontal, 12).frame(width: 260, height: 38).background(.black).foregroundStyle(.white))
            view.frame = NSRect(x: 0, y: 0, width: 260, height: 38)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 200)
            try png.write(to: output.appendingPathComponent("NotchOrbitPlus-Compact-fixture-\(name).png"))
        }
        XCTAssertEqual(LiveNotchSelection.ordered(fixtures[3].1).first?.toolID, "workflows")
        XCTAssertEqual(LiveNotchSelection.ordered(fixtures[4].1).first?.toolID, "calendar")
    }
}
