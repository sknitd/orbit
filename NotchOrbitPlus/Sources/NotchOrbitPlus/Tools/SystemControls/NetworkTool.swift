import AppKit
import SwiftUI
import Darwin
import CoreWLAN
import NotchCore

struct SystemNetworkReading: Sendable {
    let interfaces: [OrbitNetworkInterface]
    let wifiSSID: String?
    let uptime: Double
    let date: Date
}
enum SystemNetworkReader {
    static func read() throws -> SystemNetworkReading {
        try Task.checkCancellation()
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else {
            throw SystemHardwareError.unavailable("Local network interfaces could not be read (\(errno)).")
        }
        defer { freeifaddrs(first) }
        struct Interface {
            var flags: UInt32
            var addresses: Set<String> = []
            var bytes: OrbitNetworkBytes?
        }
        var entries: [String: Interface] = [:]; var cursor = first
        while let pointer = cursor {
            try Task.checkCancellation()
            let entry = pointer.pointee
            defer { cursor = entry.ifa_next }
            guard let namePointer = entry.ifa_name else { continue }
            let name = String(cString: namePointer)
            var value = entries[name] ?? Interface(flags: entry.ifa_flags)
            value.flags = entry.ifa_flags
            if let address = entry.ifa_addr {
                let family = Int32(address.pointee.sa_family)
                if family == AF_LINK, let data = entry.ifa_data {
                    let bytes = data.assumingMemoryBound(to: if_data.self).pointee
                    value.bytes = .init(received: UInt64(bytes.ifi_ibytes), sent: UInt64(bytes.ifi_obytes))
                } else if family == AF_INET || family == AF_INET6 {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        value.addresses.insert(String(cString: host))
                    }
                }
            }
            entries[name] = value
        }
        let interfaces = entries.map { name, value in
            OrbitNetworkInterface(name: name, isUp: value.flags & UInt32(IFF_UP) != 0,
                                  isRunning: value.flags & UInt32(IFF_RUNNING) != 0,
                                  isLoopback: value.flags & UInt32(IFF_LOOPBACK) != 0,
                                  addresses: value.addresses.sorted(), bytes: value.bytes)
        }.sorted { $0.name < $1.name }
        // Read an existing association only; never scan, join, or request
        // location. macOS can redact SSID under current permission settings.
        let ssid = CWWiFiClient.shared().interface()?.ssid()
        return .init(interfaces: interfaces, wifiSSID: ssid, uptime: ProcessInfo.processInfo.systemUptime, date: Date())
    }
}

@MainActor
final class NetworkService: ObservableObject {
    static let shared = NetworkService()
    @Published private(set) var reading: SystemNetworkReading?
    @Published private(set) var rates: [String: OrbitNetworkRate] = [:]
    @Published private(set) var error: String?
    @Published private(set) var isSampling = false
    @Published var backgroundMonitoring = false { didSet { reconcile() } }
    private var visible = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func resume() { visible = true; reconcile() }
    func stop() { visible = false; reconcile() }
    func shutdown() { visible = false; backgroundMonitoring = false; reconcile() }
    private func reconcile() {
        guard visible || backgroundMonitoring else {
            generation = UUID(); task?.cancel(); task = nil; isSampling = false; reading = nil; rates = [:]; return
        }
        guard task == nil else { return }
        let token = UUID(); generation = token; isSampling = true
        task = Task { @MainActor [weak self] in
            var previous: SystemNetworkReading?
            while !Task.isCancelled {
                let work = Task.detached { try SystemNetworkReader.read() }
                do {
                    let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    try Task.checkCancellation()
                    guard let self, self.generation == token else { return }
                    self.rates = previous.map { OrbitSystemDeltas.interfaceRates(current: value.interfaces, previous: $0.interfaces, elapsed: value.uptime - $0.uptime) } ?? [:]
                    self.reading = value; self.error = nil; previous = value
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError { return }
                catch {
                    guard let self, self.generation == token else { return }
                    self.error = error.localizedDescription; self.task = nil; self.isSampling = false; return
                }
            }
        }
    }
}

@MainActor
struct NetworkToolView: View {
    @ObservedObject private var service = NetworkService.shared
    private func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "Unavailable" }
        let count = value >= Double(Int64.max) ? Int64.max : Int64(value)
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file) + "/s"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Network", systemImage: "network").font(.headline)
            Toggle("Monitor network while dashboard is closed", isOn: Binding(get: { service.backgroundMonitoring }, set: { service.backgroundMonitoring = $0 }))
            if let reading = service.reading {
                LabeledContent("Wi-Fi SSID", value: reading.wifiSSID ?? "Not available under the current permission or connection")
                let active = reading.interfaces.filter(\.isActive)
                if active.isEmpty { Text("No up-and-running non-loopback interfaces reported.").foregroundStyle(.secondary) }
                ForEach(active) { interface in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(interface.name, systemImage: interface.isTunnel ? "lock.shield" : "network").font(.callout.weight(.medium))
                            Spacer()
                            Text(interface.isTunnel ? "Tunnel / VPN interface" : "Active interface").font(.caption).foregroundStyle(.secondary)
                        }
                        if !interface.addresses.isEmpty { Text(interface.addresses.joined(separator: " · ")).font(.caption.monospaced()).textSelection(.enabled) }
                        if let speed = service.rates[interface.name] { Text("↓ \(rate(speed.received))  ↑ \(rate(speed.sent))").font(.caption.monospacedDigit()) }
                        else { Text(interface.bytes == nil ? "Counters unavailable" : "Measuring local byte-counter delta…").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text("Read \(reading.date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            } else { Text("Reading local interfaces…").foregroundStyle(.secondary) }
            if let error = service.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("Rates are per interface; physical and VPN traffic are not combined. A tunnel name does not prove that a VPN is connected, and interface activity does not prove Internet reachability. No external probe or network request runs. SSID may be redacted by macOS; this tool requests no location access.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { service.resume() }.onDisappear { service.stop() }
            .background(OrbitNativeToolVisibility(onVisible: service.resume, onHidden: service.stop).frame(width: 0, height: 0))
    }
}
