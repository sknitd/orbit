import Foundation
import XCTest
@testable import NotchCore

final class OnlineCodexQuotaTests: XCTestCase {
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func testPublicProtocolSelectsCodexKeyAndIgnoresSensitiveExtras() throws {
        let data = try json(["rateLimits": ["primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1_900_000_000],
                "secondary": ["usedPercent": 60, "windowDurationMins": 10080], "credits": ["balance": "synthetic-unused"], "planType": "synthetic-unused"]],
            "accountId": "synthetic-unused-account"])
        let quota = try OnlineCodexQuota.decodeResult(data)
        XCTAssertEqual(quota.windows.count, 2)
        XCTAssertEqual(quota.windows[0].usedPercent, 25)
        XCTAssertEqual(quota.windows[0].remainingPercent, 75)
        XCTAssertEqual(quota.windows[0].label, "5-hour session")
        XCTAssertEqual(quota.windows[1].label, "Weekly")
        XCTAssertEqual(quota.windows[0].resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
    }
    func testHistoricalFallbackKeepsUnknownDurationHonest() throws {
        let quota = try OnlineCodexQuota.decodeResult(json(["rateLimits": [
            "primary": ["usedPercent": 0, "windowDurationMins": NSNull(), "resetsAt": NSNull()],
            "secondary": ["usedPercent": 100, "windowDurationMins": 120]]]))
        XCTAssertTrue(quota.windows[0].label.contains("duration not reported"))
        XCTAssertNil(quota.windows[0].resetsAt)
        XCTAssertEqual(quota.windows[1].label, "120-minute window")
        XCTAssertEqual(quota.windows[1].remainingPercent, 0)
    }
    func testMissingOrInvalidQuotaNeverProducesInventedRemaining() throws {
        XCTAssertThrowsError(try OnlineCodexQuota.decodeResult(json(["rateLimits": NSNull()])))
        XCTAssertThrowsError(try OnlineCodexQuota.decodeResult(json(["rateLimits": ["primary": NSNull(), "secondary": NSNull()]])))
        for invalid: Any in [-1, 101, true, "NaN"] {
            XCTAssertThrowsError(try OnlineCodexQuota.decodeResult(json(["rateLimits": ["primary": ["usedPercent": invalid]]])))
        }
        XCTAssertThrowsError(try OnlineCodexQuota.decodeResult(json(["rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 0]]])))
        XCTAssertThrowsError(try OnlineCodexQuota.decodeResult(json(["rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 1.5]]])))
    }
}
