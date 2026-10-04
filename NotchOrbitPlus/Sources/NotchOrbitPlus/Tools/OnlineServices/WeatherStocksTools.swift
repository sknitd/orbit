import SwiftUI
import Observation
import Charts
import NotchCore

@MainActor
final class OnlineWeatherModel: ObservableObject {
    static let shared = OnlineWeatherModel()
    typealias Loader = ProviderReadOnlyHTTPS.Loader
    @Published var query: String
    @Published private(set) var places: [OnlineWeatherPlace] = []
    @Published private(set) var cache: OnlineWeatherCache?
    @Published private(set) var air: WeatherAirObservation?
    @Published private(set) var rain: WeatherRainForecast?
    @Published private(set) var noticesFetchedAt: Date?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var noticesError: String?
    @Published var liveEnabled: Bool { didSet { defaults.set(liveEnabled, forKey: "plus.weather.live") } }
    @Published var monitoringEnabled: Bool {
        didSet { defaults.set(monitoringEnabled, forKey: "plus.weather.monitoring"); configureMonitoring(); if !monitoringEnabled && requestIsBackground { cancel() } }
    }
    private let defaults: UserDefaults
    private let load: Loader
    private var job: Task<Void, Never>?
    private var monitoring: Task<Void, Never>?
    private var requestIsBackground = false
    private var generation = UUID()
    init(defaults: UserDefaults = .standard, load: @escaping Loader = { request in
        if request.url?.host == "geocoding-api.open-meteo.com", let url = request.url { return try await OnlineServiceHTTPS.load(url) }
        return try await ProviderReadOnlyHTTPS.load(request)
    }) {
        self.defaults = defaults; self.load = load
        query = defaults.string(forKey: "plus.weather.city") ?? ""
        liveEnabled = defaults.bool(forKey: "plus.weather.live"); monitoringEnabled = defaults.bool(forKey: "plus.weather.monitoring")
        if let data = defaults.data(forKey: "plus.weather.cache") {
            do {
                guard data.count <= 100_000 else { throw CocoaError(.fileReadTooLarge) }
                let decoded = try JSONDecoder().decode(OnlineWeatherCache.self, from: data)
                try decoded.forecast.validate(); try Self.validate(decoded.place); cache = decoded
            } catch { self.error = "Cached weather could not be read. Refresh a location to replace it: \(error.localizedDescription)" }
        }
    }
    deinit { job?.cancel(); monitoring?.cancel() }
    func start() { configureMonitoring() }
    func shutdown() { monitoring?.cancel(); monitoring = nil; cancel() }
    func setToolVisible(_ visible: Bool) { if !visible && !monitoringEnabled { cancel() } }
    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false; requestIsBackground = false }
    private static func validate(_ place: OnlineWeatherPlace) throws {
        guard place.id > 0, !place.name.isEmpty, place.name.utf8.count <= 500, place.latitude.isFinite, place.longitude.isFinite,
              (-90...90).contains(place.latitude), (-180...180).contains(place.longitude) else { throw OnlineServiceError.message("The selected location has invalid coordinates or identity.") }
    }
    func search() {
        cancel(); error = nil; places = []
        let city = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard city.count >= 2, city.count <= 120 else { error = "Enter a city name (2–120 characters)."; return }
        defaults.set(city, forKey: "plus.weather.city")
        busy = true
        let ticket = generation
        job = Task {
            guard generation == ticket, !Task.isCancelled else { return }
            defer { if generation == ticket { busy = false } }
            do {
                try Task.checkCancellation()
                let url = try OnlineServiceHTTPS.url("https://geocoding-api.open-meteo.com/v1/search", [
                    URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "5"),
                    URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json")])
                let data = try await load(URLRequest(url: url))
                try Task.checkCancellation()
                let result = try JSONDecoder().decode(OnlineWeatherSearch.self, from: data).results ?? []
                try result.forEach { try Self.validate($0) }
                guard generation == ticket else { return }; places = result
                if places.isEmpty { error = "No city found. Try a nearby city or a more specific name." }
            } catch is CancellationError {} catch { if generation == ticket { self.error = error.localizedDescription } }
        }
    }
    func fetch(_ place: OnlineWeatherPlace, background: Bool = false) {
        if background && busy { return }
        cancel(); busy = true; error = nil; noticesError = nil; requestIsBackground = background
        let ticket = generation
        job = Task {
            guard generation == ticket, !Task.isCancelled else { return }
            defer { if generation == ticket { busy = false } }
            do {
                try Task.checkCancellation()
                try Self.validate(place)
                let url = try OnlineServiceHTTPS.url("https://api.open-meteo.com/v1/forecast", [
                    URLQueryItem(name: "latitude", value: String(place.latitude)), URLQueryItem(name: "longitude", value: String(place.longitude)),
                    URLQueryItem(name: "current", value: "temperature_2m,weather_code,wind_speed_10m"),
                    URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
                    URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: "7")])
                let data = try await load(ProviderReadOnlyHTTPS.request(url))
                let forecast = try JSONDecoder().decode(OnlineWeatherResponse.self, from: data)
                try forecast.validate(); try Task.checkCancellation()
                let coordinates = [URLQueryItem(name: "latitude", value: String(place.latitude)), URLQueryItem(name: "longitude", value: String(place.longitude))]
                var airObservation: WeatherAirObservation?, rainForecast: WeatherRainForecast?, failures: [String] = []
                do {
                    let airURL = try ProviderReadOnlyHTTPS.url(host: "air-quality-api.open-meteo.com", path: "/v1/air-quality", query: coordinates + [
                        .init(name: "current", value: "us_aqi,uv_index,pm2_5"), .init(name: "timezone", value: "GMT"), .init(name: "timeformat", value: "unixtime")])
                    airObservation = try WeatherAirObservation.decode(try await load(ProviderReadOnlyHTTPS.request(airURL)))
                    try Task.checkCancellation()
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append("AQI / UV unavailable: \(error.localizedDescription)") }
                try Task.checkCancellation()
                do {
                    let rainURL = try ProviderReadOnlyHTTPS.url(host: "api.open-meteo.com", path: "/v1/forecast", query: coordinates + [
                        .init(name: "minutely_15", value: "precipitation"), .init(name: "forecast_minutely_15", value: "8"),
                        .init(name: "timezone", value: "GMT"), .init(name: "timeformat", value: "unixtime")])
                    rainForecast = try WeatherRainForecast.decode(try await load(ProviderReadOnlyHTTPS.request(rainURL)))
                    try Task.checkCancellation()
                } catch is CancellationError { throw CancellationError() }
                catch { failures.append("15-minute rain forecast unavailable: \(error.localizedDescription)") }
                try Task.checkCancellation(); guard generation == ticket else { return }
                let fetched = OnlineWeatherCache(place: place, forecast: forecast, fetchedAt: Date())
                cache = fetched; places = []; air = airObservation; rain = rainForecast; noticesFetchedAt = Date()
                noticesError = failures.isEmpty ? nil : failures.joined(separator: "\n")
                defaults.set(try JSONEncoder().encode(fetched), forKey: "plus.weather.cache")
                if monitoringEnabled && monitoring == nil { configureMonitoring() }
            } catch is CancellationError {} catch { if generation == ticket { self.error = error.localizedDescription } }
        }
    }
    private func configureMonitoring() {
        monitoring?.cancel(); monitoring = nil
        guard monitoringEnabled, cache != nil else { return }
        monitoring = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(900)) } catch { return }
                guard let self, let place = cache?.place else { return }
                fetch(place, background: true)
            }
        }
    }
    var liveStatus: LiveNotchStatus? {
        let now = Date()
        guard liveEnabled, let noticesFetchedAt, now.timeIntervalSince(noticesFetchedAt) < 1_200, let cache else { return nil }
        if let rain = rain?.nextRain(at: now) {
            let minutes = max(0, Int(ceil(rain.date.timeIntervalSince(now) / 60)))
            return LiveNotchStatus(id: "weather-rain", kind: .weather, title: minutes == 0 ? "Rain forecast now" : "Rain forecast in ~\(minutes)m",
                                   detail: "\(cache.place.name) · \(rain.millimetres.formatted()) mm / 15min", toolID: "weather")
        }
        if let air, abs(air.date.timeIntervalSince(now)) <= 3_600 {
            if air.usAQI >= 101 { return LiveNotchStatus(id: "weather-aqi", kind: .weather, title: "US AQI \(Int(air.usAQI)) · \(air.aqiLabel)", detail: cache.place.name + " · model forecast", toolID: "weather") }
            if air.uvIndex >= 6 { return LiveNotchStatus(id: "weather-uv", kind: .weather, title: "High UV index \(air.uvIndex.formatted(.number.precision(.fractionLength(1))))", detail: cache.place.name + " · model forecast", toolID: "weather") }
        }
        return nil
    }
}

