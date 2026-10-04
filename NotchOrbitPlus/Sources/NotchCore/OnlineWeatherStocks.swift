import Foundation

public struct OnlineWeatherPlace: Codable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let country: String?
    public let admin1: String?
    public var label: String { [name, admin1, country].compactMap { $0 }.joined(separator: ", ") }
}
public struct OnlineWeatherSearch: Decodable, Sendable { public let results: [OnlineWeatherPlace]? }
public struct OnlineWeatherResponse: Codable, Sendable {
    public struct Current: Codable, Sendable {
        public let time: String
        public let temperature_2m: Double
        public let weather_code: Int
        public let wind_speed_10m: Double
    }
    public struct Daily: Codable, Sendable {
        public let time: [String]
        public let weather_code: [Int]
        public let temperature_2m_max: [Double]
        public let temperature_2m_min: [Double]
        public let precipitation_probability_max: [Double]
    }
    public let current: Current
    public let daily: Daily
    public func validate() throws {
        let count = daily.time.count
        guard count == 7, daily.weather_code.count == count, daily.temperature_2m_max.count == count,
              daily.temperature_2m_min.count == count, daily.precipitation_probability_max.count == count,
              current.temperature_2m.isFinite, current.wind_speed_10m.isFinite,
              daily.temperature_2m_max.allSatisfy(\.isFinite), daily.temperature_2m_min.allSatisfy(\.isFinite),
              daily.precipitation_probability_max.allSatisfy({ $0.isFinite && (0...100).contains($0) }) else {
            throw OnlineDataError.invalid("Weather provider returned an incomplete seven-day forecast.")
        }
        for day in daily.time { _ = try OnlineServiceDecoding.calendarDate(day) }
    }
    public static func condition(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1, 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...67: "Rain / drizzle"
        case 71...77: "Snow"
        case 80...82: "Rain showers"
        case 85, 86: "Snow showers"
        case 95...99: "Thunderstorm"
        default: "Condition code \(code)"
        }
    }
}
public struct OnlineWeatherCache: Codable, Sendable {
    public let place: OnlineWeatherPlace
    public let forecast: OnlineWeatherResponse
    public let fetchedAt: Date
    public init(place: OnlineWeatherPlace, forecast: OnlineWeatherResponse, fetchedAt: Date) {
        self.place = place; self.forecast = forecast; self.fetchedAt = fetchedAt
    }
}

public struct OnlineStockPoint: Identifiable, Codable, Sendable {
    public var id: String { time }
    public let time: String
    public let close: Decimal
}
public struct OnlineStockQuote: Codable, Sendable {
    public let symbol: String
    public let price: Decimal
    public let change: Decimal
    public let changePercent: String
    public let tradingDay: String
    public let intraday: [OnlineStockPoint]
    public let exchangeTimeZone: String?
    public static func decodeQuote(_ data: Data) throws -> Self {
        let root = try OnlineServiceDecoding.object(data)
        guard let quote = root["Global Quote"] as? [String: Any], let symbol = quote["01. symbol"] as? String,
              let day = quote["07. latest trading day"] as? String, day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw OnlineDataError.invalid("Alpha Vantage returned no quote. Check symbol, API-key entitlement or rate limit. Quotes may require a paid plan.")
        }
        let price = try OnlineServiceDecoding.decimal(quote["05. price"])
        _ = try OnlineServiceDecoding.calendarDate(day)
        guard price > 0 else { throw OnlineDataError.invalid("Provider quote has no valid price.") }
        return Self(symbol: symbol, price: price, change: try OnlineServiceDecoding.decimal(quote["09. change"]),
            changePercent: quote["10. change percent"] as? String ?? "Unavailable", tradingDay: day, intraday: [], exchangeTimeZone: nil)
    }
    public func addingIntraday(_ data: Data) throws -> Self {
        let root = try OnlineServiceDecoding.object(data)
        guard let series = root["Time Series (60min)"] as? [String: [String: Any]], !series.isEmpty else {
            throw OnlineDataError.invalid("Intraday data unavailable. Alpha Vantage may require a premium entitlement.")
        }
        let points = try series.keys.sorted().suffix(100).map { timestamp in
            _ = try OnlineServiceDecoding.calendarDate(String(timestamp.prefix(10)))
            let close = try OnlineServiceDecoding.decimal(series[timestamp]?["4. close"])
            guard close > 0 else { throw OnlineDataError.invalid("Intraday close price is invalid.") }
            return OnlineStockPoint(time: timestamp, close: close)
        }
        let zone = (root["Meta Data"] as? [String: Any])?["6. Time Zone"] as? String
        return Self(symbol: symbol, price: price, change: change, changePercent: changePercent,
            tradingDay: tradingDay, intraday: points, exchangeTimeZone: zone)
    }
}
