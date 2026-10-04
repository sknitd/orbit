import SwiftUI
import Observation
import Charts
import NotchCore

@MainActor
@Observable
private final class OnlineWeatherModel {
    var query = UserDefaults.standard.string(forKey: "plus.weather.city") ?? ""
    var places: [OnlineWeatherPlace] = []
    var cache: OnlineWeatherCache?
    var busy = false
    var error: String?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    init() {
        if let data = UserDefaults.standard.data(forKey: "plus.weather.cache") {
            if let decoded = try? JSONDecoder().decode(OnlineWeatherCache.self, from: data),
               (try? decoded.forecast.validate()) != nil { cache = decoded }
        }
    }
    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false }
    func search() {
        cancel(); error = nil; places = []
        let city = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard city.count >= 2, city.count <= 120 else { error = "Enter a city name (2–120 characters)."; return }
        UserDefaults.standard.set(city, forKey: "plus.weather.city")
        busy = true
        let ticket = generation
        job = Task {
            defer { if generation == ticket { busy = false } }
            do {
                let url = try OnlineServiceHTTPS.url("https://geocoding-api.open-meteo.com/v1/search", [
                    URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "5"),
                    URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json")])
                let data = try await OnlineServiceHTTPS.load(url)
                try Task.checkCancellation()
                places = try JSONDecoder().decode(OnlineWeatherSearch.self, from: data).results ?? []
                if places.isEmpty { error = "No city found. Try a nearby city or a more specific name." }
            } catch is CancellationError {} catch { if generation == ticket { self.error = error.localizedDescription } }
        }
    }
    func fetch(_ place: OnlineWeatherPlace) {
        cancel(); busy = true; error = nil
        let ticket = generation
        job = Task {
            defer { if generation == ticket { busy = false } }
            do {
                guard place.latitude.isFinite, place.longitude.isFinite,
                      (-90...90).contains(place.latitude), (-180...180).contains(place.longitude) else {
                    throw OnlineServiceError.message("The selected location has invalid coordinates.")
                }
                let url = try OnlineServiceHTTPS.url("https://api.open-meteo.com/v1/forecast", [
                    URLQueryItem(name: "latitude", value: String(place.latitude)), URLQueryItem(name: "longitude", value: String(place.longitude)),
                    URLQueryItem(name: "current", value: "temperature_2m,weather_code,wind_speed_10m"),
                    URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
                    URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: "7")])
                let data = try await OnlineServiceHTTPS.load(url)
                let forecast = try JSONDecoder().decode(OnlineWeatherResponse.self, from: data)
                try forecast.validate(); try Task.checkCancellation()
                let fetched = OnlineWeatherCache(place: place, forecast: forecast, fetchedAt: Date())
                cache = fetched; places = []
                UserDefaults.standard.set(try JSONEncoder().encode(fetched), forKey: "plus.weather.cache")
            } catch is CancellationError {} catch { if generation == ticket { self.error = error.localizedDescription } }
        }
    }
}

@MainActor
struct WeatherToolView: View {
    @State private var model = OnlineWeatherModel()
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Weather").font(.title2.bold())
                HStack { TextField("City", text: $model.query).onSubmit { model.search() }; Button("Search") { model.search() }.disabled(model.busy) }
                Text("City-based weather. No location permission or account required.").font(.caption).foregroundStyle(.secondary)
                OnlineStatusView(busy: model.busy, error: model.error, cancel: { model.cancel() })
                ForEach(model.places) { place in Button(place.label) { model.fetch(place) }.buttonStyle(.bordered) }
                if let cache = model.cache {
                    HStack { Text(cache.place.label).font(.headline); Spacer(); Button("Refresh") { model.fetch(cache.place) }.disabled(model.busy) }
                    Text("\(cache.forecast.current.temperature_2m, specifier: "%.1f") °C · \(OnlineWeatherResponse.condition(cache.forecast.current.weather_code))")
                    Text("Wind \(cache.forecast.current.wind_speed_10m, specifier: "%.1f") km/h · provider local time \(cache.forecast.current.time)").font(.caption)
                    Text("Fetched \(cache.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · cached until you refresh")
                        .font(.caption).foregroundStyle(.secondary)
                    if Date().timeIntervalSince(cache.fetchedAt) > 3 * 3600 { Text("This forecast is more than three hours old.").foregroundStyle(.orange).font(.caption) }
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
            }.padding(16)
        }.frame(minWidth: 480, minHeight: 400).onDisappear { model.cancel() }
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
