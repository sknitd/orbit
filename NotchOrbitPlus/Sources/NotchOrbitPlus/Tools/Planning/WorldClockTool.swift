import AppKit
import SwiftUI
import NotchCore

@MainActor
final class WorldClockToolModel: ObservableObject {
    static let shared = WorldClockToolModel()
    static let zonesKey = "plus.worldClock.zones"
    @Published private(set) var zoneIDs: [String]
    @Published private(set) var now = Date()
    @Published var error: String?
    @Published private(set) var malformedPreferences = false
    private let defaults: UserDefaults
    private let settingsDidChange: @MainActor () -> Void
    private var ticker: Task<Void, Never>?
    init(defaults: UserDefaults = .standard, settingsDidChange: @escaping @MainActor () -> Void = { PlusSyncService.shared.settingsDidChange() }) {
        self.defaults = defaults
        self.settingsDidChange = settingsDidChange
        zoneIDs = [TimeZone.current.identifier]
        do { zoneIDs = try exportSyncZoneIDs() }
        catch { zoneIDs = []; malformedPreferences = true; self.error = error.localizedDescription }
    }
    deinit { ticker?.cancel() }
    func add(_ zoneID: String) {
        guard !malformedPreferences else { error = "Reset saved zones with a backup before editing these unreadable preferences."; return }
        guard TimeZone(identifier: zoneID) != nil else { error = WorldClockError.unknownZone.localizedDescription; return }
        guard !zoneIDs.contains(zoneID) else { error = "That time zone is already saved."; return }
        guard zoneIDs.count < 12 else { error = "Save up to 12 time zones."; return }
        zoneIDs.append(zoneID); defaults.set(zoneIDs, forKey: Self.zonesKey); error = nil; settingsDidChange()
    }
    func remove(_ zoneID: String) {
        guard !malformedPreferences, zoneIDs.contains(zoneID) else { return }
        zoneIDs.removeAll { $0 == zoneID }; defaults.set(zoneIDs, forKey: Self.zonesKey); settingsDidChange()
    }
    func exportSyncZoneIDs() throws -> [String] {
        guard let raw = defaults.object(forKey: Self.zonesKey) else { return [TimeZone.current.identifier] }
        guard let values = raw as? [String] else { throw WorldClockError.invalidPreferences }
        return try WorldClockPreferences.validated(values)
    }
    func validateSyncZoneIDs(_ values: [String]) throws {
        _ = try exportSyncZoneIDs(); _ = try WorldClockPreferences.validated(values)
    }
    func applySyncedZoneIDs(_ values: [String]) throws {
        try validateSyncZoneIDs(values)
        zoneIDs = values; defaults.set(values, forKey: Self.zonesKey); malformedPreferences = false; error = nil
    }
    func resetMalformedZonesWithBackup() {
        guard malformedPreferences else { return }
        if let raw = defaults.object(forKey: Self.zonesKey) {
            defaults.set(raw, forKey: Self.zonesKey + ".backup." + UUID().uuidString)
        }
        zoneIDs = []; defaults.set(zoneIDs, forKey: Self.zonesKey); malformedPreferences = false
        error = nil; settingsDidChange()
    }
    func start() {
        guard ticker == nil else { return }
        now = Date()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.now = Date()
            }
        }
    }
    func stop() { ticker?.cancel(); ticker = nil }
    static func text(_ date: Date, zoneID: String) -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: zoneID)
        return formatter.string(from: date)
    }
}

@MainActor
struct WorldClockToolView: View {
    @ObservedObject private var model: WorldClockToolModel
    init(model: WorldClockToolModel = .shared) { _model = ObservedObject(wrappedValue: model) }
    @ObservedObject private var meetings = PlusMeetingService.shared
    @State private var mode = "now"
    @State private var meetingDate = Date()
    @State private var sourceZone = TimeZone.current.identifier
    @State private var selectedMeeting = ""
    @State private var adding = false
    @State private var search = ""
    private var instant: Date { mode == "now" ? model.now : meetingDate }
    private var availableZones: [String] {
        TimeZone.knownTimeZoneIdentifiers.filter { search.isEmpty || $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Display", selection: $mode) { Text("Now").tag("now"); Text("Meeting").tag("meeting") }.pickerStyle(.segmented).frame(width: 210)
                Spacer()
                Button("Add Time Zone") { adding = true }
            }
            LocalToolError(message: model.error)
            if model.malformedPreferences { Button("Reset Saved Zones with Backup") { model.resetMalformedZonesWithBackup() } }
            List(model.zoneIDs, id: \.self) { zoneID in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(zoneID.replacingOccurrences(of: "_", with: " ")).font(.callout.weight(.medium))
                        Text((try? WorldClockConversion.offsetLabel(for: instant, zoneID: zoneID)) ?? "Unknown time zone")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(WorldClockToolModel.text(instant, zoneID: zoneID)).monospacedDigit().font(.callout)
                    Button { model.remove(zoneID) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(zoneID)")
                }
            }.frame(height: 160).overlay {
                if model.zoneIDs.isEmpty { Text("Add a time zone to begin.").foregroundStyle(.secondary).allowsHitTesting(false) }
            }
            if mode == "meeting" {
                HStack {
                    Picker("Input zone", selection: $sourceZone) {
                        ForEach(Array(Set(model.zoneIDs + [sourceZone])).sorted(), id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                    }.frame(maxWidth: 240)
                    DatePicker("Meeting", selection: $meetingDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().environment(\.timeZone, TimeZone(identifier: sourceZone) ?? .current)
                }
                if meetings.connected {
                    let upcoming = meetings.upcoming(at: model.now)
                    Picker("Calendar meeting", selection: $selectedMeeting) {
                        Text("Choose an upcoming meeting").tag("")
                        ForEach(upcoming) { Text($0.title).tag($0.id) }
                    }.onChange(of: selectedMeeting) { _, id in
                        if let meeting = upcoming.first(where: { $0.id == id }) { meetingDate = meeting.start }
                    }
                    if upcoming.isEmpty { Text(meetings.status).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Connect Calendar in the Calendar tool to choose real upcoming meetings. You can convert a date here without calendar access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Saved IANA zones use their daylight-saving rules at the displayed date. All rows show the same instant; a repeated fall-back wall time uses the first occurrence.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
            .background(OrbitNativeToolVisibility(onVisible: {
                model.start(); meetings.setToolVisible(true, toolID: "worldClock")
            }, onHidden: {
                model.stop(); meetings.setToolVisible(false, toolID: "worldClock")
            }).frame(width: 0, height: 0))
            .onDisappear { model.stop(); meetings.setToolVisible(false, toolID: "worldClock") }
            .sheet(isPresented: $adding) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add Time Zone").font(.headline)
                    TextField("Search city or IANA zone", text: $search).textFieldStyle(.roundedBorder)
                    List(availableZones, id: \.self) { zone in
                        Button(zone.replacingOccurrences(of: "_", with: " ")) { model.add(zone); if model.error == nil { adding = false; search = "" } }
                            .buttonStyle(.plain).disabled(model.zoneIDs.contains(zone))
                    }.frame(height: 220)
                    LocalToolError(message: model.error)
                    Button("Cancel") { adding = false }
                }.padding().frame(width: 420)
            }
    }
}
