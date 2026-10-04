import XCTest
@testable import NotchCore

final class FocusTimerTests: XCTestCase {
    func testPauseResumePreservesRemainingAcrossLongHiddenInterval() {
        let origin = Date(timeIntervalSince1970: 1_000)
        var timer = FocusTimer()
        timer.start(minutes: 25, at: origin)
        timer.pause(at: origin.addingTimeInterval(120))
        XCTAssertEqual(timer.remaining(at: origin.addingTimeInterval(3_600)), 1_380)
        timer.resume(at: origin.addingTimeInterval(3_600))
        XCTAssertNil(timer.finishIfDue(at: origin.addingTimeInterval(4_979)))
        XCTAssertEqual(timer.finishIfDue(at: origin.addingTimeInterval(4_980)), .focus)
        XCTAssertEqual(timer.completedSessions, 1)
        XCTAssertNil(timer.finishIfDue(at: origin.addingTimeInterval(5_000)))
    }

    func testDeadlineSurvivesPersistenceAndSleepWithoutTickCounting() throws {
        let origin = Date(timeIntervalSince1970: 1_000)
        var timer = FocusTimer()
        timer.start(minutes: 1, at: origin)
        var restored = try JSONDecoder().decode(FocusTimer.self, from: JSONEncoder().encode(timer))
        XCTAssertEqual(restored.finishIfDue(at: origin.addingTimeInterval(500)), .focus)
        XCTAssertEqual(restored.remaining(at: origin.addingTimeInterval(500)), 0)
        XCTAssertEqual(restored.phase, .idle)
    }

    func testRestDoesNotCountAsFocusAndCancelNeverCompletes() {
        let origin = Date(timeIntervalSince1970: 1_000)
        var timer = FocusTimer()
        timer.start(minutes: 5, phase: .rest, at: origin)
        XCTAssertEqual(timer.finishIfDue(at: origin.addingTimeInterval(300)), .rest)
        XCTAssertEqual(timer.completedSessions, 0)
        timer.start(minutes: 1, at: origin)
        timer.cancel()
        XCTAssertNil(timer.finishIfDue(at: origin.addingTimeInterval(500)))
        for duration in [0, -1, Double.nan, Double.infinity, 1_441] {
            timer.start(minutes: duration, at: origin)
            XCTAssertEqual(timer.phase, .idle)
        }
    }
}
