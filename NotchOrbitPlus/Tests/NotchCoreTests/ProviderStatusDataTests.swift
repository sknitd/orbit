import Foundation
import XCTest
@testable import NotchCore

final class ProviderStatusDataTests: XCTestCase {
    func testAfterShipCurrentSchemaPreservesReportedStatusAndOptionalRecipientLocalETA() throws {
        let page = try AfterShipTrackingData.decode(Data(#"{"meta":{"code":200},"data":{"trackings":[{"id":"tracking-real","tracking_number":"RA123456789US","slug":"usps","tag":"InTransit","updated_at":"2026-10-08T12:00:00Z","latest_estimated_delivery":{"datetime":"2026-10-10"},"checkpoints":[{"message":"Arrived at sorting center"}]}],"pagination":{"has_next_page":true,"next_cursor":"cursor-from-provider"}}}"#.utf8))
        XCTAssertEqual(page.trackings.first?.status, "InTransit")
        XCTAssertEqual(page.trackings.first?.estimatedDelivery, "2026-10-10")
        XCTAssertEqual(page.trackings.first?.checkpoint, "Arrived at sorting center")
        XCTAssertTrue(page.trackings.first?.isActive == true)
        XCTAssertEqual(page.nextCursor, "cursor-from-provider")
        let pending = try AfterShipTrackingData.decode(Data(#"{"meta":{"code":200},"data":{"trackings":[{"id":"pending","tracking_number":"AB123","slug":"ups","tag":"Pending"}]}}"#.utf8))
        XCTAssertNil(pending.trackings.first?.estimatedDelivery)
        XCTAssertFalse(pending.trackings.first?.isActive == true)
        XCTAssertThrowsError(try AfterShipTrackingData.decode(Data(#"{"meta":{"code":401},"data":{"trackings":[]}}"#.utf8)))
        XCTAssertThrowsError(try AfterShipTrackingData.decode(Data(#"{"meta":{"code":200},"data":{"trackings":[],"pagination":{"has_next_page":true}}}"#.utf8)))
    }

    func testFallbackURLsAndPackageReferencesRejectCredentialsSchemesAndLocalHosts() throws {
        XCTAssertEqual(try ProviderBrowserLink.validated("https://www.ups.com/track?tracknum=AB123").host, "www.ups.com")
        for value in ["javascript:alert(1)", "http://www.ups.com", "https://user:secret@www.ups.com/", "https://127.0.0.1/", "https://machine.local/"] {
            XCTAssertThrowsError(try ProviderBrowserLink.validated(value))
        }
        XCTAssertThrowsError(try PackageReference(number: "AB123,INJECTED"))
        let reference = try PackageReference(number: "AB123", pageURL: ProviderBrowserLink.validated("https://www.ups.com/track"))
        XCTAssertEqual(try JSONDecoder().decode(PackageReference.self, from: JSONEncoder().encode(reference)), reference)
    }

    func testCalendarTravelCandidatesUseRealEventDepartureAndExcludeAllDayOrUnrelatedText() throws {
        let departure = try iso("2026-10-09T10:00:00Z")
        let flight = try XCTUnwrap(TravelCalendarReference(eventID: "event-flight", title: "Flight BA 123 to London", departure: departure))
        XCTAssertEqual(flight.code, "BA123"); XCTAssertEqual(flight.kind, .flight); XCTAssertEqual(flight.departure, departure)
        let train = try XCTUnwrap(TravelCalendarReference(eventID: "event-train", title: "Train ICE 548", departure: departure))
        XCTAssertEqual(train.code, "ICE548"); XCTAssertEqual(train.kind, .train)
        XCTAssertNil(TravelCalendarReference(eventID: "event", title: "Team planning meeting", departure: departure))
        XCTAssertNil(TravelCalendarReference(eventID: "event", title: "Flight BA123", departure: departure, isAllDay: true))
        XCTAssertTrue(AviationstackData.validFlightCode("6E123"))
    }

    func testFlightParserKeepsProviderOffsetsAndMissingGateWithoutInventingStatus() throws {
        let page = try AviationstackData.decode(Data(#"{"pagination":{"total":2},"data":[{"flight":{"iata":"BA123"},"flight_status":"scheduled","departure":{"iata":"LHR","scheduled":"2026-10-09T11:00:00+01:00","estimated":null,"gate":null},"arrival":{"iata":"JFK","scheduled":"2026-10-09T14:00:00-04:00"}}]}"#.utf8), requested: "BA123")
        XCTAssertEqual(page.flights.first?.departure, try iso("2026-10-09T10:00:00Z"))
        XCTAssertEqual(page.flights.first?.arrival, try iso("2026-10-09T18:00:00Z"))
        XCTAssertNil(page.flights.first?.gate); XCTAssertNil(page.flights.first?.estimatedDeparture)
        XCTAssertEqual(page.flights.first?.status, "scheduled"); XCTAssertTrue(page.limited)
        XCTAssertThrowsError(try AviationstackData.decode(Data(#"{"error":{"code":"invalid_access_key"}}"#.utf8), requested: "BA123"))
        XCTAssertThrowsError(try AviationstackData.decode(Data(#"{"data":[]}"#.utf8), requested: "BAD/URL"))
    }

    func testSportsNullScoresStayUnknownAndOnlyInProgressStatusesAreLive() throws {
        let data = Data(#"{"errors":[],"response":[{"fixture":{"id":102,"date":"2026-10-09T10:00:00Z","status":{"short":"1H","long":"First Half","elapsed":24}},"teams":{"home":{"id":42,"name":"Home FC"},"away":{"id":43,"name":"Away FC"}},"goals":{"home":2,"away":null}}]}"#.utf8)
        let game = try XCTUnwrap(APIFootballData.games(data).first)
        XCTAssertTrue(game.isInProgress); XCTAssertEqual(game.homeScore, 2); XCTAssertNil(game.awayScore); XCTAssertEqual(game.scoreText, "2–—")
        let finished = try XCTUnwrap(APIFootballData.games(Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"1H\"", with: "\"FT\"").utf8)).first)
        XCTAssertFalse(finished.isInProgress)
        XCTAssertThrowsError(try APIFootballData.games(Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"id\":102", with: "\"id\":true").utf8)))
        XCTAssertThrowsError(try APIFootballData.teams(Data(#"{"errors":{"token":"invalid"},"response":[]}"#.utf8)))
    }

    func testAQIAndUVAreActualBoundedProviderFieldsAndNullIsAnError() throws {
        let air = try WeatherAirObservation.decode(Data(#"{"current":{"time":1791547200,"us_aqi":125,"uv_index":7.3,"pm2_5":40}}"#.utf8))
        XCTAssertEqual(air.usAQI, 125); XCTAssertEqual(air.uvIndex, 7.3); XCTAssertEqual(air.pm25, 40)
        XCTAssertEqual(air.aqiLabel, "Unhealthy for sensitive groups")
        XCTAssertThrowsError(try WeatherAirObservation.decode(Data(#"{"current":{"time":1791547200,"us_aqi":null,"uv_index":7,"pm2_5":40}}"#.utf8)))
        XCTAssertThrowsError(try WeatherAirObservation.decode(Data(#"{"current":{"time":1791547200,"us_aqi":125,"uv_index":true,"pm2_5":40}}"#.utf8)))
    }

    func testRainForecastUsesConsecutiveQuarterHoursAndActualNearTermPrecipitation() throws {
        let date = Date(timeIntervalSince1970: 1791547200)
        let rain = try WeatherRainForecast.decode(Data(#"{"minutely_15":{"time":[1791547200,1791548100,1791549000],"precipitation":[0,0.4,0]}}"#.utf8))
        XCTAssertEqual(rain.nextRain(at: date)?.date, date.addingTimeInterval(900))
        XCTAssertNil(rain.nextRain(at: date, within: 300))
        XCTAssertNil(rain.nextRain(at: date.addingTimeInterval(1800)))
        XCTAssertThrowsError(try WeatherRainForecast.decode(Data(#"{"minutely_15":{"time":[1791547200,1791547300],"precipitation":[0,0.4]}}"#.utf8)))
        XCTAssertThrowsError(try WeatherRainForecast.decode(Data(#"{"minutely_15":{"time":[1791547200],"precipitation":[null]}}"#.utf8)))
    }
    private func iso(_ value: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: value)) }
}
