import SwiftUI
import Foundation
import Darwin
import IOKit.ps
import NotchCore

private struct OrbitSystemReading: Sendable {
    let uptime: Double
    let ticks: [UInt32]?
    let memoryUsed: UInt64?
    let memoryTotal: UInt64
    let diskAvailable: Int64?
    let diskTotal: Int64?
    let network: [String: OrbitNetworkBytes]
    let batteryPercent: Double?
    let batteryState: String?
    let errors: [String]
}

private enum OrbitSystemReader {
    static func read() throws -> OrbitSystemReading {
        try Task.checkCancellation()
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var errors: [String] = []
        var cpu = host_cpu_load_info()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuStatus = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(host, host_flavor_t(HOST_CPU_LOAD_INFO), $0, &cpuCount)
            }
        }
        let ticks: [UInt32]?
        if cpuStatus == KERN_SUCCESS { ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3] }
        else { ticks = nil; errors.append("CPU counters unavailable (\(cpuStatus)).") }

        var memory = vm_statistics64()
        var memoryCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let memoryStatus = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(memoryCount)) {
                host_statistics64(host, host_flavor_t(HOST_VM_INFO64), $0, &memoryCount)
            }
        }
        var pageSize: vm_size_t = 0
        let pageStatus = host_page_size(host, &pageSize)
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let used: UInt64?
        if memoryStatus == KERN_SUCCESS, pageStatus == KERN_SUCCESS {
            let pages = UInt64(memory.active_count) + UInt64(memory.wire_count) + UInt64(memory.compressor_page_count)
            used = min(totalMemory, pages * UInt64(pageSize))
        } else { used = nil; errors.append("Memory counters unavailable.") }

        try Task.checkCancellation()
        var diskAvailable: Int64?; var diskTotal: Int64?
        do {
            let volume = try URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            diskAvailable = volume.volumeAvailableCapacityForImportantUsage
            diskTotal = volume.volumeTotalCapacity.map(Int64.init)
        } catch { errors.append("Home volume capacity unavailable: \(error.localizedDescription)") }

        var network: [String: OrbitNetworkBytes] = [:]
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0 {
            defer { freeifaddrs(interfaces) }
            var cursor = interfaces
            while let pointer = cursor {
                let entry = pointer.pointee
                if let address = entry.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                   entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                   let name = entry.ifa_name, let data = entry.ifa_data {
                    let counters = data.assumingMemoryBound(to: if_data.self).pointee
                    network[String(cString: name)] = OrbitNetworkBytes(received: UInt64(counters.ifi_ibytes), sent: UInt64(counters.ifi_obytes))
                }
                cursor = entry.ifa_next
            }
        } else { errors.append("Network interface counters unavailable.") }

        var batteryPercent: Double?; var batteryState: String?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() {
            for source in sources as NSArray {
                guard let values = IOPSGetPowerSourceDescription(info, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                      values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = values[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                batteryPercent = min(100, max(0, 100 * Double(current) / Double(maximum)))
                if values[kIOPSIsChargingKey] as? Bool == true { batteryState = "Charging" }
                else if values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue { batteryState = "Power adapter" }
                else { batteryState = "Battery power" }
                break
            }
        }
        return OrbitSystemReading(uptime: ProcessInfo.processInfo.systemUptime, ticks: ticks,
            memoryUsed: used, memoryTotal: totalMemory, diskAvailable: diskAvailable, diskTotal: diskTotal,
            network: network, batteryPercent: batteryPercent, batteryState: batteryState, errors: errors)
    }
}

@MainActor
private final class OrbitSystemModel: ObservableObject {
    @Published var reading: OrbitSystemReading?
    @Published var cpuPercent: Double?
    @Published var networkRate: OrbitNetworkRate?
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func resume() {
        guard task == nil else { return }
        let id = UUID(); generation = id
        task = Task { [weak self] in
            guard let self else { return }
            var previous: OrbitSystemReading?
            defer { if self.generation == id { self.task = nil } }
            while !Task.isCancelled, self.generation == id {
                do {
                    let sample = Task.detached { try OrbitSystemReader.read() }
                    let value = try await withTaskCancellationHandler { try await sample.value } onCancel: { sample.cancel() }
                    try Task.checkCancellation()
                    guard self.generation == id else { return }
                    if let old = previous {
                        if let currentTicks = value.ticks, let oldTicks = old.ticks {
                            self.cpuPercent = OrbitSystemDeltas.cpuPercent(current: currentTicks, previous: oldTicks)
                        } else { self.cpuPercent = nil }
                        self.networkRate = OrbitSystemDeltas.networkRate(current: value.network, previous: old.network, elapsed: value.uptime - old.uptime)
                    } else { self.cpuPercent = nil; self.networkRate = nil }
                    self.reading = value; self.error = nil; previous = value
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError { return }
                catch { if self.generation == id { self.error = error.localizedDescription }; return }
            }
        }
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil }
}

@MainActor
struct SystemToolView: View {
    @StateObject private var model = OrbitSystemModel()
    private func bytes(_ count: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System").font(.headline)
            if let value = model.reading {
                LabeledContent("CPU", value: model.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "Measuring…")
                if let cpu = model.cpuPercent { ProgressView(value: cpu, total: 100) }
                LabeledContent("Memory", value: value.memoryUsed.map { bytes($0) + " / " + bytes(value.memoryTotal) } ?? "Unavailable")
                Text("Active, wired, and compressed memory; inactive cache is excluded.").font(.caption).foregroundStyle(.secondary)
                if let available = value.diskAvailable, let total = value.diskTotal {
                    LabeledContent("Home volume", value: ByteCountFormatter.string(fromByteCount: available, countStyle: .file) + " available / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                }
                if let rate = model.networkRate {
                    LabeledContent("Network ↓ / ↑", value: bytes(UInt64(max(0, rate.received))) + "/s / " + bytes(UInt64(max(0, rate.sent))) + "/s")
                } else { LabeledContent("Network", value: value.network.isEmpty ? "No active interfaces" : "Measuring…") }
                Text("Traffic totals cover active interfaces. VPN/tunnel traffic may be counted more than once; this does not measure Internet reachability.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Battery", value: value.batteryPercent.map { String(format: "%.0f%%", $0) + " · " + (value.batteryState ?? "") } ?? "No internal battery reported")
                ForEach(value.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            } else { ProgressView("Reading system counters…") }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.onAppear { model.resume() }.onDisappear { model.stop() }
            .background(OrbitNativeToolVisibility(onVisible: model.resume, onHidden: model.stop).frame(width: 0, height: 0))
    }
}
