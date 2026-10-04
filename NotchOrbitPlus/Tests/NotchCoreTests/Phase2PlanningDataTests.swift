import Foundation
import XCTest
@testable import NotchCore

final class Phase2PlanningDataTests: XCTestCase {
    func testCrossCurrencyConversionUsesDatedDecimalRatesAndRejectsMissingCurrencies() throws {
        let rates = try OnlineFXRates.decode(Data(#"{"base":"USD","date":"2026-10-08","rates":{"EUR":0.8,"GBP":0.5,"JPY":150}}"#.utf8))
        XCTAssertEqual(rates.rateDate, "2026-10-08")
        XCTAssertEqual(try CurrencyConversion.convert(8, from: "EUR", to: "GBP", rates: rates), 5)
        XCTAssertEqual(try CurrencyConversion.convert(-8, from: "EUR", to: "JPY", rates: rates), -1500)
        XCTAssertEqual(try CurrencyConversion.convert(0, from: "USD", to: "EUR", rates: rates), 0)
        XCTAssertThrowsError(try CurrencyConversion.convert(1, from: "CHF", to: "USD", rates: rates))
        XCTAssertThrowsError(try CurrencyConversion.convert(.nan, from: "USD", to: "EUR", rates: rates))
    }

    func testMeetingInstantConvertsAcrossDateBoundariesAndFractionalOffsets() throws {
        let instant = try iso("2026-12-31T23:00:00Z")
        let tokyo = try WorldClockConversion.components(for: instant, zoneID: "Asia/Tokyo")
        XCTAssertEqual(tokyo.year, 2027); XCTAssertEqual(tokyo.month, 1); XCTAssertEqual(tokyo.day, 1); XCTAssertEqual(tokyo.hour, 8)
        let kathmandu = try WorldClockConversion.components(for: instant, zoneID: "Asia/Kathmandu")
        XCTAssertEqual(kathmandu.hour, 4); XCTAssertEqual(kathmandu.minute, 45)
        XCTAssertEqual(try WorldClockConversion.offsetLabel(for: instant, zoneID: "Asia/Kathmandu"), "UTC+05:45")
        XCTAssertThrowsError(try WorldClockConversion.components(for: instant, zoneID: "Imaginary/City"))
    }

    func testDSTGapIsRejectedAndFallBackSelectsFirstOccurrence() throws {
        XCTAssertThrowsError(try WorldClockConversion.date(components: .init(year: 2026, month: 3, day: 8, hour: 2, minute: 30), zoneID: "America/New_York"))
        let valid = try WorldClockConversion.date(components: .init(year: 2026, month: 3, day: 8, hour: 3, minute: 30), zoneID: "America/New_York")
        XCTAssertEqual(valid, try iso("2026-03-08T07:30:00Z"))
        let repeated = try WorldClockConversion.date(components: .init(year: 2026, month: 11, day: 1, hour: 1, minute: 30), zoneID: "America/New_York")
        XCTAssertEqual(repeated, try iso("2026-11-01T05:30:00Z"))
        XCTAssertEqual(try WorldClockConversion.offsetLabel(for: valid, zoneID: "America/New_York"), "UTC−04:00")
    }

    func testZonePreferencesNormalizeForDisplayButStrictSyncValidationDoesNotDiscardInput() throws {
        let values = ["Asia/Tokyo", "Asia/Tokyo", "not-a-zone", "Europe/London"]
        XCTAssertEqual(WorldClockPreferences(zoneIDs: values).zoneIDs, ["Asia/Tokyo", "Europe/London"])
        XCTAssertThrowsError(try WorldClockPreferences.validated(values))
        XCTAssertEqual(try WorldClockPreferences.validated([]), [])
        let valid = WorldClockPreferences(zoneIDs: ["Asia/Kathmandu", "America/New_York"])
        XCTAssertEqual(try JSONDecoder().decode(WorldClockPreferences.self, from: JSONEncoder().encode(valid)), valid)
    }

    func testFocusHistoryRecordsDeadlineAndFocusDurationOnceWithoutPausedTime() throws {
        let origin = Date(timeIntervalSince1970: 1000)
        var timer = FocusTimer(); timer.start(minutes: 25, at: origin)
        timer.pause(at: origin.addingTimeInterval(120)); timer.resume(at: origin.addingTimeInterval(3600))
        var restored = try JSONDecoder().decode(FocusTimer.self, from: JSONEncoder().encode(timer))
        XCTAssertEqual(restored.finishIfDue(at: origin.addingTimeInterval(9000)), .focus)
        XCTAssertEqual(restored.history.count, 1)
        XCTAssertEqual(restored.history.first?.finishedAt, origin.addingTimeInterval(4980))
        XCTAssertEqual(restored.history.first?.duration, 1500)
        XCTAssertNil(restored.finishIfDue(at: origin.addingTimeInterval(10000)))
        restored.start(minutes: 5, phase: .rest, at: origin); _ = restored.finishIfDue(at: origin.addingTimeInterval(300))
        restored.start(minutes: 1, at: origin); restored.cancel(); _ = restored.finishIfDue(at: origin.addingTimeInterval(500))
        XCTAssertEqual(restored.history.count, 1)
    }

    func testLegacyFocusMigrationRetainsCountWithoutInventingOldDatesOrDurations() throws {
        struct Legacy: Codable { let phase: FocusTimer.Phase; let deadline: Date; let completedSessions: Int }
        let deadline = Date(timeIntervalSince1970: 2000)
        var migrated = try JSONDecoder().decode(FocusTimer.self, from: JSONEncoder().encode(Legacy(phase: .focus, deadline: deadline, completedSessions: 17)))
        XCTAssertEqual(migrated.completedSessions, 17); XCTAssertTrue(migrated.history.isEmpty)
        XCTAssertEqual(migrated.finishIfDue(at: deadline), .focus)
        XCTAssertEqual(migrated.completedSessions, 18); XCTAssertTrue(migrated.history.isEmpty)
        migrated.start(minutes: 1, at: deadline); _ = migrated.finishIfDue(at: deadline.addingTimeInterval(60))
        XCTAssertEqual(migrated.history.first?.duration, 60)
    }

    func testFocusWeekUsesLocalCalendarDaysAcrossSpringDSTAndExcludesNextWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York")); calendar.firstWeekday = 2
        let records = [FocusCompletion(finishedAt: try iso("2026-03-08T05:00:00Z"), duration: 1500),
                       FocusCompletion(finishedAt: try iso("2026-03-09T03:59:59Z"), duration: 600),
                       FocusCompletion(finishedAt: try iso("2026-03-09T04:00:00Z"), duration: 300)]
        let days = FocusHistory.week(containing: try iso("2026-03-08T12:00:00Z"), records: records, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.reduce(0) { $0 + $1.sessions }, 2)
        XCTAssertEqual(days.last?.seconds, 2100)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(days.last?.date)), 8)
    }

    func testGithubParserRejectsMalformedPagesUnsafeLinksAndTraversal() throws {
        let repo = #"[{"id":123,"full_name":"sknitd/orbit","html_url":"https://github.com/sknitd/orbit","private":false}]"#
        XCTAssertEqual(try GithubActionsData.repositories(Data(repo.utf8)).first?.fullName, "sknitd/orbit")
        XCTAssertThrowsError(try GithubActionsData.repositories(Data(repo.replacingOccurrences(of: "github.com", with: "example.com").utf8)))
        XCTAssertThrowsError(try GithubActionsData.repositories(Data("{}".utf8)))
        XCTAssertThrowsError(try GithubActionsData.runsURL(repository: "sknitd/..", page: 1))
        XCTAssertThrowsError(try GithubActionsData.repositoryURL(page: 6))
        XCTAssertThrowsError(try GithubActionsData.runPage(Data(#"{"total_count":true,"workflow_runs":[]}"#.utf8)))
        let url = try GithubActionsData.runsURL(repository: "sknitd/orbit", page: 3)
        XCTAssertEqual(url.host, "api.github.com"); XCTAssertEqual(url.path, "/repos/sknitd/orbit/actions/runs")
    }

    private func iso(_ text: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: text)) }
}
