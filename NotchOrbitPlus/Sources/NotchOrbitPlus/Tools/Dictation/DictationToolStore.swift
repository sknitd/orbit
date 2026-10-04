import AppKit
import Combine
import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech
import NotchCore

@MainActor
final class DictationToolStore: ObservableObject {
    static let shared = DictationToolStore()
    typealias Permission = @MainActor @Sendable () async -> Bool
    @Published var locale = "en-US"
    @Published var shortcut = DictationShortcut()
    @Published private(set) var shortcutEnabled = false
    @Published private(set) var backgroundMonitoring = false
    @Published private(set) var appendHoldToQuickNote = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isListening = false
    @Published private(set) var isFinishing = false
    @Published private(set) var transcript = ""
    @Published private(set) var amplitude = 0.0
    @Published private(set) var waveform: [Double] = []
    @Published private(set) var status = "Enable a hold shortcut or choose Start. Dictation stays on this Mac."
    @Published private(set) var error: String?
    var onAppendToQuickNote: (@MainActor (String) throws -> Void)?
    var onRequestShow: (@MainActor () -> Bool)?
    private let driver: DictationDriver
    private let speechPermission: Permission
    private let microphonePermission: Permission
    private let hotkey = DictationHoldShortcut()
    private var task: Task<Void, Never>?
    private var finalDeadline: Task<Void, Never>?
    private var generation = UUID()
    private var visible = false
    private var lastLevelTime = 0.0
    private var holdSession = false
    init(driver: DictationDriver? = nil, speechPermission: Permission? = nil, microphonePermission: Permission? = nil) {
        self.driver = driver ?? DictationNativeSession().driver
        self.speechPermission = speechPermission ?? {
            guard !Task.isCancelled else { return false }
            if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        }
        self.microphonePermission = microphonePermission ?? {
            guard !Task.isCancelled else { return false }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }
    func setVisible(_ value: Bool) {
        if !value && !backgroundMonitoring && (isPreparing || isListening || isFinishing) { cancel() }
        visible = value
    }
    func setBackgroundMonitoring(_ value: Bool) {
        backgroundMonitoring = value
        if !value && !visible { cancel() }
    }
    func setAppendHoldToQuickNote(_ value: Bool) { appendHoldToQuickNote = value }
    func setShortcutEnabled(_ value: Bool) {
        if !value { hotkey.stop(); shortcutEnabled = false; cancel(); return }
        shortcutEnabled = hotkey.configure(shortcut) { [weak self] pressed in
            self?.holdShortcutChanged(pressed)
        }
        if !shortcutEnabled { error = "This shortcut is unavailable. Choose another key or modifier combination." }
    }
    func holdShortcutChanged(_ pressed: Bool) {
        if pressed {
            if !visible && !backgroundMonitoring {
                guard let reveal = onRequestShow, reveal() else {
                    error = "Dictation could not be shown. Show it or explicitly allow background dictation first."
                    return
                }
            }
            start(fromHoldShortcut: true)
        } else { stop() }
    }
    func updateShortcut(_ value: DictationShortcut) {
        shortcut = value
        if shortcutEnabled { setShortcutEnabled(true) }
    }
    func start(fromHoldShortcut: Bool = false) {
        guard !isPreparing, !isListening, !isFinishing else { return }
        let token = UUID(); generation = token
        holdSession = fromHoldShortcut
        isPreparing = true; error = nil; transcript = ""; amplitude = 0; waveform = []
        let language = locale
        task = Task { @MainActor [weak self] in
            guard let store = self else { return }
            do {
                try store.check(token)
                guard store.driver.supports(language) else {
                    throw AssistantFileFailure.invalid("On-device dictation is unavailable for this language or Mac. No cloud recognizer is used.")
                }
                store.status = "Checking Speech permission…"
                guard await store.speechPermission() else { throw AssistantFileFailure.invalid("Allow Speech Recognition in Privacy & Security, then explicitly Start again.") }
                try store.check(token)
                store.status = "Checking Microphone permission…"
                guard await store.microphonePermission() else { throw AssistantFileFailure.invalid("Allow Microphone access in Privacy & Security, then explicitly Start again.") }
                try store.check(token)
                try store.driver.start(language) { [weak store] event in
                    Task { @MainActor [weak store] in store?.receive(event, token: token) }
                }
                try store.check(token)
                store.isPreparing = false; store.isListening = true; store.task = nil
                store.status = "Listening on-device. Release the hold key or choose Stop. No audio file is saved."
            } catch {
                guard store.generation == token else { return }
                store.driver.cancel(); store.isPreparing = false; store.isListening = false; store.task = nil; store.holdSession = false
                if error is CancellationError { store.status = "Dictation stopped." }
                else { store.error = error.localizedDescription; store.status = "Dictation could not start." }
            }
        }
    }
    func stop() {
        if isPreparing { cancel(); return }
        guard isListening else { return }
        isListening = false; isFinishing = true; amplitude = 0; waveform = []
        status = "Finishing the actual recognized transcript…"
        driver.finish()
        let token = generation
        finalDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.generation == token else { return }
            self.driver.cancel(); self.isFinishing = false; self.generation = UUID(); self.holdSession = false
            self.status = self.transcript.isEmpty ? "Stopped; no speech was recognized." : "Stopped; the recognized transcript is retained."
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; finalDeadline?.cancel(); finalDeadline = nil
        driver.cancel(); isPreparing = false; isListening = false; isFinishing = false
        holdSession = false
        amplitude = 0; waveform = []; status = "Dictation stopped; recognized text is retained."
    }
    func shutdown() { cancel(); hotkey.stop(); shortcutEnabled = false; visible = false }
    func copy(_ board: NSPasteboard = .general) { guard !transcript.isEmpty else { return }; board.clearContents(); board.setString(transcript, forType: .string) }
    func sendToQuickNote() {
        guard !isListening, !isPreparing, !isFinishing, !transcript.isEmpty else { return }
        guard let append = onAppendToQuickNote else { error = "Quick Note is not connected."; return }
        do { try append(transcript); error = nil; status = "Appended the recognized transcript to Quick Note." }
        catch { self.error = error.localizedDescription; status = "Quick Note was not updated; the transcript is retained." }
    }
    private func check(_ token: UUID) throws { try Task.checkCancellation(); guard generation == token else { throw CancellationError() } }
    private func receive(_ event: DictationEvent, token: UUID) {
        guard generation == token, isListening || isFinishing else { return }
        switch event {
        case .level(let measured):
            guard isListening, measured.isFinite else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastLevelTime >= 0.05 else { return }
            lastLevelTime = now; amplitude = min(1, max(0, measured)); waveform = DictationText.waveform(waveform, appending: amplitude)
        case .transcript(let words, let final):
            do { transcript = try DictationText.validated(words) }
            catch { cancel(); self.error = error.localizedDescription; return }
            if final {
                let shouldAppend = holdSession && isFinishing && appendHoldToQuickNote && !transcript.isEmpty
                driver.cancel(); isListening = false; isFinishing = false; amplitude = 0; waveform = []
                finalDeadline?.cancel(); finalDeadline = nil; generation = UUID()
                holdSession = false
                status = transcript.isEmpty ? "No speech was recognized." : "Recognized transcript ready. Copy it or send it to Quick Note."
                if shouldAppend { sendToQuickNote() }
            }
        case .failure(let message):
            let wasFinishing = isFinishing
            cancel()
            if wasFinishing && !transcript.isEmpty { status = "Stopped; the recognized transcript is retained." }
            else { error = message; status = "On-device recognition stopped." }
        }
    }
}
