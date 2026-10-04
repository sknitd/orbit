import Foundation
import XCTest
@testable import NotchCore

final class OnlineServiceDataTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_728_000_000) // 2024-10-04 UTC
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private var stamp: String { ISO8601DateFormatter().string(from: now) }

    func testStripeUTCFilteringCaptureMinorUnitsAndRefunds() throws {
        let data = try json(["data": [
            ["id": "synthetic_a", "paid": true, "captured": true, "amount": 12345, "amount_captured": 12000, "amount_refunded": 500, "currency": "usd", "created": now.timeIntervalSince1970],
            ["id": "synthetic_b", "paid": true, "captured": true, "amount": 123, "currency": "jpy", "created": now.timeIntervalSince1970],
            ["id": "synthetic_old", "paid": true, "amount": 100, "currency": "usd", "created": now.addingTimeInterval(-86400).timeIntervalSince1970],
            ["id": "synthetic_authorized", "paid": true, "captured": false, "amount": 100, "currency": "usd", "created": now.timeIntervalSince1970]
        ]])
        let report = try OnlineServiceDecoding.sales(data, provider: .stripe, fetchedAt: now)
        XCTAssertEqual(report.orders.count, 2)
        XCTAssertEqual(report.totals["USD"], 120)
        XCTAssertEqual(report.totals["JPY"], 123)
        XCTAssertEqual(report.refunds["USD"], 5)
        XCTAssertLessThanOrEqual(report.dayStart, now)
        XCTAssertGreaterThan(report.dayEnd, now)
    }
    func testEverySalesProviderNormalizesItsDocumentedEnvelope() throws {
        let fixtures: [(OnlineSalesProvider, [String: Any], Decimal)] = [
            (.lemon, ["data": [["id": "synthetic_l", "attributes": ["status": "paid", "currency": "USD", "total": 1250, "created_at": stamp]]]], Decimal(string: "12.50")!),
            (.gumroad, ["success": true, "sales": [["id": "synthetic_g", "currency": "usd", "price": 1250, "created_at": stamp]]], Decimal(string: "12.50")!),
            (.dodo, ["items": [["payment_id": "synthetic_d", "status": "succeeded", "currency": "USD", "total_amount": 1250, "created_at": stamp]]], Decimal(string: "12.50")!),
            (.polar, ["items": [["id": "synthetic_p", "currency": "usd", "total_amount": 1250, "refunded_amount": 0, "created_at": stamp]]], Decimal(string: "12.50")!),
            (.paddle, ["data": [["id": "synthetic_t", "status": "completed", "currency_code": "USD", "created_at": stamp, "details": ["totals": ["grand_total": "1250"]]]]], Decimal(string: "12.50")!),
            (.shopify, ["data": ["orders": ["edges": [["node": ["id": "synthetic_s", "createdAt": stamp, "displayFinancialStatus": "PAID", "totalPriceSet": ["shopMoney": ["amount": "12.50", "currencyCode": "USD"]], "totalRefundedSet": ["shopMoney": ["amount": "1.50", "currencyCode": "USD"]]]]]]]], Decimal(string: "12.50")!)
        ]
        for (provider, fixture, amount) in fixtures {
            let report = try OnlineServiceDecoding.sales(json(fixture), provider: provider, fetchedAt: now)
            XCTAssertEqual(report.totals["USD"], amount, provider.rawValue)
            XCTAssertEqual(report.orders.count, 1, provider.rawValue)
        }
    }
    func testSalesRejectsErrorsDuplicateIdentitiesAndInvalidMoney() throws {
        XCTAssertThrowsError(try OnlineServiceDecoding.sales(json(["error": "synthetic"]), provider: .stripe, fetchedAt: now))
        let row: [String: Any] = ["id": "duplicate", "paid": true, "amount": 100, "currency": "usd", "created": now.timeIntervalSince1970]
        XCTAssertThrowsError(try OnlineServiceDecoding.sales(json(["data": [row, row]]), provider: .stripe, fetchedAt: now))
        XCTAssertThrowsError(try OnlineServiceDecoding.decimal(true))
        XCTAssertEqual(try OnlineServiceDecoding.decimal(1), 1)
        XCTAssertThrowsError(try OnlineServiceDecoding.decimal("nan"))
        XCTAssertThrowsError(try OnlineServiceDecoding.majorUnits(-1, currency: "USD"))
        XCTAssertEqual(try OnlineServiceDecoding.majorUnits(1234, currency: "KWD"), Decimal(string: "1.234")!)
    }
    func testFXUsesDatedRealBaseDirectionAndExcludesMissingCurrency() throws {
        let fx = try OnlineFXRates.decode(json(["base": "USD", "date": "2024-10-04", "rates": ["EUR": 0.8, "JPY": 160]]))
        let total = fx.converted(["USD": 10, "EUR": 80, "JPY": 1600, "ZZZ": 4])
        XCTAssertEqual(total.usd, 120)
        XCTAssertEqual(total.excluded, ["ZZZ"])
        XCTAssertEqual(fx.rateDate, "2024-10-04")
        XCTAssertThrowsError(try OnlineFXRates.decode(json(["base": "EUR", "date": "2024-10-04", "rates": ["USD": 1.2]])))
        XCTAssertThrowsError(try OnlineFXRates.decode(json(["base": "USD", "date": "2024-10-04", "rates": ["EUR": 0]])))
    }
    func testUsageImportsExplicitLimitsMissingQuotaAndStaleness() throws {
        let data = try json(["provider": "Codex", "exported_at": stamp, "snapshots": [
            ["scope": "session", "used": 40, "limit": 100, "unit": "requests"],
            ["scope": "weekly", "used": 12345, "unit": "tokens"]]])
        let imported = try OnlineAIUsageExport.decode(data, now: now)
        XCTAssertEqual(imported.snapshots[0].remaining, 60)
        XCTAssertEqual(imported.snapshots[0].fraction!, 0.4, accuracy: 0.0001)
        XCTAssertNil(imported.snapshots[1].remaining)
        XCTAssertFalse(imported.isStale(at: now))
        XCTAssertTrue(imported.isStale(at: now.addingTimeInterval(7 * 3600)))
        let over = try OnlineAIUsageExport.decode(json(["provider": "Claude", "exported_at": stamp,
            "snapshots": [["scope": "session", "used": 120, "limit": 100, "unit": "percent"]]]), now: now)
        XCTAssertEqual(over.snapshots[0].remaining, 0)
        XCTAssertEqual(over.snapshots[0].fraction!, 1.2, accuracy: 0.0001)
    }
    func testUsageRejectsFutureTimestampsNegativeLimitsAndDuplicateScopes() throws {
        let rows: [[String: Any]] = [["scope": "session", "used": 1, "limit": 10, "unit": "tokens"]]
        XCTAssertThrowsError(try OnlineAIUsageExport.decode(json(["provider": "Codex", "exported_at": stamp, "snapshots": rows + rows]), now: now))
        XCTAssertThrowsError(try OnlineAIUsageExport.decode(json(["provider": "Codex", "exported_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(3600)), "snapshots": rows]), now: now))
        XCTAssertThrowsError(try OnlineAIUsageExport.decode(json(["provider": "Codex", "exported_at": stamp, "snapshots": [["scope": "weekly", "used": -1, "unit": "tokens"]]]), now: now))
        XCTAssertThrowsError(try OnlineAIUsageExport.decode(json(["provider": "Codex", "exported_at": stamp, "snapshots": [["scope": "weekly", "used": 1, "limit": 0, "unit": "tokens"]]]), now: now))
    }
    func testStockQuoteDoesNotInventRateLimitedOrMissingData() throws {
        let quote = try OnlineStockQuote.decodeQuote(json(["Global Quote": ["01. symbol": "TEST", "05. price": "123.45", "07. latest trading day": "2024-10-04", "09. change": "-1.20", "10. change percent": "-0.9%"]]))
        XCTAssertEqual(quote.price, Decimal(string: "123.45")!)
        XCTAssertEqual(quote.tradingDay, "2024-10-04")
        XCTAssertThrowsError(try OnlineStockQuote.decodeQuote(json(["Information": "provider quota reached"])))
        XCTAssertThrowsError(try quote.addingIntraday(json(["Note": "premium entitlement required"])))
    }
    func testWeatherRequiresSevenCompleteFiniteDays() throws {
        var forecast: [String: Any] = ["current": ["time": "2024-10-04T12:00", "temperature_2m": 20, "weather_code": 0, "wind_speed_10m": 4],
            "daily": ["time": Array(repeating: "2024-10-04", count: 7), "weather_code": Array(repeating: 0, count: 7), "temperature_2m_max": Array(repeating: 20, count: 7), "temperature_2m_min": Array(repeating: 10, count: 7), "precipitation_probability_max": Array(repeating: 20, count: 7)]]
        try JSONDecoder().decode(OnlineWeatherResponse.self, from: json(forecast)).validate()
        var daily = forecast["daily"] as! [String: Any]; daily["temperature_2m_max"] = [20]
        forecast["daily"] = daily
        XCTAssertThrowsError(try JSONDecoder().decode(OnlineWeatherResponse.self, from: json(forecast)).validate())
    }
}