@MainActor
struct WeatherToolView: View {
    @ObservedObject private var model: OnlineWeatherModel
    init(model: OnlineWeatherModel = .shared) { _model = ObservedObject(wrappedValue: model) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Weather").font(.title2.bold())
                HStack { TextField("City", text: $model.query).onSubmit { model.search() }; Button("Search") { model.search() }.disabled(model.busy) }
                Text("City-based weather. No location permission or account required.").font(.caption).foregroundStyle(.secondary)
                OnlineStatusView(busy: model.busy, error: model.error, cancel: { model.cancel() })
                Toggle("Show AQI, UV or imminent-rain forecast notices in closed notch", isOn: $model.liveEnabled).font(.caption)
                Toggle("Monitor weather in the background every 15 minutes", isOn: $model.monitoringEnabled).font(.caption)
                ForEach(model.places) { place in Button(place.label) { model.fetch(place) }.buttonStyle(.bordered) }
                if let cache = model.cache {
                    HStack { Text(cache.place.label).font(.headline); Spacer(); Button("Refresh") { model.fetch(cache.place) }.disabled(model.busy) }
                    Text("\(cache.forecast.current.temperature_2m, specifier: "%.1f") °C · \(OnlineWeatherResponse.condition(cache.forecast.current.weather_code))")
                    Text("Wind \(cache.forecast.current.wind_speed_10m, specifier: "%.1f") km/h · provider local time \(cache.forecast.current.time)").font(.caption)
                    Text("Fetched \(cache.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · cached until you refresh")
                        .font(.caption).foregroundStyle(.secondary)
                    if Date().timeIntervalSince(cache.fetchedAt) > 3 * 3600 { Text("This forecast is more than three hours old.").foregroundStyle(.orange).font(.caption) }
                    if let air = model.air {
                        Text("US AQI \(air.usAQI, specifier: "%.0f") · \(air.aqiLabel) · UV \(air.uvIndex, specifier: "%.1f") · PM₂.₅ \(air.pm25, specifier: "%.1f") µg/m³").font(.caption)
                        Text("Air-quality model time \(air.date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let rain = model.rain {
                        if let next = rain.nextRain(at: Date(), within: 2 * 3_600) {
                            Text("Rain forecast at \(next.date.formatted(date: .omitted, time: .shortened)) · \(next.millimetres, specifier: "%.1f") mm / 15min").font(.caption)
                        } else { Text("No ≥0.1 mm interval in the returned next two hours.").font(.caption).foregroundStyle(.secondary) }
                    }
                    LocalToolError(message: model.noticesError)
                    Divider()
                    ForEach(Array(cache.forecast.daily.time.enumerated()), id: \.offset) { index, day in
                        HStack {
                            Text(day).monospacedDigit(); Spacer()
                            Text(OnlineWeatherResponse.condition(cache.forecast.daily.weather_code[index])).font(.caption)
                            Text("\(cache.forecast.daily.temperature_2m_min[index], specifier: "%.0f")–\(cache.forecast.daily.temperature_2m_max[index], specifier: "%.0f") °C")
                            Text("\(cache.forecast.daily.precipitation_probability_max[index], specifier: "%.0f")% rain").font(.caption)
                        }
                    }
                }
                Link("Weather: Open-Meteo · location data: GeoNames · CC BY 4.0", destination: URL(string: "https://open-meteo.com/")!).font(.caption)
                Text("Forecast notices use modelled US AQI ≥101, UV ≥6 or predicted rain in the next 30 minutes. Background requests occur only with your monitoring opt-in.").font(.caption2).foregroundStyle(.secondary)
            }.padding(16)
        }.frame(minWidth: 480, minHeight: 400).onDisappear { model.setToolVisible(false) }
            .background(OrbitNativeToolVisibility(onVisible: {}, onHidden: { model.setToolVisible(false) }).frame(width: 0, height: 0))
    }
}

