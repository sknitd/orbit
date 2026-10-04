import AppKit
import SwiftUI
import NotchCore

@MainActor
enum PlusLiveStatus {
    static func statuses(model: AppModel, at date: Date, preferences: DashboardPreferences? = nil) -> [LiveNotchStatus] {
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
                detail: focus.timer.isPaused ? "Paused" : focus.timer.phase == .rest ? "Break" : FocusAppHidingStore.shared.hiddenCount > 0 ? "Focus · \(FocusAppHidingStore.shared.hiddenCount) apps hidden" : "Focus", toolID: "timers"))
        }
        let music = PlusNowPlayingStore.shared
        if music.backgroundMonitoring, music.connected, let track = music.snapshot, !track.title.isEmpty {
            values.append(.init(id: "music", kind: .music, title: track.title,
                detail: track.playing || !track.playbackStateKnown ? track.artist : "Paused · \(track.artist)", toolID: "nowPlaying"))
        }
        let controls = SystemControlsService.shared
        if controls.enabled, let hud = controls.hud {
            values.append(.init(id: "hud", kind: .hud, title: hud.label,
                detail: "\(hud.percent)%", toolID: "hud", progress: hud.level))
        }
        let devices = DevicesService.shared
        if devices.backgroundMonitoring, devices.updatedAt != nil,
           let device = (devices.devices + devices.bluetoothDevices).filter({ $0.connected != false && $0.batteryPercent != nil })
               .min(by: { ($0.batteryPercent ?? 100) < ($1.batteryPercent ?? 100) }),
           let battery = device.batteryPercent {
            values.append(.init(id: "devices", kind: .devices, title: device.name,
                detail: "Battery \(Int(battery.rounded()))%", toolID: "devices"))
        }
        let status = StatusService.shared
        if status.backgroundMonitoring, let snapshot = status.snapshot {
            if snapshot.focusIsActive == true {
                values.append(.init(id: "focus-status", kind: .status, title: "Focus active",
                    detail: "Shared Focus status", toolID: "status"))
            }
            if snapshot.inputDeviceIsRunning == true {
                values.append(.init(id: "audio-input", kind: .status, title: "Audio input active",
                    detail: snapshot.inputDeviceName ?? "Input device", toolID: "status"))
            }
            if snapshot.cameraInUseByAnotherApplication == true {
                values.append(.init(id: "camera-in-use", kind: .status, title: "Camera active",
                    detail: "Another application", toolID: "status"))
            }
        }
        values.append(contentsOf: DownloadsService.shared.liveStatuses)
        values.append(contentsOf: CommandsService.shared.liveStatuses)
        let dictation = DictationToolStore.shared
        if dictation.isListening {
            values.append(.init(id: "dictation", kind: .dictation, title: "Dictating to Quick Note",
                detail: "On-device microphone capture", toolID: PlusTool.dictation.rawValue, waveform: dictation.waveform))
        }
        if let code = VerificationCodesStore.shared.liveStatus, code.isVisible(at: date) {
            values.append(.init(id: "verification:\(code.id)", kind: .verificationCode, title: code.code,
                detail: "One-time code · \(max(0, Int(ceil(code.expiresAt.timeIntervalSince(date)))))s", toolID: PlusTool.verificationCodes.rawValue, action: .copyVerificationCode))
        }
        values.append(contentsOf: [PackageTrackerService.shared.liveStatus, TravelStatusService.shared.liveStatus,
            SportsScoresService.shared.liveStatus, OnlineWeatherModel.shared.liveStatus].compactMap { $0 })
        let visible = values.filter { preferences?.hiddenToolIDs.contains($0.toolID) != true }
        return LiveNotchSelection.ordered(visible, priorityOrder: PlusLivePriorityStore.shared.priorityOrder)
    }
}

@MainActor
struct PlusCompactView: View {
    let model: AppModel
    var openDashboard: (@MainActor () -> Void)? = nil
    @ObservedObject var preferences: DashboardPreferences
    @ObservedObject private var timer = FocusTimerService.shared
    @ObservedObject private var meetings = PlusMeetingService.shared
    @ObservedObject private var music = PlusNowPlayingStore.shared
    @ObservedObject private var workflows = WorkflowStore.shared
    @ObservedObject private var controls = SystemControlsService.shared
    @ObservedObject private var devices = DevicesService.shared
    @ObservedObject private var priorities = PlusLivePriorityStore.shared
    @ObservedObject private var status = StatusService.shared
    @ObservedObject private var downloads = DownloadsService.shared
    @ObservedObject private var commands = CommandsService.shared
    @ObservedObject private var dictation = DictationToolStore.shared
    @ObservedObject private var codes = VerificationCodesStore.shared
    @ObservedObject private var package = PackageTrackerService.shared
    @ObservedObject private var travel = TravelStatusService.shared
    @ObservedObject private var sports = SportsScoresService.shared
    @ObservedObject private var weather = OnlineWeatherModel.shared
    @ObservedObject private var focusApps = FocusAppHidingStore.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            LiveCompactContent(statuses: PlusLiveStatus.statuses(model: model, at: context.date, preferences: preferences),
                musicArtwork: music.artwork, priorityOrder: priorities.priorityOrder, hudSnapshot: controls.hud,
                openDashboard: openDashboard, onActivityAction: { status in
                    switch status.action {
                    case .copyVerificationCode:
                        if let code = codes.codes.first(where: { "verification:\($0.id)" == status.id }) { codes.copy(code) }
                    case .revealFile: downloads.reveal(statusID: status.id)
                    case nil: break
                    }
                })
        }
    }
}

