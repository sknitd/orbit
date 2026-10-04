import Foundation

public enum CurrencyConversionError: Error, LocalizedError, Equatable, Sendable {
    case invalidAmount, missingRate(String), overflow
    public var errorDescription: String? {
        switch self {
        case .invalidAmount: "Enter a finite decimal amount."
        case .missingRate(let currency): "The dated reference rates do not include \(currency)."
        case .overflow: "The amount is outside the supported decimal range."
        }
    }
}

public enum CurrencyConversion {
    public static func convert(_ amount: Decimal, from: String, to: String, rates: OnlineFXRates) throws -> Decimal {
        guard !amount.isNaN else { throw CurrencyConversionError.invalidAmount }
        guard let source = rates.ratesPerUSD[from], source > 0 else { throw CurrencyConversionError.missingRate(from) }
        guard let target = rates.ratesPerUSD[to], target > 0 else { throw CurrencyConversionError.missingRate(to) }
        if from == to { return amount }
        var amount = amount, sourceRate = source, targetRate = target, dollars = Decimal(), result = Decimal()
        let divided = NSDecimalDivide(&dollars, &amount, &sourceRate, .bankers)
        guard divided == .noError || divided == .lossOfPrecision,
              !dollars.isNaN else { throw CurrencyConversionError.overflow }
        let multiplied = NSDecimalMultiply(&result, &dollars, &targetRate, .bankers)
        guard multiplied == .noError || multiplied == .lossOfPrecision,
              !result.isNaN else { throw CurrencyConversionError.overflow }
        return result
    }
}
