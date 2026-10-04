import Foundation

public struct OnlineCodexQuotaWindow: Identifiable, Sendable, Equatable {
    public let id: String
    public let usedPercent: Double
    public let durationMinutes: Int?
    public let resetsAt: Date?
    public var remainingPercent: Double { 100 - usedPercent }
    public var label: String {
        if durationMinutes == 300 { return "5-hour session" }
        if durationMinutes == 10_080 { return "Weekly" }
        if let durationMinutes { return "\(durationMinutes)-minute window" }
        return "\(id.capitalized) window (duration not reported)"
    }
}
public struct OnlineCodexQuota: Sendable, Equatable {
    public let windows: [OnlineCodexQuotaWindow]
    public let fetchedAt: Date
    /// Consumes only the documented account/rateLimits/read result, never account IDs, credits, tokens or upsell metadata.
    public static func decodeResult(_ data: Data, fetchedAt: Date = Date()) throws -> Self {
        let root = try OnlineServiceDecoding.object(data)
        let keyed = root["rateLimitsByLimitId"] as? [String: Any]
        guard let limits = (keyed?["codex"] as? [String: Any]) ?? (root["rateLimits"] as? [String: Any]) else {
            throw OnlineDataError.invalid("Codex returned no subscription rate-limit snapshot. Sign in with your installed CLI in Terminal and retry.")
        }
        var windows: [OnlineCodexQuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let raw = limits[key] as? [String: Any] else { continue }
            let percentDecimal = try OnlineServiceDecoding.decimal(raw["usedPercent"])
            let percent = NSDecimalNumber(decimal: percentDecimal).doubleValue
            guard percent.isFinite, (0...100).contains(percent) else { throw OnlineDataError.invalid("Codex returned an invalid used percentage.") }
            var duration: Int?
            if let value = raw["windowDurationMins"], !(value is NSNull) {
                let number = try OnlineServiceDecoding.decimal(value)
                guard number > 0, number <= 527_040, number == Decimal(NSDecimalNumber(decimal: number).intValue) else {
                    throw OnlineDataError.invalid("Codex returned an invalid window duration.")
                }
                duration = NSDecimalNumber(decimal: number).intValue
            }
            let reset: Date?
            if let value = raw["resetsAt"], !(value is NSNull) { reset = try OnlineServiceDecoding.date(value) }
            else { reset = nil }
            windows.append(OnlineCodexQuotaWindow(id: key, usedPercent: percent, durationMinutes: duration, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw OnlineDataError.invalid("Codex did not report any quota windows for this account.") }
        return Self(windows: windows, fetchedAt: fetchedAt)
    }
}
