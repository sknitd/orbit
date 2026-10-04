import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import NotchCore

@MainActor
final class FocusTimerService: ObservableObject {
    static let shared = FocusTimerService()
    @Published private(set) var timer: FocusTimer
    @Published private(set) var now = Date()
    @Published var focusMinutes: Double
    @Published var restMinutes: Double
    @Published var automaticBreak: Bool
    @Published var soundEnabled: Bool
    @Published var noiseEnabled = false { didSet { updateNoise() } }
    @Published private(set) var message = "Ready for a focus session."
    @Published private(set) var historyError: String?
    private var ticker: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private let defaults: UserDefaults
    private var unreadableTimerData: Data?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        focusMinutes = defaults.double(forKey: "focus.minutes").nonzeroOr(25)
        restMinutes = defaults.double(forKey: "focus.rest").nonzeroOr(5)
        automaticBreak = defaults.bool(forKey: "focus.automaticBreak")
        soundEnabled = defaults.object(forKey: "focus.sound") as? Bool ?? true
        timer = FocusTimer()
        if let data = defaults.data(forKey: "focus.timer") {
            do {
                guard data.count <= 4 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
                timer = try JSONDecoder().decode(FocusTimer.self, from: data)
            } catch {
                unreadableTimerData = data
                historyError = "Saved focus history could not be read. Its original is preserved; starting a new session creates a backup."
                message = historyError ?? "Could not restore the saved focus timer."
            }
        }
        if timer.isRunning { schedule() }
    }
    var remaining: TimeInterval { timer.remaining(at: now) }
    var remainingText: String {
        let seconds = Int(ceil(remaining))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var compactText: String? { timer.phase == .idle ? nil : remainingText }
    func start(rest: Bool = false) {
        let duration = rest ? restMinutes : focusMinutes
        guard duration.isFinite, duration > 0, duration <= 1_440 else {
            message = "Choose a positive duration up to 1,440 minutes."; return
        }
        if let unreadableTimerData {
            defaults.set(unreadableTimerData, forKey: "focus.timer.backup." + UUID().uuidString)
            self.unreadableTimerData = nil; historyError = nil
        }
        timer.start(minutes: rest ? restMinutes : focusMinutes, phase: rest ? .rest : .focus, at: Date())
        now = Date(); message = rest ? "Take a break." : "Focus time."
        persist(); schedule(); updateNoise()
    }
    func pauseResume() {
        now = Date()
        if timer.isPaused { timer.resume(at: now); schedule() }
        else { timer.pause(at: now); ticker?.cancel(); ticker = nil }
        persist(); updateNoise()
    }
    func stop() {
        timer.cancel(); ticker?.cancel(); ticker = nil
        player?.stop(); player = nil
        message = "Session cancelled."; persist()
    }
    func shutdown() { ticker?.cancel(); player?.stop(); persist() }
    func persist() {
        if unreadableTimerData == nil {
            do { defaults.set(try JSONEncoder().encode(timer), forKey: "focus.timer") }
            catch { historyError = "Could not save focus history: \(error.localizedDescription)" }
        }
        defaults.set(focusMinutes, forKey: "focus.minutes")
        defaults.set(restMinutes, forKey: "focus.rest")
        defaults.set(automaticBreak, forKey: "focus.automaticBreak")
        defaults.set(soundEnabled, forKey: "focus.sound")
    }
    func update(at date: Date) {
        now = date
        if let phase = timer.finishIfDue(at: now) {
            message = phase == .focus ? "Focus complete. Take a break." : "Break complete. Ready to focus."
            if soundEnabled { NSSound(named: "Glass")?.play() }
            if phase == .focus && automaticBreak { timer.start(minutes: restMinutes, phase: .rest, at: now) }
            persist(); updateNoise()
        }
    }
    private func schedule() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.update(at: Date())
                guard self.timer.isRunning else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private func updateNoise() {
        guard noiseEnabled, timer.isRunning, timer.phase == .focus else { player?.stop(); player = nil; return }
        guard player == nil else { return }
        do {
            let audio = try AVAudioPlayer(data: Self.noiseWAV())
            audio.numberOfLoops = -1; audio.volume = 0.2; audio.play(); player = audio
        } catch { message = "Focus sound: \(error.localizedDescription)"; noiseEnabled = false }
    }
    private static func noiseWAV() -> Data {
        let count = 44_100 * 3
        let size = UInt32(count * 2)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + size); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(44_100); u32(88_200); u16(2); u16(16); text("data"); u32(size)
        var seed: UInt32 = 3_709_757
        var smoothed = 0.0
        for _ in 0..<count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed) / Double(UInt32.max) * 2 - 1
            smoothed = 0.85 * smoothed + 0.15 * noise
            u16(UInt16(bitPattern: Int16(smoothed * 12_000)))
        }
        return data
    }
}

private extension Double {
    func nonzeroOr(_ fallback: Double) -> Double { isFinite && self > 0 && self <= 1_440 ? self : fallback }
}

