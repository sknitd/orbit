import Foundation

public struct OnlineFXRates: Sendable {
    public let rateDate: String
    public let ratesPerUSD: [String: Decimal]
    public static func decode(_ data: Data) throws -> Self {
        let root = try OnlineServiceDecoding.object(data)
        guard root["base"] as? String == "USD", let date = root["date"] as? String,
              date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let rows = root["rates"] as? [String: Any], !rows.isEmpty else {
            throw OnlineDataError.invalid("FX provider did not return dated USD-based rates.")
        }
        _ = try OnlineServiceDecoding.calendarDate(date)
        var rates: [String: Decimal] = ["USD": 1]
        for (currency, raw) in rows {
            guard currency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil else { throw OnlineDataError.invalid("Invalid FX currency.") }
            let rate = try OnlineServiceDecoding.decimal(raw)
            guard rate > 0 else { throw OnlineDataError.invalid("FX rates must be positive.") }
            rates[currency] = rate
        }
        return Self(rateDate: date, ratesPerUSD: rates)
    }
    public func converted(_ totals: [String: Decimal]) -> (usd: Decimal, excluded: [String]) {
        var value: Decimal = 0; var excluded: [String] = []
        for (currency, amount) in totals {
            if let rate = ratesPerUSD[currency] { value += amount / rate }
            else { excluded.append(currency) }
        }
        return (value, excluded.sorted())
    }
}
