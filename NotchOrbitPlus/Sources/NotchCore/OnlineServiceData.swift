import Foundation
import CoreFoundation

public enum OnlineDataError: LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public enum OnlineSalesProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case stripe = "Stripe", shopify = "Shopify", lemon = "Lemon Squeezy", gumroad = "Gumroad"
    case dodo = "Dodo", polar = "Polar", paddle = "Paddle"
    public var id: String { rawValue }
}

public struct OnlineSalesOrder: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let date: Date
    public let amount: Decimal
    public let currency: String
    public let title: String
    /// Refund amount attached to this order, when exposed by the order API; not refunds processed today.
    public let refundedAmount: Decimal?
}

public struct OnlineSalesReport: Codable, Sendable {
    public let provider: OnlineSalesProvider
    public let orders: [OnlineSalesOrder]
    public let fetchedAt: Date
    public let dayStart: Date
    public let dayEnd: Date
    /// Deliberately explicit: adapters fetch at most the first page; this is never a complete sales ledger.
    public let coverage: String
    public var totals: [String: Decimal] {
        orders.reduce(into: [:]) { $0[$1.currency, default: 0] += $1.amount }
    }
    public var refunds: [String: Decimal] {
        orders.reduce(into: [:]) { result, order in
            if let refund = order.refundedAmount { result[order.currency, default: 0] += refund }
        }
    }
    public init(provider: OnlineSalesProvider, orders: [OnlineSalesOrder], fetchedAt: Date, dayStart: Date, dayEnd: Date, coverage: String) {
        self.provider = provider; self.orders = orders; self.fetchedAt = fetchedAt
        self.dayStart = dayStart; self.dayEnd = dayEnd; self.coverage = coverage
    }
}