@MainActor
struct TimersToolView: View {
    @ObservedObject private var service = FocusTimerService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(service.timer.phase == .rest ? "Break" : "Focus timer", systemImage: "timer").font(.headline)
                Spacer()
                Text("\(service.timer.completedSessions) sessions").font(.caption).foregroundStyle(.secondary)
            }
            Text(service.timer.phase == .idle ? String(format: "%02d:00", Int(service.focusMinutes)) : service.remainingText)
                .font(.system(size: 52, weight: .light, design: .rounded)).monospacedDigit().frame(maxWidth: .infinity)
            HStack {
                if service.timer.phase == .idle {
                    Button("Start focus") { service.start() }.buttonStyle(.borderedProminent)
                    Button("Start break") { service.start(rest: true) }
                } else {
                    Button(service.timer.isPaused ? "Resume" : "Pause", action: service.pauseResume).buttonStyle(.borderedProminent)
                    Button("Cancel", action: service.stop)
                }
            }.frame(maxWidth: .infinity)
            HStack {
                Stepper("Focus: \(Int(service.focusMinutes)) min", value: $service.focusMinutes, in: 1...180, step: 1)
                Stepper("Break: \(Int(service.restMinutes)) min", value: $service.restMinutes, in: 1...60, step: 1)
            }.disabled(service.timer.phase != .idle)
            Toggle("Start a break after focus", isOn: $service.automaticBreak)
            HStack {
                Toggle("Completion sound", isOn: $service.soundEnabled)
                Toggle("Soft focus noise", isOn: $service.noiseEnabled)
            }
            Text(service.message).font(.callout).foregroundStyle(.secondary)
            LocalToolError(message: service.historyError)
            Text("The countdown continues in the closed notch and stays accurate after sleep. Soft noise plays only during a running focus session.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12).onDisappear { service.persist() }
    }
}

@MainActor
struct TeleprompterToolView: View {
    @AppStorage("teleprompter.script") private var script = "Write your script here. Press Play to scroll it below the camera."
    @AppStorage("teleprompter.speed") private var speed = 26.0
    @AppStorage("teleprompter.font") private var fontSize = 28.0
    @State private var playing = false
    @State private var presenting = false
    @State private var offset = 0.0
    @State private var finished = false
    @State private var importError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Teleprompter", systemImage: "text.aligncenter").font(.headline)
                Spacer()
                Button("Import text…", action: importText)
                Button(presenting ? "Edit" : "Read") { playing = false; presenting.toggle(); offset = 0; finished = false }
                Button(playing ? "Pause" : "Play") { presenting = true; finished = false; playing.toggle() }.buttonStyle(.borderedProminent)
                Button { playing = false; offset = 0; finished = false } label: { Image(systemName: "backward.end") }.help("Restart script")
            }
            if presenting {
                PrompterText(script: script, fontSize: fontSize, offset: offset, finished: $finished)
                    .frame(minHeight: 140, maxHeight: .infinity)
                    .overlay(alignment: .top) { Rectangle().fill(.blue.opacity(0.4)).frame(height: 1).padding(.top, 38) }
            } else {
                TextEditor(text: $script).font(.system(size: 16)).frame(minHeight: 140)
                    .onChange(of: script) { _, value in if value.count > 200_000 { script = String(value.prefix(200_000)) } }
            }
            HStack {
                Text("Speed").font(.caption); Slider(value: $speed, in: 5...90).frame(maxWidth: 180)
                Text("Text").font(.caption); Slider(value: $fontSize, in: 18...50).frame(maxWidth: 140)
            }
            if let importError { Text(importError).foregroundStyle(.orange).font(.caption) }
            Text(finished ? "End of script. Restart to read again." : "Keep the notch open or pinned while reading. Your script saves automatically on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12).task(id: playing) {
            guard playing else { return }
            while !Task.isCancelled && playing && !finished {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                offset += speed * 0.05
            }
            if finished { playing = false }
        }.onDisappear { playing = false }
    }
    private func importText() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_000_000 else {
                importError = "Choose a text file smaller than 1 MB."; return
            }
            script = String(try String(contentsOf: url, encoding: .utf8).prefix(200_000))
            offset = 0; finished = false; importError = nil
        } catch { importError = error.localizedDescription }
    }
}

@MainActor
private struct PrompterText: NSViewRepresentable {
    let script: String
    let fontSize: Double
    let offset: Double
    @Binding var finished: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.textColor = .white; text.alignment = .center
        text.textContainerInset = NSSize(width: 16, height: 38)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        if text.string != script { text.string = script }
        text.font = .systemFont(ofSize: fontSize, weight: .medium)
        text.setFrameSize(NSSize(width: max(100, scroll.contentSize.width), height: max(200, text.frame.height)))
        text.textContainer?.containerSize = NSSize(width: max(60, scroll.contentSize.width - 32), height: .greatestFiniteMagnitude)
        guard let container = text.textContainer else { return }
        text.layoutManager?.ensureLayout(for: container)
        let height = (text.layoutManager?.usedRect(for: container).height ?? 0) + 150
        text.setFrameSize(NSSize(width: max(100, scroll.contentSize.width), height: max(scroll.contentSize.height, height)))
        let maximum = max(0, text.frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset, maximum)))
        scroll.reflectScrolledClipView(scroll.contentView)
        if maximum > 0, offset >= maximum, !finished {
            DispatchQueue.main.async { finished = true }
        }
    }
}
