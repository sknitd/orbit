import SwiftUI
import Observation
import NotchCore

private enum OnlineSalesAdapter {
    static let pageSize = 100
    static let maximumPages = 10
    static func fetch(_ provider: OnlineSalesProvider, token: String, shopDomain: String, now: Date) async throws -> OnlineSalesReport {
        let day = OnlineServiceDecoding.utcDay(containing: now)
        let formatter = ISO8601DateFormatter()
        let start = formatter.string(from: day.start), end = formatter.string(from: day.end)
        var url: URL
        var headers = ["Accept": "application/json"]
        switch provider {
        case .stripe:
            url = try OnlineServiceHTTPS.url("https://api.stripe.com/v1/charges", [URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "created[gte]", value: String(Int(day.start.timeIntervalSince1970))),
                URLQueryItem(name: "created[lt]", value: String(Int(day.end.timeIntervalSince1970)))])
            headers["Authorization"] = "Bearer \(token)"
        case .shopify:
            let domain = shopDomain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard domain.range(of: #"^[a-z0-9][a-z0-9-]*\.myshopify\.com$"#, options: .regularExpression) != nil else {
                throw OnlineServiceError.message("Enter your store’s exact shop-name.myshopify.com domain without a path.")
            }
            url = try OnlineServiceHTTPS.url("https://\(domain)/admin/api/2026-01/graphql.json")
            headers["X-Shopify-Access-Token"] = token
        case .lemon:
            url = try OnlineServiceHTTPS.url("https://api.lemonsqueezy.com/v1/orders", [URLQueryItem(name: "page[size]", value: "100")])
            headers["Authorization"] = "Bearer \(token)"; headers["Accept"] = "application/vnd.api+json"
        case .gumroad:
            url = try OnlineServiceHTTPS.url("https://api.gumroad.com/v2/sales", [URLQueryItem(name: "access_token", value: token),
                URLQueryItem(name: "after", value: String(start.prefix(10))), URLQueryItem(name: "before", value: String(end.prefix(10)))])
        case .dodo:
            url = try OnlineServiceHTTPS.url("https://live.dodopayments.com/payments", [URLQueryItem(name: "page_size", value: "100"), URLQueryItem(name: "page_number", value: "0")])
            headers["Authorization"] = "Bearer \(token)"
        case .polar:
            url = try OnlineServiceHTTPS.url("https://api.polar.sh/v1/orders/", [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "sorting", value: "-created_at")])
            headers["Authorization"] = "Bearer \(token)"
        case .paddle:
            url = try OnlineServiceHTTPS.url("https://api.paddle.com/transactions", [URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "created_at[gte]", value: start), URLQueryItem(name: "created_at[lt]", value: end)])
            headers["Authorization"] = "Bearer \(token)"
        }
        let originalHost = url.host
        var cursor: String?
        var allOrders: [OnlineSalesOrder] = []
        var seen = Set<String>()
        var seenPages = Set<String>()
        var pages = 0
        var more = false
        repeat {
            try Task.checkCancellation()
            guard seenPages.insert(url.absoluteString + (cursor ?? "")).inserted else { throw OnlineServiceError.message("Provider returned a repeating pagination cursor.") }
            var body: Data?
            if provider == .shopify {
                let query = "query Orders($cursor: String, $filter: String!) { orders(first: 100, after: $cursor, query: $filter, sortKey: CREATED_AT, reverse: true) { edges { node { id name createdAt displayFinancialStatus totalPriceSet { shopMoney { amount currencyCode } } totalRefundedSet { shopMoney { amount currencyCode } } } } pageInfo { hasNextPage endCursor } } }"
                var variables: [String: Any] = ["filter": "created_at:>=\(start) created_at:<\(end)"]
                if let cursor { variables["cursor"] = cursor }
                body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
            }
            let data = try await OnlineServiceHTTPS.load(url, headers: headers, jsonBody: body)
            let page = try OnlineServiceDecoding.sales(data, provider: provider, fetchedAt: now)
            for order in page.orders where seen.insert(order.id).inserted { allOrders.append(order) }
            let root = try OnlineServiceDecoding.object(data)
            pages += 1
            var next: URL?
            more = false
            switch provider {
            case .stripe:
                more = root["has_more"] as? Bool == true
                if more, let rows = root["data"] as? [[String: Any]], let last = rows.last?["id"] as? String {
                    next = try replacingQuery(url, name: "starting_after", value: last)
                }
            case .shopify:
                let orders = (root["data"] as? [String: Any])?["orders"] as? [String: Any]
                let info = orders?["pageInfo"] as? [String: Any]
                more = info?["hasNextPage"] as? Bool == true
                if more, let endCursor = info?["endCursor"] as? String, !endCursor.isEmpty { cursor = endCursor; next = url }
            case .lemon:
                if let value = (root["links"] as? [String: Any])?["next"] as? String, !value.isEmpty { next = URL(string: value, relativeTo: url)?.absoluteURL; more = true }
            case .gumroad:
                if let value = root["next_page_url"] as? String, !value.isEmpty {
                    next = URL(string: value, relativeTo: url)?.absoluteURL
                    if let current = next { next = try replacingQuery(current, name: "access_token", value: token) }
                    more = true
                }
            case .dodo:
                if let rows = root["items"] as? [[String: Any]], rows.count >= pageSize {
                    more = true; next = try replacingQuery(url, name: "page_number", value: String(pages))
                }
            case .polar:
                let pagination = root["pagination"] as? [String: Any]
                let maximum = (pagination?["max_page"] as? NSNumber)?.intValue
                let count = (root["items"] as? [[String: Any]])?.count ?? 0
                more = maximum.map { pages < $0 } ?? (count >= pageSize)
                if more { next = try replacingQuery(url, name: "page", value: String(pages + 1)) }
            case .paddle:
                let meta = root["meta"] as? [String: Any], pagination = meta?["pagination"] as? [String: Any]
                more = pagination?["has_more"] as? Bool == true
                if more, let value = pagination?["next"] as? String { next = URL(string: value, relativeTo: url)?.absoluteURL }
            }
            if more {
                guard let next, OnlineServiceHTTPS.allowed(next), next.host == originalHost, next.path == url.path else {
                    throw OnlineServiceError.message("Provider returned missing or unsafe pagination information.")
                }
                url = next
            }
        } while more && pages < maximumPages
        let coverage = more ? "Truncated after \(pages) pages / at most 1,000 records. UTC-day totals are incomplete." : "\(pages) API page(s) read. UTC-day totals include supported paid records returned by the provider."
        return OnlineSalesReport(provider: provider, orders: allOrders.sorted { $0.date > $1.date }, fetchedAt: now,
            dayStart: day.start, dayEnd: day.end, coverage: coverage)
    }
    private static func replacingQuery(_ url: URL, name: String, value: String) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { throw OnlineServiceError.message("Invalid pagination URL.") }
        var items = components.queryItems ?? []; items.removeAll { $0.name == name }; items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        guard let next = components.url else { throw OnlineServiceError.message("Invalid pagination URL.") }
        return next
    }
}