public enum OnlineServiceDecoding {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 4 * 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineDataError.invalid("The provider response is not a supported JSON object.")
        }
        return value
    }
    public static func decimal(_ value: Any?) throws -> Decimal {
        guard let value else { throw OnlineDataError.invalid("Missing numeric amount.") }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            throw OnlineDataError.invalid("Boolean is not a numeric amount.")
        }
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
        guard text.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let result = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !result.isNaN else {
            throw OnlineDataError.invalid("Invalid numeric amount.")
        }
        return result
    }
    public static func date(_ value: Any?) throws -> Date {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
           (-62_135_596_800...253_402_300_799).contains(number.doubleValue) {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let text = value as? String else { throw OnlineDataError.invalid("Missing provider timestamp.") }
        _ = try calendarDate(String(text.prefix(10)))
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = fractional.date(from: text) ?? plain.date(from: text) else {
            throw OnlineDataError.invalid("Invalid provider timestamp; expected ISO 8601 with a time zone.")
        }
        return date
    }
    public static func calendarDate(_ text: String) throws -> Date {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw OnlineDataError.invalid("Invalid calendar date.")
        }
        let pieces = text.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let input = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
        guard let date = calendar.date(from: input), calendar.dateComponents([.year, .month, .day], from: date) == input else {
            throw OnlineDataError.invalid("Invalid calendar day.")
        }
        return date
    }
    public static func utcDay(containing date: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: date)
        return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
    }
    public static func majorUnits(_ minor: Decimal, currency: String) throws -> Decimal {
        let zero = Set(["BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"])
        let three = Set(["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"])
        guard minor >= 0, Locale.commonISOCurrencyCodes.contains(currency) else {
            throw OnlineDataError.invalid("Invalid amount or currency in an order.")
        }
        return minor / (zero.contains(currency) ? 1 : three.contains(currency) ? 1000 : 100)
    }
    public static func providerMajorUnits(_ minor: Decimal, currency: String, provider: OnlineSalesProvider) throws -> Decimal {
        guard minor >= 0, Locale.commonISOCurrencyCodes.contains(currency) else { throw OnlineDataError.invalid("Invalid provider amount or currency.") }
        // These order APIs document their integer amounts in cents. Dodo and Paddle use currency-smallest units.
        if [.lemon, .gumroad, .polar].contains(provider) { return minor / 100 }
        // Stripe has compatibility exceptions distinct from ISO currency exponents.
        if provider == .stripe && ["ISK", "UGX"].contains(currency) { return minor / 100 }
        if provider == .stripe && currency == "MGA" { return minor }
        return try majorUnits(minor, currency: currency)
    }

    public static func sales(_ data: Data, provider: OnlineSalesProvider, fetchedAt: Date = Date()) throws -> OnlineSalesReport {
        let root = try object(data)
        let rows: [[String: Any]]
        switch provider {
        case .stripe, .lemon, .paddle:
            guard let values = root["data"] as? [[String: Any]] else { throw OnlineDataError.invalid("Missing provider order array.") }
            rows = values
        case .gumroad:
            guard root["success"] as? Bool == true else { throw OnlineDataError.invalid("Gumroad did not return a successful sales response.") }
            guard let values = root["sales"] as? [[String: Any]] else { throw OnlineDataError.invalid("Missing Gumroad sales array.") }
            rows = values
        case .dodo, .polar:
            guard let values = root["items"] as? [[String: Any]] else { throw OnlineDataError.invalid("Missing provider order array.") }
            rows = values
        case .shopify:
            if root["errors"] != nil { throw OnlineDataError.invalid("Shopify rejected the order query. Check read_orders access and the store API configuration.") }
            guard let data = root["data"] as? [String: Any], let orders = data["orders"] as? [String: Any],
                  let edges = orders["edges"] as? [[String: Any]] else { throw OnlineDataError.invalid("Missing Shopify order page.") }
            rows = try edges.map {
                guard let node = $0["node"] as? [String: Any] else { throw OnlineDataError.invalid("Missing Shopify order node.") }
                return node
            }
        }
        // Error payloads must not masquerade as an empty successful ledger.
        let expectedKey: String = switch provider {
        case .stripe, .lemon, .paddle, .shopify: "data"
        case .gumroad: "sales"
        case .dodo, .polar: "items"
        }
        guard root[expectedKey] != nil else { throw OnlineDataError.invalid("The provider returned an error or an unsupported order response.") }
        let day = utcDay(containing: fetchedAt)
        var orders: [OnlineSalesOrder] = []
        var identities = Set<String>()
        for row in rows {
            let attributes = (row["attributes"] as? [String: Any]) ?? row
            let status = attributes["status"] as? String ?? ""
            if provider == .stripe && row["paid"] as? Bool != true { continue }
            if provider == .stripe && row["captured"] as? Bool == false { continue }
            if provider == .polar && row["paid"] as? Bool != true { continue }
            if provider == .lemon && !["paid", "refunded"].contains(status) { continue }
            if provider == .dodo && status != "succeeded" { continue }
            if provider == .paddle && !["completed", "paid"].contains(status) { continue }
            if provider == .shopify && !["PAID", "PARTIALLY_REFUNDED", "REFUNDED"].contains(row["displayFinancialStatus"] as? String ?? "") { continue }
            let dateValue = provider == .stripe ? row["created"] : provider == .shopify ? row["createdAt"] : attributes["created_at"]
            let date = try self.date(dateValue)
            guard date >= day.start && date < day.end else { continue }
            let id = (row["id"] as? String) ?? (row["payment_id"] as? String) ?? ""
            guard !id.isEmpty, identities.insert(id).inserted else { throw OnlineDataError.invalid("Missing or duplicate order identity.") }
            var currency = (attributes["currency"] as? String) ?? (attributes["currency_code"] as? String) ?? ""
            let amount: Decimal
            if provider == .shopify {
                guard let total = row["totalPriceSet"] as? [String: Any], let money = total["shopMoney"] as? [String: Any] else {
                    throw OnlineDataError.invalid("Shopify order has no shop currency total.")
                }
                currency = money["currencyCode"] as? String ?? ""
                amount = try decimal(money["amount"])
            } else {
                let value: Any?
                switch provider {
                case .stripe: value = row["amount_captured"] ?? row["amount"]
                case .lemon: value = attributes["total"]
                case .gumroad: value = row["price"]
                case .dodo: value = row["total_amount"]
                case .polar: value = row["total_amount"] ?? row["amount"]
                case .paddle:
                    let details = row["details"] as? [String: Any]
                    value = (details?["totals"] as? [String: Any])?["grand_total"]
                case .shopify: value = nil
                }
                currency = currency.uppercased()
                let minor = try decimal(value)
                amount = try providerMajorUnits(minor, currency: currency, provider: provider)
            }
            guard amount >= 0, Locale.commonISOCurrencyCodes.contains(currency) else {
                throw OnlineDataError.invalid("Invalid order total or currency.")
            }
            let title = (attributes["product_name"] as? String) ?? (row["name"] as? String) ?? (attributes["order_number"] as? String) ?? String(id.suffix(12))
            var refund: Decimal?
            if provider == .stripe, let value = row["amount_refunded"] {
                let minor = try decimal(value)
                refund = try providerMajorUnits(minor, currency: currency, provider: provider)
            }
            if provider == .polar, let value = row["refunded_amount"] {
                let netRefund = try decimal(value)
                let taxRefund = try row["refunded_tax_amount"].map { try decimal($0) } ?? 0
                refund = try providerMajorUnits(netRefund + taxRefund, currency: currency, provider: provider)
            }
            if provider == .lemon, let value = attributes["refunded_amount"] {
                refund = try providerMajorUnits(decimal(value), currency: currency, provider: provider)
            }
            if provider == .gumroad, row["refunded"] as? Bool == true { refund = amount }
            if provider == .shopify, let value = row["totalRefundedSet"] as? [String: Any], let money = value["shopMoney"] as? [String: Any] {
                guard money["currencyCode"] as? String == currency else { throw OnlineDataError.invalid("Refund currency differs from order currency.") }
                refund = try decimal(money["amount"])
            }
            if provider == .paddle, let totals = (row["adjustment_totals"] ?? row["adjustments_totals"]) as? [String: Any],
               let breakdown = totals["breakdown"] as? [String: Any], let value = breakdown["refund"] {
                guard totals["currency_code"] as? String == currency else { throw OnlineDataError.invalid("Paddle refund currency differs from transaction currency.") }
                refund = try majorUnits(decimal(value), currency: currency)
            }
            guard refund == nil || refund! >= 0 else { throw OnlineDataError.invalid("Invalid refund amount.") }
            orders.append(OnlineSalesOrder(id: id, date: date, amount: amount, currency: currency, title: title, refundedAmount: refund))
        }
        return OnlineSalesReport(provider: provider, orders: orders.sorted { $0.date > $1.date }, fetchedAt: fetchedAt,
            dayStart: day.start, dayEnd: day.end,
            coverage: "First API page only (up to 100 records). UTC-day totals may be incomplete. Gross paid amounts, not net revenue; refunds, fees and tax treatment vary by provider.")
    }
}

