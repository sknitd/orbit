import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech
import NotchCore

@MainActor
struct DictationDriver {
    let supports: (String) -> Bool
    let start: (String, @escaping @Sendable (DictationEvent) -> Void) throws -> Void
    let finish: () -> Void
    let cancel: () -> Void
}

@MainActor
final class DictationNativeSession {
    private let audio = AVAudioEngine()
    private var recognition: SFSpeechRecognitionTask?
    private var bridge: DictationAudioBridge?
    private var hasTap = false
    static func supports(_ locale: String) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else { return false }
        return recognizer.supportsOnDeviceRecognition && recognizer.isAvailable
    }
    var driver: DictationDriver {
        .init(supports: Self.supports, start: { [self] locale, events in try start(locale: locale, events: events) },
              finish: { [self] in finish() }, cancel: { [self] in cancel() })
    }
    private func start(locale: String, events: @escaping @Sendable (DictationEvent) -> Void) throws {
        cancel()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw AssistantFileFailure.invalid("On-device speech recognition is unavailable for this language. No cloud fallback is used.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true; request.taskHint = .dictation
        let bridge = DictationAudioBridge(request: request, events: events)
        self.bridge = bridge
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cancel(); throw AssistantFileFailure.invalid("No working microphone is available.")
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [bridge] buffer, _ in bridge.append(buffer) }
        hasTap = true
        recognition = recognizer.recognitionTask(with: request) { result, error in
            if let result { events(.transcript(result.bestTranscription.formattedString, isFinal: result.isFinal)) }
            if let error { events(.failure(error.localizedDescription)) }
        }
        do { audio.prepare(); try audio.start() }
        catch { cancel(); throw error }
    }
    private func stopAudio() {
        bridge?.end()
        audio.stop()
        if hasTap { audio.inputNode.removeTap(onBus: 0); hasTap = false }
    }
    private func finish() { stopAudio(); recognition?.finish() }
    private func cancel() { stopAudio(); recognition?.cancel(); recognition = nil; bridge = nil }
}

private final class DictationAudioBridge: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let events: @Sendable (DictationEvent) -> Void
    private let lock = NSLock()
    private var active = true
    init(request: SFSpeechAudioBufferRecognitionRequest, events: @escaping @Sendable (DictationEvent) -> Void) {
        self.request = request; self.events = events
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard active else { lock.unlock(); return }
        request.append(buffer)
        lock.unlock()
        guard let channel = buffer.floatChannelData?.pointee else { return }
        let level = DictationText.rms(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        events(.level(level))
    }
    func end() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        active = false; request.endAudio()
    }
}
