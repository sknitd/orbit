import Foundation

public struct WeatherAirObservation: Codable, Equatable, Sendable {
    public let date: Date
    public let usAQI: Double
    public let uvIndex: Double
    public let pm25: Double
    public var aqiLabel: String {
        switch usAQI { case ...50: "Good"; case ...100: "Moderate"; case ...150: "Unhealthy for sensitive groups"; case ...200: "Unhealthy"; case ...300: "Very unhealthy"; default: "Hazardous" }
    }
    public static func decode(_ data: Data) throws -> Self {
        let root = try OnlineServiceDecoding.object(data)
        guard let current = root["current"] as? [String: Any] else { throw OnlineDataError.invalid("Open-Meteo air-quality fields are unavailable.") }
        func numeric(_ name: String, maximum: Double) throws -> Double {
            let value = NSDecimalNumber(decimal: try OnlineServiceDecoding.decimal(current[name])).doubleValue
            guard value.isFinite, (0...maximum).contains(value) else { throw OnlineDataError.invalid("Invalid Open-Meteo \(name) value.") }
            return value
        }
        return Self(date: try OnlineServiceDecoding.date(current["time"]), usAQI: try numeric("us_aqi", maximum: 1_000),
                    uvIndex: try numeric("uv_index", maximum: 30), pm25: try numeric("pm2_5", maximum: 10_000))
    }
}
public struct WeatherRainPoint: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let millimetres: Double
}
public struct WeatherRainForecast: Codable, Equatable, Sendable {
    public let points: [WeatherRainPoint]
    public func nextRain(at date: Date, within duration: TimeInterval = 1_800) -> WeatherRainPoint? {
        points.first { $0.millimetres >= 0.1 && $0.date.addingTimeInterval(900) > date && $0.date <= date.addingTimeInterval(duration) }
    }
    public static func decode(_ data: Data) throws -> Self {
        let root = try OnlineServiceDecoding.object(data)
        guard let forecast = root["minutely_15"] as? [String: Any], let times = forecast["time"] as? [Any],
              let amounts = forecast["precipitation"] as? [Any], !times.isEmpty, times.count <= 16, times.count == amounts.count else {
            throw OnlineDataError.invalid("Open-Meteo did not return bounded 15-minute precipitation values.")
        }
        let points = try times.indices.map { index -> WeatherRainPoint in
            let amount = NSDecimalNumber(decimal: try OnlineServiceDecoding.decimal(amounts[index])).doubleValue
            guard amount.isFinite, (0...1_000).contains(amount) else { throw OnlineDataError.invalid("Invalid 15-minute precipitation amount.") }
            return WeatherRainPoint(date: try OnlineServiceDecoding.date(times[index]), millimetres: amount)
        }
        for index in 1..<points.count where points[index].date.timeIntervalSince(points[index - 1].date) != 900 {
            throw OnlineDataError.invalid("Precipitation timestamps must be consecutive 15-minute intervals.")
        }
        return Self(points: points)
    }
}
