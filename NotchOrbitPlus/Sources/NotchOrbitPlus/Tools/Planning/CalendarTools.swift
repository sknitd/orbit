import SwiftUI
import AppKit
@preconcurrency import EventKit

@MainActor
final class CalendarToolModel: ObservableObject {
    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var status = "Connect Apple Calendar to see your month and events."
    @Published private(set) var connected = false
    private let store = EKEventStore()

    func connect(month: Date) async {
        do {
            guard try await store.requestFullAccessToEvents() else {
                status = "Calendar access was denied. Enable it in System Settings → Privacy & Security → Calendars."
                return
            }
            connected = true
            refresh(month: month)
        } catch { status = error.localizedDescription }
    }
    func refresh(month: Date) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            connected = false; events = []; return
        }
        connected = true
        guard let interval = Calendar.current.dateInterval(of: .month, for: month) else { return }
        events = store.events(matching: store.predicateForEvents(withStart: interval.start,
                          end: interval.end, calendars: nil)).sorted { $0.startDate < $1.startDate }
        status = "\(events.count) event\(events.count == 1 ? "" : "s") this month"
    }
}

@MainActor
struct CalendarToolView: View {
    @StateObject private var model = CalendarToolModel()
    @State private var month = Date()
    @State private var selected = Date()
    private let calendar = Calendar.current
    private var days: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let offset = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: offset) + range.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: interval.start)
        }.map(Optional.some)
    }
    private var selectedEvents: [EKEvent] {
        model.events.filter { event in
            guard let start = event.startDate, let end = event.endDate,
                  let interval = calendar.dateInterval(of: .day, for: selected) else { return false }
            return start < interval.end && end > interval.start
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }.help("Previous month")
                Text(month, format: .dateTime.month(.wide).year()).font(.headline)
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }.help("Next month")
                Spacer()
                Button("Today") { month = Date(); selected = Date(); model.refresh(month: month) }
                if model.connected { Button { model.refresh(month: month) } label: { Image(systemName: "arrow.clockwise") } }
            }
            if model.connected {
                HStack(alignment: .top, spacing: 18) {
                    VStack {
                        let weekdays = Array(calendar.veryShortStandaloneWeekdaySymbols.dropFirst(calendar.firstWeekday - 1))
                                     + Array(calendar.veryShortStandaloneWeekdaySymbols.prefix(calendar.firstWeekday - 1))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 5) {
                            ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                                if let date {
                                    Button { selected = date } label: {
                                        VStack(spacing: 2) {
                                            Text("\(calendar.component(.day, from: date))")
                                            Circle().fill(model.events.contains { calendar.isDate($0.startDate, inSameDayAs: date) } ? Color.blue : .clear)
                                                .frame(width: 4, height: 4)
                                        }.frame(maxWidth: .infinity).padding(4)
                                            .background(calendar.isDate(date, inSameDayAs: selected) ? Color.blue.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    }.buttonStyle(.plain)
                                        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                                } else { Color.clear.frame(height: 24) }
                            }
                        }
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selected, format: .dateTime.weekday(.wide).month().day()).font(.subheadline.weight(.semibold))
                        if selectedEvents.isEmpty { Text("No events for this day.").foregroundStyle(.secondary) }
                        ForEach(Array(selectedEvents.enumerated()), id: \.offset) { _, event in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.title ?? "Untitled event").font(.callout.weight(.medium))
                                if event.isAllDay { Text("All day").font(.caption).foregroundStyle(.secondary) }
                                else { Text(event.startDate, style: .time).font(.caption).foregroundStyle(.secondary) }
                                if let location = event.location, !location.isEmpty { Text(location).font(.caption).lineLimit(2) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(model.status).foregroundStyle(.secondary)
                Button("Connect Apple Calendar") { Task { await model.connect(month: month) } }.buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
            Text("Calendar data stays on this Mac. Access is requested only when you connect.").font(.caption).foregroundStyle(.secondary)
        }.padding(12).onAppear { model.refresh(month: month) }
    }
    private func moveMonth(_ count: Int) {
        if let next = calendar.date(byAdding: .month, value: count, to: month) {
            month = next; selected = next; model.refresh(month: month)
        }
    }
}

private final class ReminderTransfer: @unchecked Sendable {
    let items: [EKReminder]
    init(_ items: [EKReminder]) { self.items = items }
}

@MainActor
final class RemindersToolModel: ObservableObject {
    @Published private(set) var reminders: [EKReminder] = []
    @Published private(set) var status = "Connect Apple Reminders to view and complete reminders."
    @Published private(set) var connected = false
    @Published var showCompleted = false
    private let store = EKEventStore()
    private var generation = 0

    func connect() async {
        do {
            guard try await store.requestFullAccessToReminders() else {
                status = "Reminders access was denied. Enable it in System Settings → Privacy & Security → Reminders."
                return
            }
            connected = true
            await refresh()
        } catch { status = error.localizedDescription }
    }
    func refresh() async {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            connected = false; reminders = []; return
        }
        connected = true
        generation += 1
        let request = generation
        let predicate = store.predicateForReminders(in: nil)
        let transfer: ReminderTransfer = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { items in continuation.resume(returning: ReminderTransfer(items ?? [])) }
        }
        guard generation == request else { return }
        reminders = transfer.items.sorted { left, right in
            if left.isCompleted != right.isCompleted { return !left.isCompleted }
            return (left.title ?? "").localizedStandardCompare(right.title ?? "") == .orderedAscending
        }
        status = "\(reminders.filter { !$0.isCompleted }.count) incomplete reminders"
    }
    func setCompleted(_ reminder: EKReminder, to completed: Bool) {
        let previous = reminder.isCompleted
        reminder.isCompleted = completed
        do { try store.save(reminder, commit: true); Task { await refresh() } }
        catch { reminder.isCompleted = previous; status = error.localizedDescription }
    }
}

@MainActor
struct RemindersToolView: View {
    @StateObject private var model = RemindersToolModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apple Reminders").font(.headline)
                Spacer()
                if model.connected {
                    Toggle("Completed", isOn: $model.showCompleted).toggleStyle(.switch).controlSize(.small)
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            Text(model.status).font(.callout).foregroundStyle(.secondary)
            if model.connected {
                ForEach(model.reminders.filter { model.showCompleted || !$0.isCompleted }, id: \.calendarItemIdentifier) { item in
                    HStack(alignment: .top) {
                        Button { model.setCompleted(item, to: !item.isCompleted) } label: {
                            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.plain).accessibilityLabel(item.isCompleted ? "Mark incomplete" : "Complete reminder")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title ?? "Untitled reminder").strikethrough(item.isCompleted)
                            if let components = item.dueDateComponents, let date = Calendar.current.date(from: components) {
                                Text(date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(item.calendar.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } else {
                Button("Connect Apple Reminders") { Task { await model.connect() } }.buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
            Button("Open Reminders") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app")) }
        }.padding(12).task { await model.refresh() }
    }
}
