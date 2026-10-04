import AppKit
import SwiftUI
import NotchCore

@MainActor
final class CurrencyConverterToolStore: ObservableObject {
    typealias Loader = @Sendable (URL) async throws -> Data
    @Published var input = "1"
    @Published var from = "USD"
    @Published var to = "EUR"
    @Published private(set) var rates: OnlineFXRates?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var busy = false
    @Published var error: String?
    private let load: Loader
    private var task: Task<Void, Never>?
    private var generation = 0
    init(load: @escaping Loader = { try await OnlineServiceHTTPS.load($0) }) { self.load = load }
    deinit { task?.cancel() }
    var currencies: [String] { rates?.ratesPerUSD.keys.sorted() ?? ["EUR", "USD"] }
    var result: (value: Decimal?, error: String?) {
        guard let rates else { return (nil, "Refresh reference rates to convert currencies.") }
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard raw.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN else {
            return (nil, CurrencyConversionError.invalidAmount.localizedDescription)
        }
        do { return (try CurrencyConversion.convert(amount, from: from, to: to, rates: rates), nil) }
        catch { return (nil, error.localizedDescription) }
    }
    var resultText: String? {
        guard let amount = result.value else { return nil }
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 8
        return formatter.string(from: NSDecimalNumber(decimal: amount))
    }
    func refresh() {
        cancel(); let requestGeneration = generation
        busy = true; error = nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try OnlineServiceHTTPS.url("https://api.frankfurter.dev/v1/latest", [URLQueryItem(name: "base", value: "USD")])
                let rates = try OnlineFXRates.decode(try await self.load(url))
                guard !Task.isCancelled, self.generation == requestGeneration else { return }
                self.rates = rates; self.fetchedAt = Date()
                if rates.ratesPerUSD[self.from] == nil { self.from = "USD" }
                if rates.ratesPerUSD[self.to] == nil { self.to = rates.ratesPerUSD["EUR"] != nil ? "EUR" : "USD" }
                self.busy = false; self.task = nil
            } catch {
                guard self.generation == requestGeneration else { return }
                self.busy = false; self.task = nil
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() { generation += 1; task?.cancel(); task = nil; busy = false }
    func swap() {
        let amount = result.value
        let old = from; from = to; to = old
        if let amount { input = NSDecimalNumber(decimal: amount).stringValue }
    }
    func copy() {
        guard let text = resultText else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString("\(text) \(to)", forType: .string) { error = nil }
        else { error = "macOS could not copy the converted amount." }
    }
}

@MainActor
struct CurrencyConverterToolView: View {
    @StateObject private var store: CurrencyConverterToolStore
    init(store: CurrencyConverterToolStore = .init()) { _store = StateObject(wrappedValue: store) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Currency", systemImage: "dollarsign.arrow.circlepath").font(.headline)
                Spacer()
                Button("Refresh Rates") { store.refresh() }.disabled(store.busy)
            }
            HStack {
                TextField("Amount", text: $store.input).textFieldStyle(.roundedBorder)
                Picker("From", selection: $store.from) { ForEach(store.currencies, id: \.self) { Text($0).tag($0) } }.frame(width: 120)
                Button { store.swap() } label: { Image(systemName: "arrow.left.arrow.right") }.help("Swap currencies and invert result")
                Picker("To", selection: $store.to) { ForEach(store.currencies, id: \.self) { Text($0).tag($0) } }.frame(width: 120)
            }
            if let result = store.resultText {
                HStack {
                    Text("\(result) \(store.to)").font(.title2.monospacedDigit()).textSelection(.enabled)
                    Spacer(); Button("Copy") { store.copy() }
                }
            } else { Text(store.result.error ?? "").font(.caption).foregroundStyle(.secondary) }
            OnlineStatusView(busy: store.busy, error: store.error, cancel: { store.cancel() })
            if let rates = store.rates {
                Text("Frankfurter reference rates dated \(rates.rateDate). Indicative conversion, not settlement or a live market quote.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let fetchedAt = store.fetchedAt { Text("Last read \(fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
            Text("Rates load only when you choose Refresh Rates. Available currencies come from the provider; conversion then runs locally.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12).onDisappear { store.cancel() }
            .background(OrbitNativeToolVisibility(onVisible: {}, onHidden: { store.cancel() }).frame(width: 0, height: 0))
    }
}
