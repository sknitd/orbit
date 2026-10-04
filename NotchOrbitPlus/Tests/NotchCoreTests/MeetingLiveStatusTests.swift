import XCTest
@testable import NotchCore

final class MeetingLiveStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testUpcomingPrioritizesOngoingAndFiltersExpiredAllDayAndInvalidRanges() {
        let ongoing = OrbitMeeting(id: "ongoing", title: "Meeting", start: now.addingTimeInterval(-30), end: now.addingTimeInterval(30))
        let next = OrbitMeeting(id: "next", title: "Next", start: now.addingTimeInterval(120), end: now.addingTimeInterval(240))
        let expired = OrbitMeeting(id: "expired", title: "Old", start: now.addingTimeInterval(-60), end: now)
        let allDay = OrbitMeeting(id: "allday", title: "Birthday", start: now, end: now.addingTimeInterval(3600), isAllDay: true)
        let invalid = OrbitMeeting(id: "invalid", title: "Bad", start: now, end: now.addingTimeInterval(-1))
        XCTAssertEqual(MeetingPlanner.upcoming([next, expired, allDay, invalid, ongoing], at: now).map(\.id), ["ongoing", "next"])
        XCTAssertEqual(MeetingPlanner.upcoming([ongoing, next], at: now.addingTimeInterval(31)).first?.id, "next")
    }
    func testCountdownRecoversAcrossSleepAndMeetingEnd() {
        let meeting = OrbitMeeting(id: "m", title: "Call", start: now.addingTimeInterval(300), end: now.addingTimeInterval(600))
        XCTAssertEqual(meeting.countdown(at: now), "in 5m")
        XCTAssertEqual(meeting.countdown(at: now.addingTimeInterval(270)), "in 30s")
        XCTAssertEqual(meeting.countdown(at: now.addingTimeInterval(330)), "Now")
        XCTAssertEqual(meeting.countdown(at: now.addingTimeInterval(600)), "Ended")
    }
    func testJoinLinksRejectUnsafeSchemesCredentialsLookalikeHostsAndPorts() {
        for value in ["file:///tmp/meeting", "javascript:alert(1)", "https://zoom.us.evil.test/j/123", "https://evilzoom.us/j/123", "https://user:password@zoom.us/j/123", "https://zoom.us:8443/j/123", "https://zoom.us/"] {
            XCTAssertNil(MeetingLinkResolver.validated(URL(string: value)), value)
        }
        for value in ["https://us02web.zoom.us/j/123?pwd=abc", "https://meet.google.com/abc-defg-hij", "https://teams.microsoft.com/l/meetup-join/id", "https://example.webex.com/meet/person"] {
            XCTAssertNotNil(MeetingLinkResolver.validated(URL(string: value)), value)
        }
    }
    func testJoinURLCanComeFromCalendarLocationOrNotes() {
        let zoom = URL(string: "https://zoom.us/j/123")!
        XCTAssertEqual(MeetingLinkResolver.find(eventURL: zoom, location: "https://meet.google.com/abc-defg-hij", notes: nil), zoom)
        XCTAssertEqual(MeetingLinkResolver.find(eventURL: URL(string: "https://calendar.google.com/event?id=x"), location: nil,
            notes: "Join: https://zoom.us/j/123.\nAgenda"), zoom)
        XCTAssertNil(MeetingLinkResolver.find(eventURL: nil, location: "Conference Room A", notes: "No meeting link"))
    }
    func testLiveStatusShowsJobThenMeetingThenFocusThenMusicAndReturnsAfterCompletion() {
        let music = LiveNotchStatus(id: "music", kind: .music, title: "Track", toolID: "nowPlaying")
        let focus = LiveNotchStatus(id: "focus", kind: .focus, title: "12:00", toolID: "timers")
        let meeting = LiveNotchStatus(id: "meeting", kind: .meeting, title: "Call in 5m", toolID: "calendar")
        let job = LiveNotchStatus(id: "job", kind: .processing, title: "Converting", toolID: "fileActions", progress: 0.4)
        XCTAssertEqual(LiveNotchSelection.ordered([music, focus, meeting, job]).map(\.id), ["job", "meeting", "focus", "music"])
        XCTAssertEqual(LiveNotchSelection.ordered([music, focus, meeting]).first?.id, "meeting")
        XCTAssertEqual(LiveNotchSelection.ordered([music]).first?.toolID, "nowPlaying")
    }
    func testLiveStatusDiscardsDuplicateBlankInvalidProgressAndRetainsSimultaneousJobs() {
        let first = LiveNotchStatus(id: "jobA", kind: .processing, title: "A", toolID: "workflows", progress: .infinity)
        let second = LiveNotchStatus(id: "jobB", kind: .processing, title: "B", toolID: "fileActions", progress: 2)
        let blank = LiveNotchStatus(id: "blank", kind: .music, title: "  ", toolID: "nowPlaying")
        let result = LiveNotchSelection.ordered([first, blank, second, first])
        XCTAssertEqual(result.map(\.id), ["jobA", "jobB"])
        XCTAssertNil(result[0].progress)
        XCTAssertEqual(result[1].progress, 1)
    }
}
