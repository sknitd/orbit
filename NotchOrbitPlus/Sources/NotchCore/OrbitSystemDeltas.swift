import Foundation

public struct OrbitNetworkBytes: Sendable, Equatable {
    public let received: UInt64
    public let sent: UInt64
    public init(received: UInt64, sent: UInt64) { self.received = received; self.sent = sent }
}
public struct OrbitNetworkRate: Sendable, Equatable {
    public let received: Double
    public let sent: Double
    public init(received: Double, sent: Double) { self.received = received; self.sent = sent }
}
public enum OrbitSystemDeltas {
    public static func interfaceRates(current: [OrbitNetworkInterface], previous: [OrbitNetworkInterface], elapsed: Double) -> [String: OrbitNetworkRate] {
        guard elapsed.isFinite, elapsed > 0 else { return [:] }
        let old = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var rates: [String: OrbitNetworkRate] = [:]
        for interface in current where interface.isActive {
            guard let before = old[interface.name], before.isActive,
                  let bytes = interface.bytes, let prior = before.bytes,
                  let rate = networkRate(current: [interface.name: bytes], previous: [interface.name: prior], elapsed: elapsed) else { continue }
            rates[interface.name] = rate
        }
        return rates
    }
    /// Mach ticks: user, system, idle, nice. UInt32 rollover is intentional.
    public static func cpuPercent(current: [UInt32], previous: [UInt32]) -> Double? {
        guard current.count == 4, previous.count == 4 else { return nil }
        let deltas = zip(current, previous).map { UInt64($0 &- $1) }
        let total = deltas.reduce(UInt64(0), +)
        guard total > 0 else { return nil }
        return 100 * Double(total - deltas[2]) / Double(total)
    }
    public static func networkRate(current: [String: OrbitNetworkBytes], previous: [String: OrbitNetworkBytes], elapsed: Double) -> OrbitNetworkRate? {
        guard elapsed.isFinite, elapsed > 0 else { return nil }
        var received = 0.0; var sent = 0.0; var found = false
        for (name, value) in current {
            guard let old = previous[name], value.received >= old.received, value.sent >= old.sent else { continue }
            found = true
            received += Double(value.received - old.received)
            sent += Double(value.sent - old.sent)
        }
        guard found else { return nil }
        let incoming = received / elapsed, outgoing = sent / elapsed
        guard incoming.isFinite, outgoing.isFinite else { return nil }
        return OrbitNetworkRate(received: incoming, sent: outgoing)
    }
}
