import AppKit
import SwiftUI
import NotchCore
@preconcurrency import EventKit

@MainActor
final class PlusMeetingService: ObservableObject {
    static let shared = PlusMeetingService()
    static let liveDefaultsKey = "plus.meetings.live"
    @Published private(set) var meetings: [OrbitMeeting] = []
    @Published private(set) var connected = false
    @Published private(set) var status = "Connect Calendar to see upcoming meetings."
    @Published var liveEnabled: Bool {
        didSet { defaults.set(liveEnabled, forKey: Self.liveDefaultsKey); configurePolling() }
    }
    private let store = EKEventStore()
    private let defaults: UserDefaults
    private let opener: @MainActor (URL) -> Bool
    private var visibleTools = Set<String>()
    private var visible: Bool { !visibleTools.isEmpty }
    private var polling: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var started = false

    init(defaults: UserDefaults = .standard, opener: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults; self.opener = opener
        liveEnabled = defaults.bool(forKey: Self.liveDefaultsKey)
    }
    func start() {
        guard !started else { return }
        started = true
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        configurePolling()
    }
    func shutdown() {
        polling?.cancel(); polling = nil; started = false; visibleTools.removeAll()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil; meetings = []
    }
    func setToolVisible(_ value: Bool, toolID: String = "calendar") {
        if value { visibleTools.insert(toolID) } else { visibleTools.remove(toolID) }
        configurePolling()
    }
    func connect() async {
        do {
            guard try await store.requestFullAccessToEvents() else {
                connected = false; status = "Calendar access was denied. Enable it in Privacy & Security → Calendars."; return
            }
            refresh(); configurePolling()
        } catch { status = error.localizedDescription }
    }
    func refresh() {
        connected = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard connected else { meetings = []; status = "Connect Calendar to see upcoming meetings."; return }
        guard visible || liveEnabled else { meetings = []; status = "Meeting status is off while the dashboard is closed."; return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-86_400),
                                                end: now.addingTimeInterval(2 * 86_400), calendars: nil)
        meetings = store.events(matching: predicate).prefix(1_000).compactMap { Self.meeting(from: $0) }
        let count = MeetingPlanner.upcoming(meetings, at: now).count
        status = count == 0 ? "No upcoming timed events in the next 24 hours." : "\(count) upcoming event\(count == 1 ? "" : "s")"
    }
    static func meeting(from event: EKEvent) -> OrbitMeeting? {
        guard event.status != .canceled, let start = event.startDate, let end = event.endDate else { return nil }
        return OrbitMeeting(id: event.eventIdentifier ?? "\(start.timeIntervalSince1970)-\(event.title ?? "event")",
                title: event.title ?? "Untitled meeting", start: start, end: end, isAllDay: event.isAllDay,
                joinURL: MeetingLinkResolver.find(eventURL: event.url, location: event.location, notes: event.notes))
    }
    func upcoming(at date: Date) -> [OrbitMeeting] { MeetingPlanner.upcoming(meetings, at: date) }
    @discardableResult
    func join(_ meeting: OrbitMeeting, at date: Date = Date()) -> Bool {
        guard meeting.end > date, let url = MeetingLinkResolver.validated(meeting.joinURL) else {
            status = "This event has ended or has no supported meeting link."; return false
        }
        guard opener(url) else { status = "macOS could not open the meeting link."; return false }
        return true
    }
    private func configurePolling() {
        polling?.cancel(); polling = nil
        refresh()
        guard started || visible, visible || liveEnabled else { return }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                guard let self else { break }
                self.refresh()
            }
        }
    }
}

@MainActor
struct MeetingControlsView: View {
    @ObservedObject private var service = PlusMeetingService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Upcoming meetings", systemImage: "video").font(.headline)
                Spacer()
                Button { service.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh meetings").disabled(!service.connected)
            }
            Toggle("Show upcoming meetings while the notch is closed", isOn: $service.liveEnabled)
                .font(.callout)
            if service.connected {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let meetings = Array(service.upcoming(at: context.date).prefix(4))
                    if meetings.isEmpty { Text(service.status).foregroundStyle(.secondary) }
                    ForEach(meetings) { meeting in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(meeting.title).font(.callout.weight(.medium)).lineLimit(2)
                                Text("\(meeting.start.formatted(date: .abbreviated, time: .shortened)) · \(meeting.countdown(at: context.date))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("Join") { service.join(meeting) }.disabled(meeting.joinURL == nil)
                                .help(meeting.joinURL == nil ? "No supported meeting link in this event" : "Open this meeting link")
                        }
                    }
                }
            } else {
                Text(service.status).font(.callout).foregroundStyle(.secondary)
                Button("Connect Calendar for Meetings") { Task { await service.connect() } }
            }
            Text("Join supports Zoom, Google Meet, Teams, Webex and other recognized conferencing links in the event URL, location or notes. Opening is always your explicit action.")
                .font(.caption).foregroundStyle(.secondary)
        }.background(OrbitNativeToolVisibility(onVisible: { service.setToolVisible(true) },
                                               onHidden: { service.setToolVisible(false) }).frame(width: 0, height: 0))
            .onDisappear { service.setToolVisible(false) }
    }
}