@MainActor
struct LiveCompactContent: View {
    let statuses: [LiveNotchStatus]
    var musicArtwork: NSImage? = nil
    var priorityOrder: [LiveNotchKind] = LiveNotchKind.defaultOrder
    var hudSnapshot: SystemHUDSnapshot? = nil
    var openDashboard: (@MainActor () -> Void)? = nil
    var onActivityAction: (@MainActor (LiveNotchStatus) -> Void)? = nil
    private var ordered: [LiveNotchStatus] { LiveNotchSelection.ordered(statuses, priorityOrder: priorityOrder) }
    var body: some View {
        HStack(spacing: 7) {
            if let primary = ordered.first {
                if let openDashboard {
                    Button(action: openDashboard) { primaryLabel(primary) }.buttonStyle(.plain)
                        .accessibilityLabel("Open \(primary.title): \(primary.detail)")
                } else { primaryLabel(primary) }
                if let action = primary.action, let onActivityAction {
                    CompactActivityActionButton(status: primary, action: action, perform: onActivityAction)
                        .frame(width: 24, height: 24)
                }
                ForEach(Array(ordered.dropFirst().prefix(2))) { activity in
                    Image(systemName: activity.kind.symbol).font(.system(size: 9)).foregroundStyle(.secondary)
                        .help("\(activity.title) · \(activity.detail)").accessibilityLabel("\(activity.title) \(activity.detail)")
                }
            } else if let openDashboard {
                Button(action: openDashboard) { idleLabel }.buttonStyle(.plain).accessibilityLabel("Open NotchOrbitPlus dashboard")
            } else { idleLabel }
        }.help(ordered.map { "\($0.title) \($0.detail)" }.joined(separator: "\n"))
            .accessibilityElement(children: .contain)
    }
    private var idleLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: "rectangle.topthird.inset.filled")
            Text("NotchOrbitPlus").font(.system(size: 11, weight: .medium))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func primaryLabel(_ primary: LiveNotchStatus) -> some View {
        HStack(spacing: 7) {
            if primary.kind == .hud, let hudSnapshot {
                Image(systemName: hudSnapshot.symbol).accessibilityHidden(true)
            } else if primary.kind == .music, let musicArtwork {
                Image(nsImage: musicArtwork).resizable().scaledToFill().frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityHidden(true)
            } else if [.processing, .downloads].contains(primary.kind), let progress = primary.progress {
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
            if [.processing, .downloads].contains(primary.kind), let progress = primary.progress {
                Text("\(Int(progress * 100))%").font(.system(size: 10)).monospacedDigit()
            }
            if primary.kind == .dictation, !primary.waveform.isEmpty {
                HStack(alignment: .center, spacing: 1) {
                    ForEach(Array(primary.waveform.suffix(16).enumerated()), id: \.offset) { sample in
                        Capsule().fill(Color.accentColor).frame(width: 2, height: max(0.5, sample.element * 20))
                    }
                }.frame(height: 20).accessibilityLabel("Live microphone waveform")
            }
            if primary.kind == .hud, let progress = primary.progress {
                ProgressView(value: progress).frame(width: 42).accessibilityLabel(primary.title)
                    .accessibilityValue("\(Int(progress * 100)) percent")
            }
        }.contentShape(Rectangle())
    }
}

/// A real AppKit control keeps the small icon action independently discoverable
/// and pressable by accessibility clients inside the hosted compact content.
@MainActor
private struct CompactActivityActionButton: NSViewRepresentable {
    let status: LiveNotchStatus
    let action: LiveNotchAction
    let perform: @MainActor (LiveNotchStatus) -> Void
    private var label: String { action == .copyVerificationCode ? "Copy one-time code" : "Reveal completed download" }
    private var identifier: String { action == .copyVerificationCode ? "NotchOrbitPlus.compact.copyVerificationCode" : "NotchOrbitPlus.compact.revealFile" }

    func makeCoordinator() -> Coordinator { Coordinator(status: status, perform: perform) }
    func makeNSView(context: Context) -> NSButton {
        let button = CompactActivityNativeButton(title: "", target: context.coordinator, action: #selector(Coordinator.press(_:)))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.setContentHuggingPriority(.required, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.status = status
        context.coordinator.perform = perform
        let image = NSImage(systemSymbolName: action == .copyVerificationCode ? "doc.on.doc" : "folder", accessibilityDescription: label)
        image?.isTemplate = true
        image?.size = NSSize(width: 14, height: 14)
        button.image = image
        button.toolTip = label
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
        button.setAccessibilityElement(true)
    }
    @MainActor
    final class Coordinator: NSObject {
        var status: LiveNotchStatus
        var perform: @MainActor (LiveNotchStatus) -> Void
        init(status: LiveNotchStatus, perform: @escaping @MainActor (LiveNotchStatus) -> Void) {
            self.status = status; self.perform = perform
        }
        @objc func press(_ sender: NSButton) { perform(status) }
    }
}

/// Hosted icon actions expose a button role and use the same target/action route
/// for accessibility presses and ordinary mouse clicks.
@MainActor
private final class CompactActivityNativeButton: NSButton {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        return NSApp.sendAction(action, to: target, from: self)
    }
}