@MainActor
@Observable
private final class OnlineSalesModel {
    var provider = OnlineSalesProvider.stripe
    var tokenInput = ""
    var shopDomain = UserDefaults.standard.string(forKey: "plus.sales.shopify.domain") ?? ""
    var connected: Set<OnlineSalesProvider> = []
    var reports: [OnlineSalesProvider: OnlineSalesReport] = [:]
    var failures: [OnlineSalesProvider: String] = [:]
    var fx: OnlineFXRates?
    var fxError: String?
    var convertUSD = true
    var busy = false
    var error: String?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    init() { reloadConnections() }
    private func account(_ provider: OnlineSalesProvider) -> String { "sales.\(provider.rawValue)" }
    private func reloadConnections() {
        do {
            var found = Set<OnlineSalesProvider>()
            for item in OnlineSalesProvider.allCases where try OnlineServiceKeychain.read(account(item)) != nil { found.insert(item) }
            connected = found
        } catch { self.error = error.localizedDescription }
    }
    func connect() {
        do {
            if provider == .shopify {
                let domain = shopDomain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard domain.range(of: #"^[a-z0-9][a-z0-9-]*\.myshopify\.com$"#, options: .regularExpression) != nil else { throw OnlineServiceError.message("Use your exact store-name.myshopify.com domain.") }
                shopDomain = domain; UserDefaults.standard.set(domain, forKey: "plus.sales.shopify.domain")
            }
            try OnlineServiceKeychain.save(tokenInput, account: account(provider)); tokenInput = ""; connected.insert(provider); error = nil
        } catch { self.error = error.localizedDescription }
    }
    func disconnect() {
        cancel()
        do { try OnlineServiceKeychain.remove(account(provider)); connected.remove(provider); reports.removeValue(forKey: provider); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false }
    func refresh() {
        cancel(); error = nil; failures = [:]; reports = [:]; fx = nil; fxError = nil
        guard !connected.isEmpty else { error = "Connect at least one provider with a read-only API key first."; return }
        busy = true
        let requested = OnlineSalesProvider.allCases.filter { connected.contains($0) }
        let ticket = generation
        job = Task {
            defer { if generation == ticket { busy = false } }
            let now = Date()
            for item in requested {
                do {
                    try Task.checkCancellation()
                    guard let token = try OnlineServiceKeychain.read(account(item)) else { throw OnlineServiceError.message("Saved provider key is unavailable.") }
                    let report = try await OnlineSalesAdapter.fetch(item, token: token, shopDomain: shopDomain, now: now)
                    try Task.checkCancellation(); reports[item] = report
                } catch is CancellationError { return }
                catch { if generation == ticket { failures[item] = error.localizedDescription } }
            }
            if convertUSD && !reports.isEmpty {
                do {
                    let url = try OnlineServiceHTTPS.url("https://api.frankfurter.dev/v1/latest", [URLQueryItem(name: "base", value: "USD")])
                    let data = try await OnlineServiceHTTPS.load(url)
                    let rates = try OnlineFXRates.decode(data); try Task.checkCancellation(); fx = rates
                } catch is CancellationError { return } catch { if generation == ticket { fxError = error.localizedDescription } }
            }
        }
    }
    var groupedTotals: [String: Decimal] {
        reports.values.reduce(into: [:]) { result, report in for (currency, total) in report.totals { result[currency, default: 0] += total } }
    }
}

@MainActor
struct SalesToolView: View {
    @State private var model = OnlineSalesModel()
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sales").font(.title2.bold())
                Text("Gross paid order/charge amounts for the current UTC day. Connect your own read-only keys. This is not net revenue or an accounting ledger.").font(.caption).foregroundStyle(.secondary)
                Picker("Provider", selection: $model.provider) { ForEach(OnlineSalesProvider.allCases) { Text($0.rawValue).tag($0) } }
                    .onChange(of: model.provider) { _, _ in model.tokenInput = "" }
                if model.provider == .shopify { TextField("store-name.myshopify.com", text: $model.shopDomain) }
                SecureField("Read-only API key / OAuth token", text: $model.tokenInput)
                Text(readAccess(model.provider)).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.connected.contains(model.provider) ? "Replace key" : "Connect") { model.connect() }.disabled(model.tokenInput.isEmpty || model.busy)
                    if model.connected.contains(model.provider) { Label("Keychain saved", systemImage: "key").font(.caption); Button("Disconnect") { model.disconnect() } }
                    Link("Provider API docs", destination: docs(model.provider)).font(.caption)
                }
                Toggle("Convert combined gross paid total to USD using dated Frankfurter rates", isOn: $model.convertUSD).font(.caption)
                Button("Refresh connected providers (\(model.connected.count))") { model.refresh() }.disabled(model.busy || model.connected.isEmpty)
                OnlineStatusView(busy: model.busy, error: model.error, cancel: model.cancel)
                if !model.reports.isEmpty {
                    Text("Gross paid · original currencies").font(.headline)
                    ForEach(model.groupedTotals.keys.sorted(), id: \.self) { currency in Text("\(currency) \(onlineAmount(model.groupedTotals[currency]!))") }
                    if let fx = model.fx {
                        let converted = fx.converted(model.groupedTotals)
                        Text("Combined USD gross paid: \(onlineAmount(converted.usd))").font(.headline)
                        Text("Frankfurter reference FX dated \(fx.rateDate); indicative conversion at that date, not settlement amounts.").font(.caption).foregroundStyle(.secondary)
                        if !converted.excluded.isEmpty { Text("Excluded from USD total: \(converted.excluded.joined(separator: ", ")) (no FX rate).").font(.caption).foregroundStyle(.orange) }
                    }
                }
                if let warning = model.fxError { Text("USD conversion unavailable: \(warning)").font(.caption).foregroundStyle(.orange) }
                ForEach(OnlineSalesProvider.allCases) { provider in
                    if let failure = model.failures[provider] { Text("\(provider.rawValue): \(failure)").font(.caption).foregroundStyle(.orange) }
                    if let report = model.reports[provider] {
                        GroupBox(provider.rawValue) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("UTC range: \(report.dayStart.formatted(.iso8601)) to \(report.dayEnd.formatted(.iso8601)) (end excluded)").font(.caption)
                                Text("Fetched \(report.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                                Text(report.coverage).font(.caption).foregroundStyle(.secondary)
                                if report.orders.isEmpty { Text("No supported paid records in this UTC day.").font(.caption) }
                                if report.refunds.isEmpty { Text("Refund amounts unavailable or absent in these order records. Refunds processed today are not queried.").font(.caption).foregroundStyle(.secondary) }
                                else {
                                    ForEach(report.refunds.keys.sorted(), id: \.self) { currency in
                                        Text("Refunds attached to these orders: \(currency) \(onlineAmount(report.refunds[currency]!))").font(.caption)
                                    }
                                }
                                ForEach(report.orders.prefix(10)) { order in
                                    HStack { Text(order.title).lineLimit(1); Spacer(); Text("\(order.currency) \(onlineAmount(order.amount))").monospacedDigit() }
                                        .font(.caption)
                                    Text(order.date.formatted(.iso8601)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text("No automatic requests. At most ten pages per provider per refresh; any cap is labeled. Original currency totals are never silently combined. Sales records remain in memory; API keys are kept only in this app’s Keychain namespace.").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }.frame(minWidth: 500, minHeight: 440).onDisappear { model.cancel() }
    }
    private func readAccess(_ provider: OnlineSalesProvider) -> String {
        switch provider {
        case .stripe: "Stripe restricted key: Charges Read permission only. Charges are gross captured paid amounts, not payout balance."
        case .shopify: "Shopify Admin access token: read_orders only. Current API version 2026-01; no write scopes needed."
        case .lemon: "Lemon Squeezy API key for reading orders. Use the least privileges your provider offers."
        case .gumroad: "Gumroad OAuth token with view_sales. The documented API transmits this token as a query parameter; it is never logged here."
        case .dodo: "Dodo live API key for reading payment records. The app never calls charge, refund or write endpoints."
        case .polar: "Polar organization token with orders:read. Only the order-list endpoint is called."
        case .paddle: "Paddle live API key with transactions.read permission only. Completed/paid transactions are included."
        }
    }
    private func docs(_ provider: OnlineSalesProvider) -> URL {
        let link: String = switch provider {
        case .stripe: "https://docs.stripe.com/api/charges/list"
        case .shopify: "https://shopify.dev/docs/api/admin-graphql/latest/queries/orders"
        case .lemon: "https://docs.lemonsqueezy.com/api/orders/list-all-orders"
        case .gumroad: "https://gumroad.com/api"
        case .dodo: "https://docs.dodopayments.com/api-reference/payments/list-payments"
        case .polar: "https://docs.polar.sh/api-reference/orders/list"
        case .paddle: "https://developer.paddle.com/api-reference/transactions/list-transactions"
        }
        return URL(string: link)!
    }
}
