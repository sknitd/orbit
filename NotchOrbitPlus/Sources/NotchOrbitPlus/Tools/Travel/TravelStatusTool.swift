import AppKit
import SwiftUI
@preconcurrency import EventKit
import NotchCore

@MainActor
final class TravelStatusService: ObservableObject {
    static let shared = TravelStatusService()
    static let keyAccount = "aviationstack"
    @Published private(set) var calendarReferences: [TravelCalendarReference] = []
    @Published var selectedReferenceID = ""
    @Published var flightCodeInput = ""
    @Published var pageInput = ""
    @Published var keyInput = ""
    @Published private(set) var flights: [ProviderFlight] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var coverage = ""
    @Published var liveEnabled: Bool { didSet { defaults.set(liveEnabled, forKey: "plus.travel.live") } }
    private let defaults: UserDefaults
    private let load: ProviderReadOnlyHTTPS.Loader
    private let readKey: @MainActor () throws -> String?
    private let readCalendar: @MainActor () throws -> [TravelCalendarReference]
    private var job: Task<Void, Never>?
    private var generation = UUID()
    init(defaults: UserDefaults = .standard, load: @escaping ProviderReadOnlyHTTPS.Loader = ProviderReadOnlyHTTPS.load,
         readKey: @escaping @MainActor () throws -> String? = { try OnlineServiceKeychain.read(TravelStatusService.keyAccount) },
         readCalendar: @escaping @MainActor () throws -> [TravelCalendarReference] = { try TravelStatusService.authorizedCalendarReferences() }) {
        self.defaults = defaults; self.load = load; self.readKey = readKey; self.readCalendar = readCalendar
        liveEnabled = defaults.bool(forKey: "plus.travel.live")
    }
    deinit { job?.cancel() }
    func start() {}
    func shutdown() { cancel() }
    func setToolVisible(_ value: Bool) { if !value { cancel() } }
    var selectedReference: TravelCalendarReference? { calendarReferences.first { $0.id == selectedReferenceID } }
    static func authorizedCalendarReferences() throws -> [TravelCalendarReference] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw OnlineServiceError.message("Connect Calendar in the Calendar tool first. Travel does not request calendar access.") }
        let store = EKEventStore(), now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(7 * 86_400), calendars: nil)
        return store.events(matching: predicate).prefix(1_000).compactMap { event in
            guard event.status != .canceled, let start = event.startDate else { return nil }
            return TravelCalendarReference(eventID: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled calendar event",
                                           location: event.location, departure: start, isAllDay: event.isAllDay)
        }.sorted { $0.departure < $1.departure }
    }
    func refreshCalendar() {
        do {
            calendarReferences = try readCalendar(); error = nil
            if !calendarReferences.contains(where: { $0.id == selectedReferenceID }) { selectedReferenceID = calendarReferences.first?.id ?? "" }
            selectCalendarReference()
            coverage = "\(calendarReferences.count) candidate flight/train references in the next seven days. Verify codes before provider lookup."
        } catch { self.error = error.localizedDescription }
    }
    func selectCalendarReference() { if let selectedReference, selectedReference.kind == .flight { flightCodeInput = selectedReference.code } }
    func saveKey() {
        do { try OnlineServiceKeychain.save(keyInput, account: Self.keyAccount); keyInput = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func forgetKey() {
        cancel()
        do { try OnlineServiceKeychain.remove(Self.keyAccount); flights = []; fetchedAt = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func openPage() {
        do { NSWorkspace.shared.open(try ProviderBrowserLink.validated(pageInput.trimmingCharacters(in: .whitespacesAndNewlines))); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func refreshFlight() {
        cancel(); error = nil
        let code = flightCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: " ", with: "")
        guard AviationstackData.validFlightCode(code) else { error = "Enter an IATA flight number, such as BA123 or 6E123."; return }
        flightCodeInput = code
        let ticket = generation; busy = true
        job = Task { @MainActor [weak self] in
            guard let self, self.generation == ticket, !Task.isCancelled else { return }
            defer { if self.generation == ticket { self.busy = false; self.job = nil } }
            do {
                try Task.checkCancellation()
                guard let key = try readKey() else { throw OnlineServiceError.message("Save your Aviationstack API key first.") }
                try Task.checkCancellation()
                let url = try ProviderReadOnlyHTTPS.url(host: "api.aviationstack.com", path: "/v1/flights", query: [
                    .init(name: "access_key", value: key), .init(name: "flight_iata", value: code), .init(name: "limit", value: "100")])
                let page = try AviationstackData.decode(try await load(ProviderReadOnlyHTTPS.request(url, key: key)), requested: code)
                try Task.checkCancellation(); guard generation == ticket else { return }
                flights = page.flights; fetchedAt = Date()
                coverage = "\(flights.count) provider flights returned; dates below distinguish repeated flight numbers.\(page.limited ? " Limited to 100 records." : "")"
                if flights.isEmpty { error = "No matching live flight record returned. Provider coverage and plan entitlements may limit availability." }
            } catch is CancellationError {} catch { if generation == ticket { self.error = error.localizedDescription } }
        }
    }
    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false }
    var liveStatus: LiveNotchStatus? {
        guard liveEnabled else { return nil }
        let now = Date()
        if let reference = selectedReference, reference.departure > now, reference.departure.timeIntervalSince(now) <= 6 * 3_600 {
            let minutes = max(1, Int(ceil(reference.departure.timeIntervalSince(now) / 60)))
            return LiveNotchStatus(id: "travel-calendar-\(reference.id)", kind: .travel, title: "Calendar: \(reference.code) in \(minutes)m",
                                   detail: reference.title, toolID: "travelStatus")
        }
        if let fetchedAt, now.timeIntervalSince(fetchedAt) < 600,
           let flight = flights.first(where: { $0.status == "active" }) {
            return LiveNotchStatus(id: "travel-flight-\(flight.id)", kind: .travel, title: "\(flight.code) · \(flight.status)",
                                   detail: "\(flight.origin) → \(flight.destination) · read \(fetchedAt.formatted(date: .omitted, time: .shortened))", toolID: "travelStatus")
        }
        return nil
    }
}

@MainActor
struct TravelStatusToolView: View {
    @ObservedObject private var service: TravelStatusService
    init(service: TravelStatusService = .shared) { _service = ObservedObject(wrappedValue: service) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { SecureField("Aviationstack API key", text: $service.keyInput); Button("Save Key") { service.saveKey() }; Button("Disconnect") { service.forgetKey() } }
            HStack {
                TextField("Flight number", text: $service.flightCodeInput)
                Button("Refresh Flight") { service.refreshFlight() }.disabled(service.busy)
                Button("Read Authorized Calendar") { service.refreshCalendar() }
            }
            Picker("Calendar reference", selection: $service.selectedReferenceID) {
                Text("Choose a calendar reference").tag("")
                ForEach(service.calendarReferences) { Text("\($0.code) · \($0.title)").tag($0.id) }
            }.onChange(of: service.selectedReferenceID) { _, _ in service.selectCalendarReference() }
            if let reference = service.selectedReference {
                Text("Calendar departure: \(reference.departure.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                if reference.kind == .train { Text("Train live-data adapter is unavailable. The countdown uses the calendar event; open your operator's status page below.").font(.caption).foregroundStyle(.secondary) }
            }
            OnlineStatusView(busy: service.busy, error: service.error, cancel: { service.cancel() })
            List(service.flights) { flight in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(flight.code) · \(flight.origin) → \(flight.destination) · \(flight.status)").font(.callout)
                    Text("Scheduled \(flight.departure.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    if let estimated = flight.estimatedDeparture { Text("Provider estimate \(estimated.formatted(date: .abbreviated, time: .shortened))").font(.caption2) }
                    if let terminal = flight.terminal { Text("Terminal \(terminal)").font(.caption2) }
                    if let gate = flight.gate { Text("Gate \(gate)").font(.caption2) }
                }
            }.frame(height: 125)
            HStack { TextField("Optional HTTPS airline/train status page", text: $service.pageInput); Button("Open Page") { service.openPage() } }
            Toggle("Show calendar departure or recently read active flight in closed notch", isOn: $service.liveEnabled).font(.caption)
            Text(service.coverage).font(.caption2).foregroundStyle(.secondary)
            Text("No calendar reads or provider requests on appearance. Flight updates require Refresh; HTTPS availability depends on your Aviationstack plan.").font(.caption2).foregroundStyle(.secondary)
            Link("Aviationstack documentation", destination: URL(string: "https://aviationstack.com/documentation")!).font(.caption2)
        }.padding(12).onDisappear { service.setToolVisible(false) }
            .background(OrbitNativeToolVisibility(onVisible: {}, onHidden: { service.setToolVisible(false) }).frame(width: 0, height: 0))
    }
}
