import AppKit
import SwiftUI
import NotchCore

@MainActor
enum PlusLiveStatus {
    static func statuses(model: AppModel, at date: Date) -> [LiveNotchStatus] {
        var values: [LiveNotchStatus] = []
        let workflows = WorkflowStore.shared
        if workflows.isRunning {
            values.append(.init(id: "workflow", kind: .processing, title: workflows.selectedPreset?.name ?? "Workflow",
                detail: workflows.status, toolID: "workflows", progress: workflows.progress))
        }
        if model.busy {
            values.append(.init(id: "file-action", kind: .processing,
                title: model.progressLabel.isEmpty ? "Processing files" : model.progressLabel,
                detail: "File action", toolID: "fileActions", progress: model.progress))
        }
        let meetings = PlusMeetingService.shared
        if meetings.liveEnabled, let meeting = meetings.upcoming(at: date).first,
           meeting.start.timeIntervalSince(date) <= 15 * 60 {
            values.append(.init(id: "meeting", kind: .meeting, title: meeting.title,
                detail: meeting.countdown(at: date), toolID: "calendar"))
        }
        let focus = FocusTimerService.shared
        if let countdown = focus.compactText {
            values.append(.init(id: "focus", kind: .focus, title: countdown,
                detail: focus.timer.isPaused ? "Paused" : focus.timer.phase == .rest ? "Break" : "Focus", toolID: "timers"))
        }
        let music = PlusNowPlayingStore.shared
        if music.backgroundMonitoring, music.connected, let track = music.snapshot, !track.title.isEmpty {
            values.append(.init(id: "music", kind: .music, title: track.title,
                detail: track.playing ? track.artist : "Paused · \(track.artist)", toolID: "nowPlaying"))
        }
        return LiveNotchSelection.ordered(values)
    }
}

@MainActor
struct PlusCompactView: View {
    let model: AppModel
    @ObservedObject private var timer = FocusTimerService.shared
    @ObservedObject private var meetings = PlusMeetingService.shared
    @ObservedObject private var music = PlusNowPlayingStore.shared
    @ObservedObject private var workflows = WorkflowStore.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            LiveCompactContent(statuses: PlusLiveStatus.statuses(model: model, at: context.date), musicArtwork: music.artwork)
        }
    }
}

@MainActor
struct LiveCompactContent: View {
    let statuses: [LiveNotchStatus]
    var musicArtwork: NSImage? = nil
    private var ordered: [LiveNotchStatus] { LiveNotchSelection.ordered(statuses) }
    var body: some View {
        HStack(spacing: 7) {
            if let primary = ordered.first {
                if primary.kind == .music, let musicArtwork {
                    Image(nsImage: musicArtwork).resizable().scaledToFill().frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityHidden(true)
                } else if primary.kind == .processing, let progress = primary.progress {
                    ZStack {
                        Circle().stroke(.white.opacity(0.18), lineWidth: 2)
                        Circle().trim(from: 0, to: progress).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }.frame(width: 18, height: 18).accessibilityHidden(true)
                } else { Image(systemName: primary.kind.symbol).foregroundStyle(.secondary).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(primary.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if !primary.detail.isEmpty { Text(primary.detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if primary.kind == .processing, let progress = primary.progress {
                    Text("\(Int(progress * 100))%").font(.system(size: 10)).monospacedDigit()
                }
                ForEach(Array(ordered.dropFirst().prefix(2))) { activity in
                    Image(systemName: activity.kind.symbol).font(.system(size: 9)).foregroundStyle(.secondary)
                        .help("\(activity.title) · \(activity.detail)").accessibilityLabel("\(activity.title) \(activity.detail)")
                }
            } else {
                Image(systemName: "rectangle.topthird.inset.filled")
                Text("NotchOrbitPlus").font(.system(size: 11, weight: .medium))
            }
        }.help(ordered.map { "\($0.title) \($0.detail)" }.joined(separator: "\n"))
            .accessibilityElement(children: .combine)
    }
}
