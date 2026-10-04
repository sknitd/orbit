import Foundation
import XCTest
import NotchCore
@testable import NotchOrbitPlus

private actor ProviderRequestFixture {
    var requests: [URLRequest] = []
    let endlessPackages: Bool
    init(endlessPackages: Bool = false) { self.endlessPackages = endlessPackages }
    func load(_ request: URLRequest) throws -> Data {
        requests.append(request)
        guard let url = request.url else { throw OnlineServiceError.message("Missing fixture request URL.") }
        switch url.host {
        case "api.aftership.com":
            let count = requests.count
            return try JSONSerialization.data(withJSONObject: ["meta": ["code": 200], "data": [
                "trackings": [["id": "tracking-\(count)", "tracking_number": "AB123", "slug": "ups", "tag": "InTransit"]],
                "pagination": ["has_next_page": endlessPackages, "next_cursor": "cursor-\(count)"]]])
        case "api.aviationstack.com":
            return Data(#"{"data":[{"flight":{"iata":"BA123"},"flight_status":"active","departure":{"iata":"LHR","scheduled":"2026-10-08T10:00:00+00:00"},"arrival":{"iata":"JFK","scheduled":"2026-10-08T18:00:00+00:00"}}],"pagination":{"total":1}}"#.utf8)
        case "v3.football.api-sports.io":
            if url.path == "/teams" { return Data(#"{"errors":[],"response":[{"team":{"id":42,"name":"Chosen FC","country":"England"}}]}"#.utf8) }
            return Data(#"{"errors":[],"response":[{"fixture":{"id":100,"date":"2026-10-08T10:00:00Z","status":{"short":"1H","long":"First Half","elapsed":24}},"teams":{"home":{"id":42,"name":"Chosen FC"},"away":{"id":43,"name":"Away FC"}},"goals":{"home":2,"away":1}}]}"#.utf8)
        case "air-quality-api.open-meteo.com":
            return Data(#"{"current":{"time":1791547200,"us_aqi":125,"uv_index":7,"pm2_5":40}}"#.utf8)
        case "api.open-meteo.com":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "minutely_15" }) { return Data(#"{"minutely_15":{"time":[1791547200,1791548100],"precipitation":[0,0.4]}}"#.utf8) }
            return Data(#"{"current":{"time":"2026-10-08T12:00","temperature_2m":18,"weather_code":3,"wind_speed_10m":12},"daily":{"time":["2026-10-08","2026-10-09","2026-10-10","2026-10-11","2026-10-12","2026-10-13","2026-10-14"],"weather_code":[3,3,3,3,3,3,3],"temperature_2m_max":[20,20,20,20,20,20,20],"temperature_2m_min":[10,10,10,10,10,10,10],"precipitation_probability_max":[30,30,30,30,30,30,30]}}"#.utf8)
        default: throw OnlineServiceError.message("Unexpected fixture provider origin.")
        }
    }
    func recorded() -> [URLRequest] { requests }
}

@MainActor
final class ProviderRequestContractTests: XCTestCase {
    func testAfterShipUsesCurrentHeaderAndThreePageCapOnExplicitRefresh() async throws {
        let suite = "NotchOrbitPlus.PackageRequest.\(UUID().uuidString)", fixture = ProviderRequestFixture(endlessPackages: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let service = PackageTrackerService(defaults: defaults, load: { try await fixture.load($0) }, readKey: { "fixture-key" })
        defer { service.shutdown(); defaults.removePersistentDomain(forName: suite) }
        service.numberInput = "AB123"; service.add()
        let before = await fixture.recorded(); XCTAssertTrue(before.isEmpty)
        service.refresh(); try await waitUntil { !service.busy }
        XCTAssertNil(service.error); XCTAssertEqual(service.trackings.count, 3)
        XCTAssertTrue(service.coverage.contains("Limited to three"))
        let requests = await fixture.recorded(); XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.url?.path, "/tracking/2026-07/trackings")
            XCTAssertEqual(request.value(forHTTPHeaderField: "as-api-key"), "fixture-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "aftership-api-key"))
        }
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cursor" })?.value, "cursor-1")
    }

    func testFlightAndChosenTeamFixturesUseTheirOwnOriginsAndKeysOnlyOnRefresh() async throws {
        let suite = "NotchOrbitPlus.TravelSportsRequest.\(UUID().uuidString)", fixture = ProviderRequestFixture()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let travel = TravelStatusService(defaults: defaults, load: { try await fixture.load($0) }, readKey: { "fixture-flight-key" }, readCalendar: { [] })
        let sports = SportsScoresService(defaults: defaults, load: { try await fixture.load($0) }, readKey: { "fixture-sports-key" })
        defer { travel.shutdown(); sports.shutdown(); defaults.removePersistentDomain(forName: suite) }
        travel.flightCodeInput = "BA123"; travel.refreshFlight(); try await waitUntil { !travel.busy }
        XCTAssertEqual(travel.flights.first?.code, "BA123"); XCTAssertNil(travel.error)
        sports.teamQuery = "Chosen"; sports.searchTeams(); try await waitUntil { !sports.busy }
        sports.add(try XCTUnwrap(sports.searchResults.first)); sports.refresh(); try await waitUntil { !sports.busy }
        XCTAssertEqual(sports.games.first?.home.name, "Chosen FC"); XCTAssertEqual(sports.games.first?.homeScore, 2)
        XCTAssertNil(sports.error)
        let requests = await fixture.recorded(); XCTAssertEqual(requests.count, 3)
        let flightURL = try XCTUnwrap(requests.first?.url)
        XCTAssertEqual(flightURL.host, "api.aviationstack.com")
        let flightQuery = URLComponents(url: flightURL, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(flightQuery?.first(where: { $0.name == "flight_iata" })?.value, "BA123")
        XCTAssertEqual(flightQuery?.first(where: { $0.name == "access_key" })?.value, "fixture-flight-key")
        for request in requests.dropFirst() {
            XCTAssertEqual(request.url?.host, "v3.football.api-sports.io")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-apisports-key"), "fixture-sports-key")
            XCTAssertEqual(request.httpMethod, "GET")
        }
    }

    func testWeatherExplicitRefreshRequestsActualAQIUVAndQuarterHourRainFields() async throws {
        let suite = "NotchOrbitPlus.WeatherRequest.\(UUID().uuidString)", fixture = ProviderRequestFixture()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let weather = OnlineWeatherModel(defaults: defaults, load: { try await fixture.load($0) })
        defer { weather.shutdown(); defaults.removePersistentDomain(forName: suite) }
        let place = try JSONDecoder().decode(OnlineWeatherPlace.self, from: Data(#"{"id":100,"name":"Paris","latitude":48.85,"longitude":2.35}"#.utf8))
        let before = await fixture.recorded(); XCTAssertTrue(before.isEmpty)
        weather.fetch(place); try await waitUntil { !weather.busy }
        XCTAssertNil(weather.error); XCTAssertNil(weather.noticesError)
        XCTAssertEqual(weather.air?.usAQI, 125); XCTAssertEqual(weather.air?.uvIndex, 7)
        XCTAssertEqual(weather.rain?.points.count, 2); XCTAssertEqual(weather.cache?.place.name, "Paris")
        let requests = await fixture.recorded(); XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        let airRequest = try XCTUnwrap(requests.first { $0.url?.host == "air-quality-api.open-meteo.com" })
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(airRequest.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "current" })?.value, "us_aqi,uv_index,pm2_5")
        let rainRequest = try XCTUnwrap(requests.first { request in
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?.contains(where: { $0.name == "minutely_15" }) == true
        })
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(rainRequest.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "forecast_minutely_15" })?.value, "8")
    }

    func testReadOnlyTransportRejectsMutationAndWrongOriginCredentialBeforeNetwork() async throws {
        let url = try ProviderReadOnlyHTTPS.url(host: "api.aftership.com", path: "/tracking/2026-07/trackings", query: [])
        XCTAssertThrowsError(try ProviderReadOnlyHTTPS.request(url, key: "fixture", header: "x-apisports-key"))
        XCTAssertFalse(ProviderReadOnlyHTTPS.allowed(try XCTUnwrap(URL(string: "https://api.aftership.com.evil.example/tracking/2026-07/trackings"))))
        var mutation = URLRequest(url: url); mutation.httpMethod = "POST"
        do { _ = try await ProviderReadOnlyHTTPS.load(mutation); XCTFail("Mutation must be rejected before constructing a URLSession") }
        catch is OnlineServiceError { }
        catch { XCTFail("Unexpected read-only validation error: \(error.localizedDescription)") }
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Provider fixture did not complete within two seconds")
    }
}
