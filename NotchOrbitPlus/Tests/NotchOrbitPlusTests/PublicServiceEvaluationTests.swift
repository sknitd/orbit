import Foundation
import XCTest
import NotchCore

/// These inputs are real CI HTTP responses, never synthesized provider fixtures.
final class PublicServiceEvaluationTests: XCTestCase {
    func testRealPublicGeocodingResponseDecodesTheBerlinProbe() throws {
        let data = try response(for: "weather-geocoding")
        let places = try XCTUnwrap(JSONDecoder().decode(OnlineWeatherSearch.self, from: data).results)
        let berlin = try XCTUnwrap(places.first)
        XCTAssertTrue(berlin.name.localizedCaseInsensitiveContains("Berlin"))
        XCTAssertEqual(berlin.latitude, 52.52, accuracy: 0.15)
        XCTAssertEqual(berlin.longitude, 13.405, accuracy: 0.15)
        XCTAssertFalse(berlin.label.isEmpty)
    }

    func testRealPublicWeatherResponseDecodesSevenAlignedDays() throws {
        let forecast = try JSONDecoder().decode(OnlineWeatherResponse.self,
                                               from: response(for: "weather-forecast"))
        try forecast.validate()
        XCTAssertEqual(forecast.daily.time.count, 7)
        XCTAssertEqual(Set(forecast.daily.time).count, 7)
        XCTAssertEqual(forecast.daily.time.sorted(), forecast.daily.time)
        XCTAssertTrue(forecast.current.temperature_2m.isFinite)
        XCTAssertTrue(forecast.current.wind_speed_10m.isFinite)
        XCTAssertFalse(forecast.current.time.isEmpty)
        for index in forecast.daily.time.indices {
            XCTAssertGreaterThanOrEqual(forecast.daily.temperature_2m_max[index],
                                        forecast.daily.temperature_2m_min[index])
            XCTAssertTrue((0...100).contains(forecast.daily.precipitation_probability_max[index]))
        }
    }

    func testRealPublicUSDBasedFXResponseIsDatedAndUsableForConversion() throws {
        let rates = try OnlineFXRates.decode(response(for: "fx-usd"))
        XCTAssertNoThrow(try OnlineServiceDecoding.calendarDate(rates.rateDate))
        XCTAssertEqual(rates.ratesPerUSD["USD"], 1)
        let eur = try XCTUnwrap(rates.ratesPerUSD["EUR"])
        XCTAssertGreaterThan(eur, 0)
        let converted = rates.converted(["EUR": eur])
        XCTAssertEqual(NSDecimalNumber(decimal: converted.usd).doubleValue, 1, accuracy: 0.000_000_1)
        XCTAssertTrue(converted.excluded.isEmpty)
    }

    private func response(for id: String) throws -> Data {
        let directory = probeDirectory()
        let statusURL = directory.appendingPathComponent("status.json")
        guard FileManager.default.fileExists(atPath: statusURL.path) else {
            throw XCTSkip("Real public-service evidence is absent; run Scripts/public-service-probes.py. No live-service result is claimed.")
        }
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: statusURL)) as? [String: Any])
        XCTAssertEqual(status["api_credentials_used"] as? Bool, false)
        let results = try XCTUnwrap(status["results"] as? [[String: Any]])
        let result = try XCTUnwrap(results.first { $0["id"] as? String == id })
        guard result["validated"] as? Bool == true else {
            let reason = String((result["error"] as? String ?? "The public response failed preflight validation").prefix(240))
            throw XCTSkip("\(id) was unavailable in the recorded real HTTP probe: \(reason). No live-service success is claimed.")
        }
        XCTAssertEqual(result["http_status"] as? Int, 200)
        XCTAssertEqual(result["response_file"] as? String, "\(id).json")
        let url = directory.appendingPathComponent("\(id).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertLessThanOrEqual((attributes[.size] as? NSNumber)?.intValue ?? Int.max, 4 * 1024 * 1024)
        return try Data(contentsOf: url)
    }

    private func probeDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["NOTCHORBITPLUS_PUBLIC_PROBE_DIR"]
            ?? environment["TEST_RUNNER_NOTCHORBITPLUS_PUBLIC_PROBE_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build", isDirectory: true).appendingPathComponent("public-probes", isDirectory: true)
    }
}
