import SwiftUI
import Charts
import NotchCore

@MainActor
struct FocusStatsToolView: View {
    @ObservedObject private var service: FocusTimerService
    init(service: FocusTimerService = .shared) { _service = ObservedObject(wrappedValue: service) }
    @State private var weekDate = Date()
    private var days: [FocusDayTotal] { FocusHistory.week(containing: weekDate, records: service.timer.history) }
    private var totalMinutes: Int { Int(days.reduce(0) { $0 + $1.seconds } / 60) }
    private var sessions: Int { days.reduce(0) { $0 + $1.sessions } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LocalToolError(message: service.historyError)
            HStack {
                Button { move(-7) } label: { Image(systemName: "chevron.left") }.help("Previous week")
                if let first = days.first { Text("Week of \(first.date.formatted(date: .abbreviated, time: .omitted))").font(.headline) }
                Button { move(7) } label: { Image(systemName: "chevron.right") }.help("Next week")
                Spacer()
                Button("This Week") { weekDate = Date() }
            }
            HStack(spacing: 28) {
                Label("\(sessions) completed", systemImage: "checkmark.circle")
                Label("\(totalMinutes) focus minutes", systemImage: "timer")
            }.font(.callout)
            Chart(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Focus minutes", day.seconds / 60))
                    .foregroundStyle(.blue)
                    .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide)))
                    .accessibilityValue("\(day.sessions) completed sessions, \(Int(day.seconds / 60)) minutes")
            }.chartXScale(domain: (days.first?.date ?? weekDate)...(Calendar.current.date(byAdding: .day, value: 1, to: days.last?.date ?? weekDate) ?? weekDate))
                .chartYScale(domain: 0...max(30, Double(totalMinutes)))
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { value in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .frame(height: 145)
            if service.timer.history.isEmpty {
                Text("Complete a focus session in Timers to start a dated history. Cancelled sessions and breaks are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Recent completions").font(.caption.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(service.timer.history.suffix(8).reversed())) { completion in
                            HStack {
                                Text(completion.finishedAt, format: .dateTime.month().day().hour().minute())
                                Spacer(); Text("\(Int(completion.duration / 60)) min").monospacedDigit()
                            }.font(.caption)
                        }
                    }
                }.frame(height: 72)
            }
            let earlier = max(0, service.timer.completedSessions - service.timer.history.count)
            Text("Completed focus duration excludes pauses. A session is dated at its deadline, including after sleep. Up to 5,000 recent completions stay on this Mac.\(earlier > 0 ? " \(earlier) earlier sessions have no retained dated history." : "")")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(12)
    }
    private func move(_ days: Int) { if let date = Calendar.current.date(byAdding: .day, value: days, to: weekDate) { weekDate = date } }
}