@MainActor
@Observable
private final class OnlineStocksModel {
    var symbol = UserDefaults.standard.string(forKey: "plus.stocks.symbol") ?? ""
    var keyInput = ""
    var savedKey = false
    var includeIntraday = false
    var quote: OnlineStockQuote?
    var fetchedAt: Date?
    var error: String?
    var intradayError: String?
    var busy = false
    private var job: Task<Void, Never>?
    private var generation = UUID()
    init() { do { savedKey = try OnlineServiceKeychain.read("alphavantage") != nil } catch { self.error = error.localizedDescription } }
    func saveKey() {
        do { try OnlineServiceKeychain.save(keyInput, account: "alphavantage"); keyInput = ""; savedKey = true; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func forgetKey() {
        cancel()
        do { try OnlineServiceKeychain.remove("alphavantage"); savedKey = false; quote = nil; fetchedAt = nil }
        catch { self.error = error.localizedDescription }
    }
    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false }
    func fetch() {
        cancel(); error = nil; intradayError = nil
        let requested = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard requested.range(of: #"^[A-Z0-9][A-Z0-9.:-]{0,29}$"#, options: .regularExpression) != nil else {
            error = "Enter a valid provider ticker symbol."; return
        }
        symbol = requested; UserDefaults.standard.set(requested, forKey: "plus.stocks.symbol")
        busy = true
        let ticket = generation
        job = Task {
            defer { if generation == ticket { busy = false } }
            do {
                guard let key = try OnlineServiceKeychain.read("alphavantage") else { throw OnlineServiceError.message("Save your Alpha Vantage API key first.") }
                let url = try OnlineServiceHTTPS.url("https://www.alphavantage.co/query", [
                    URLQueryItem(name: "function", value: "GLOBAL_QUOTE"), URLQueryItem(name: "symbol", value: requested), URLQueryItem(name: "apikey", value: key)])
                let data = try await OnlineServiceHTTPS.load(url)
                let decoded = try OnlineStockQuote.decodeQuote(data)
                try Task.checkCancellation(); quote = decoded; fetchedAt = Date()
                if includeIntraday {
                    do {
                        let intradayURL = try OnlineServiceHTTPS.url("https://www.alphavantage.co/query", [
                            URLQueryItem(name: "function", value: "TIME_SERIES_INTRADAY"), URLQueryItem(name: "symbol", value: requested),
                            URLQueryItem(name: "interval", value: "60min"), URLQueryItem(name: "outputsize", value: "compact"), URLQueryItem(name: "apikey", value: key)])
                        let points = try await OnlineServiceHTTPS.load(intradayURL)
                        let plotted = try decoded.addingIntraday(points)
                        try Task.checkCancellation(); quote = plotted
                    } catch is CancellationError { throw CancellationError() }
                    catch { if generation == ticket { intradayError = error.localizedDescription } }
                }
            } catch is CancellationError {} catch { if generation == ticket { self.error = error.localizedDescription } }
        }
    }
}

@MainActor
struct StocksToolView: View {
    @State private var model = OnlineStocksModel()
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stocks").font(.title2.bold())
                Text("Alpha Vantage market data. Enter your own licensed API key; provider plan and exchange entitlements control availability and delay.").font(.caption).foregroundStyle(.secondary)
                HStack { SecureField(model.savedKey ? "Replace saved API key" : "Alpha Vantage API key", text: $model.keyInput); Button("Save key") { model.saveKey() }.disabled(model.keyInput.isEmpty) }
                if model.savedKey { HStack { Label("Key saved in Keychain", systemImage: "key"); Button("Disconnect") { model.forgetKey() } }.font(.caption) }
                Link("Get a key / provider documentation", destination: URL(string: "https://www.alphavantage.co/documentation/")!).font(.caption)
                HStack { TextField("Ticker symbol", text: $model.symbol).onSubmit { model.fetch() }; Button("Refresh") { model.fetch() }.disabled(model.busy || !model.savedKey) }
                Toggle("Also request hourly intraday chart (may require premium plan)", isOn: $model.includeIntraday).font(.caption)
                OnlineStatusView(busy: model.busy, error: model.error, cancel: { model.cancel() })
                if let quote = model.quote {
                    Text("\(quote.symbol) · \(onlineAmount(quote.price))").font(.title3.bold())
                    Text("Change \(onlineAmount(quote.change)) · \(quote.changePercent)")
                    Text("Latest provider trading day: \(quote.tradingDay)").font(.caption)
                    Text("Price uses the instrument’s trading currency; quote API does not identify currency. No USD conversion is implied.").font(.caption).foregroundStyle(.secondary)
                    if let fetched = model.fetchedAt { Text("Fetched \(fetched.formatted(date: .abbreviated, time: .shortened)) · refresh manually").font(.caption).foregroundStyle(.secondary) }
                    if !quote.intraday.isEmpty {
                        Chart(quote.intraday) { point in LineMark(x: .value("Provider time", point.time), y: .value("Close", NSDecimalNumber(decimal: point.close).doubleValue)) }
                            .chartXAxis(.hidden).frame(height: 150)
                        Text("Hourly close · time zone: \(quote.exchangeTimeZone ?? "not reported")").font(.caption)
                    }
                }
                if let warning = model.intradayError { Text(warning).font(.caption).foregroundStyle(.orange) }
                Text("No automatic refresh. Data can be delayed or end-of-day; this view does not claim live exchange quotes.").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }.frame(minWidth: 480, minHeight: 400).onDisappear { model.cancel() }
    }
}
