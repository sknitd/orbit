import AppKit
import SwiftUI
import NotchCore

@MainActor
private final class ConverterToolStore: ObservableObject {
    @Published var family: UnitFamily = .length {
        didSet {
            fromID = family.units.first?.id ?? "m"
            toID = family.units.dropFirst().first?.id ?? fromID
        }
    }
    @Published var fromID = "m"
    @Published var toID = "ft"
    @Published var input = "1"
    @Published var copyError: String?
    var conversion: (value: Double?, error: String?) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = Locale.current.decimalSeparator ?? "."
        let normalized = separator == "." ? trimmed : trimmed.replacingOccurrences(of: separator, with: ".")
        guard let value = Double(normalized) else {
            return (nil, "Enter a number to convert.")
        }
        guard let source = family.units.first(where: { $0.id == fromID }),
              let target = family.units.first(where: { $0.id == toID }) else {
            return (nil, "Choose two units.")
        }
        do { return (try UnitConversion.convert(value, from: source, to: target), nil) }
        catch { return (nil, error.localizedDescription) }
    }
    var resultText: String? {
        guard let result = conversion.value else { return nil }
        let value = family == .temperature && abs(result) < 1e-10 ? 0 : result
        return value.formatted(.number.precision(.significantDigits(1...12)))
    }
    var targetSymbol: String { family.units.first(where: { $0.id == toID })?.symbol ?? "" }
    func swap() {
        let value = conversion.value
        let old = fromID; fromID = toID; toID = old
        if let value { input = String(value) }
    }
    func copyResult() {
        guard let resultText else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString("\(resultText) \(targetSymbol)", forType: .string) { copyError = nil }
        else { copyError = "macOS could not copy the result." }
    }
}

@MainActor
struct ConverterToolView: View {
    @StateObject private var store = ConverterToolStore()
    @State private var mode = "units"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Conversion", selection: $mode) { Text("Units").tag("units"); Text("Currency").tag("currency") }
                .pickerStyle(.segmented).padding([.top, .horizontal], 12)
            if mode == "currency" { CurrencyConverterToolView() }
            else { unitContent }
        }
    }
    private var unitContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Measurement", selection: $store.family) {
                ForEach(UnitFamily.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                TextField("Value", text: $store.input).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Value to convert")
                Picker("From", selection: $store.fromID) {
                    ForEach(store.family.units) { Text("\($0.title) (\($0.symbol))").tag($0.id) }
                }
                Button(action: store.swap) { Image(systemName: "arrow.left.arrow.right") }
                    .accessibilityLabel("Swap units and invert result")
                Picker("To", selection: $store.toID) {
                    ForEach(store.family.units) { Text("\($0.title) (\($0.symbol))").tag($0.id) }
                }
            }
            if let text = store.resultText {
                HStack {
                    Text("\(text) \(store.targetSymbol)").font(.title2.monospacedDigit()).textSelection(.enabled)
                    Spacer()
                    Button("Copy Result", action: store.copyResult)
                }
            } else { LocalToolError(message: store.conversion.error) }
            LocalToolError(message: store.copyError)
            Text("US and imperial volume units are labelled separately. Calculations run locally as you type.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding()
    }
}