public struct OnlineAIUsageSnapshot: Codable, Identifiable, Sendable, Equatable {
    public var id: String { scope }
    public let scope: String
    public let used: Decimal
    public let limit: Decimal?
    public let unit: String
    public let resetsAt: Date?
    public var remaining: Decimal? { limit.map { max(0, $0 - used) } }
    public var fraction: Double? { limit.flatMap { $0 > 0 ? NSDecimalNumber(decimal: used / $0).doubleValue : nil } }
}
public struct OnlineAIUsageExport: Codable, Sendable, Equatable {
    public let provider: String
    public let exportedAt: Date
    public let snapshots: [OnlineAIUsageSnapshot]
    public func isStale(at date: Date) -> Bool { date.timeIntervalSince(exportedAt) > 6 * 3600 }
    public static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw OnlineDataError.invalid("Usage import exceeds 2 MB.") }
        let root = try OnlineServiceDecoding.object(data)
        guard let provider = root["provider"] as? String, ["Claude", "Codex", "Cursor", "Copilot", "Grok"].contains(provider),
              let rows = root["snapshots"] as? [[String: Any]], !rows.isEmpty, rows.count <= 2 else {
            throw OnlineDataError.invalid("Expected provider Claude/Codex/Cursor/Copilot/Grok and one or two quota snapshots.")
        }
        let exportedAt = try OnlineServiceDecoding.date(root["exported_at"])
        guard exportedAt <= now.addingTimeInterval(300) else { throw OnlineDataError.invalid("Usage export timestamp is in the future.") }
        var scopes = Set<String>()
        var snapshots: [OnlineAIUsageSnapshot] = []
        for row in rows {
            guard let scope = row["scope"] as? String, ["session", "weekly"].contains(scope), scopes.insert(scope).inserted,
                  let unit = row["unit"] as? String, ["tokens", "requests", "percent", "USD"].contains(unit) else {
                throw OnlineDataError.invalid("Scopes must be unique session/weekly values and units must be tokens, requests, percent or USD.")
            }
            let used = try OnlineServiceDecoding.decimal(row["used"])
            let limit = try row["limit"].map { try OnlineServiceDecoding.decimal($0) }
            guard used >= 0, limit == nil || limit! > 0 else { throw OnlineDataError.invalid("Usage must be nonnegative; supplied quota must be positive.") }
            let reset = try row["resets_at"].map { try OnlineServiceDecoding.date($0) }
            snapshots.append(OnlineAIUsageSnapshot(scope: scope, used: used, limit: limit, unit: unit, resetsAt: reset))
        }
        return Self(provider: provider, exportedAt: exportedAt, snapshots: snapshots)
    }
}
