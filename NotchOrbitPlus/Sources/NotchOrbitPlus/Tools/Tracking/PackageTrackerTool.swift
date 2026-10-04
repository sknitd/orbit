import AppKit
import SwiftUI
import NotchCore

@MainActor
final class PackageTrackerService: ObservableObject {
    static let shared = PackageTrackerService()
    static let keyAccount = "aftership"
    @Published private(set) var references: [PackageReference] = []
    @Published private(set) var trackings: [PackageTracking] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var busy = false
    @Published var numberInput = ""
    @Published var pageInput = ""
    @Published var keyInput = ""
    @Published var liveEnabled: Bool { didSet { defaults.set(liveEnabled, forKey: "plus.package.live") } }
    @Published var error: String?
    @Published private(set) var coverage = ""
    private let defaults: UserDefaults
    private let load: ProviderReadOnlyHTTPS.Loader
    private let readKey: @MainActor () throws -> String?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    init(defaults: UserDefaults = .standard, load: @escaping ProviderReadOnlyHTTPS.Loader = ProviderReadOnlyHTTPS.load,
         readKey: @escaping @MainActor () throws -> String? = { try OnlineServiceKeychain.read(PackageTrackerService.keyAccount) }) {
        self.defaults = defaults; self.load = load; self.readKey = readKey
        liveEnabled = defaults.bool(forKey: "plus.package.live")
        if let raw = defaults.object(forKey: "plus.package.references") {
            do {
                references = try Self.decodeReferences(raw)
            } catch { self.error = "Could not read saved package references. Their original is preserved: \(error.localizedDescription)" }
        }
    }
    deinit { job?.cancel() }
    func start() {}
    func shutdown() { cancel() }
    func setToolVisible(_ value: Bool) { if !value { cancel() } }
    func saveKey() {
        do { try OnlineServiceKeychain.save(keyInput, account: Self.keyAccount); keyInput = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func forgetKey() {
        cancel()
        do { try OnlineServiceKeychain.remove(Self.keyAccount); trackings = []; fetchedAt = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func add() {
        do {
            guard references.count < 20 else { throw OnlineServiceError.message("Save up to 20 tracking numbers.") }
            let number = numberInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !references.contains(where: { $0.number.caseInsensitiveCompare(number) == .orderedSame }) else { throw OnlineServiceError.message("This tracking number is already saved.") }
            let page = pageInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let reference = try PackageReference(number: number, pageURL: page.isEmpty ? nil : ProviderBrowserLink.validated(page))
            references.append(reference); try persist(); numberInput = ""; pageInput = ""; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func remove(_ reference: PackageReference) {
        cancel(); references.removeAll { $0.id == reference.id }; trackings.removeAll { $0.number == reference.number }
        do { try persist(); error = nil } catch { self.error = error.localizedDescription }
    }
    private func persist() throws {
        if let old = defaults.object(forKey: "plus.package.references"), (try? Self.decodeReferences(old)) == nil {
            defaults.set(old, forKey: "plus.package.references.backup." + UUID().uuidString)
        }
        defaults.set(try JSONEncoder().encode(references), forKey: "plus.package.references")
    }
    private static func decodeReferences(_ raw: Any) throws -> [PackageReference] {
        guard let data = raw as? Data, data.count <= 100_000 else { throw OnlineServiceError.message("Saved package references have an unsupported type or size.") }
        let values = try JSONDecoder().decode([PackageReference].self, from: data)
        guard values.count <= 20, Set(values.map { $0.number.uppercased() }).count == values.count else {
            throw OnlineServiceError.message("Saved package references are invalid; their original is preserved.")
        }
        try values.forEach { try $0.validate() }; return values
    }
    func refresh() {
        cancel(); error = nil
        guard !references.isEmpty else { error = "Add a tracking number first."; return }
        let requested = Set(references.map(\.number)), ticket = generation
        busy = true
        job = Task { @MainActor [weak self] in
            guard let self, self.generation == ticket, !Task.isCancelled else { return }
            defer { if self.generation == ticket { self.busy = false; self.job = nil } }
            do {
                try Task.checkCancellation()
                guard let key = try readKey() else { throw OnlineServiceError.message("Save your AfterShip API key first.") }
                var cursor: String?, seenCursors = Set<String>(), found: [PackageTracking] = [], seenIDs = Set<String>()
                for _ in 0..<3 {
                    try Task.checkCancellation(); guard self.generation == ticket else { return }
                    var query = [URLQueryItem(name: "tracking_numbers", value: requested.sorted().joined(separator: ",")), URLQueryItem(name: "limit", value: "100")]
                    if let cursor { query.append(.init(name: "cursor", value: cursor)) }
                    let url = try ProviderReadOnlyHTTPS.url(host: "api.aftership.com", path: "/tracking/\(AfterShipTrackingData.version)/trackings", query: query)
                    let page = try AfterShipTrackingData.decode(try await load(ProviderReadOnlyHTTPS.request(url, key: key, header: "as-api-key")))
                    try Task.checkCancellation()
                    for item in page.trackings where requested.contains(item.number) && seenIDs.insert(item.id).inserted { found.append(item) }
                    cursor = page.nextCursor
                    guard let next = cursor else { break }
                    guard seenCursors.insert(next).inserted else { throw OnlineServiceError.message("AfterShip returned a repeating cursor.") }
                }
                guard self.generation == ticket else { return }
                trackings = found; fetchedAt = Date()
                let absent = requested.subtracting(found.map(\.number)).count
                coverage = "\(found.count) tracking record(s).\(absent > 0 ? " \(absent) number(s) absent; add them to your AfterShip account first." : "")\(cursor != nil ? " Limited to three API pages." : "")"
            } catch is CancellationError {} catch { if self.generation == ticket { self.error = error.localizedDescription } }
        }
    }
    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false }
    var liveStatus: LiveNotchStatus? {
        guard liveEnabled, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 6 * 3600, let item = trackings.first(where: \.isActive) else { return nil }
        return LiveNotchStatus(id: "package-\(item.id)", kind: .package, title: "\(item.number) · \(item.status)",
                               detail: "AfterShip read \(fetchedAt.formatted(date: .omitted, time: .shortened))", toolID: "packageTracker")
    }
}

@MainActor
struct PackageTrackerToolView: View {
    @ObservedObject private var service: PackageTrackerService
    init(service: PackageTrackerService = .shared) { _service = ObservedObject(wrappedValue: service) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { SecureField("AfterShip API key", text: $service.keyInput); Button("Save Key") { service.saveKey() }; Button("Disconnect") { service.forgetKey() } }
            HStack { TextField("Tracking number", text: $service.numberInput); Button("Add") { service.add() }; Button("Refresh") { service.refresh() }.disabled(service.busy) }
            TextField("Optional HTTPS carrier tracking page", text: $service.pageInput).textFieldStyle(.roundedBorder)
            OnlineStatusView(busy: service.busy, error: service.error, cancel: { service.cancel() })
            List(service.references) { reference in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(reference.number).font(.callout.weight(.medium)); Spacer()
                        if let url = reference.pageURL { Button("Open Page") { NSWorkspace.shared.open(url) }.buttonStyle(.borderless) }
                        Button { service.remove(reference) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Remove \(reference.number)")
                    }
                    let records = service.trackings.filter { $0.number == reference.number }
                    if records.isEmpty { Text("No provider record read for this number yet.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(records) { item in
                        Text("\(item.carrier) · \(item.status)").font(.caption)
                        if let eta = item.estimatedDelivery { Text("Provider ETA: \(eta)").font(.caption2) }
                        if let message = item.checkpoint { Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }.frame(height: 150)
            Toggle("Show recently read active deliveries in the closed notch", isOn: $service.liveEnabled).font(.caption)
            Text(service.coverage).font(.caption2).foregroundStyle(.secondary)
            if let date = service.fetchedAt { Text("Read \(date.formatted(date: .abbreviated, time: .shortened)) · refresh manually").font(.caption2).foregroundStyle(.secondary) }
            Text("AfterShip returns shipments already registered in your account. This tool reads tracking data; it does not register shipments. The optional carrier page opens only when you choose Open Page.").font(.caption2).foregroundStyle(.secondary)
            Link("AfterShip API documentation", destination: URL(string: "https://www.aftership.com/docs/tracking/quickstart/api-quick-start")!).font(.caption2)
        }.padding(12).onDisappear { service.setToolVisible(false) }
            .background(OrbitNativeToolVisibility(onVisible: { service.setToolVisible(true) }, onHidden: { service.setToolVisible(false) }).frame(width: 0, height: 0))
    }
}
