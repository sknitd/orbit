import AppKit
import SwiftUI
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class DictationEvaluationTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testConstructionLifecycleAndImmediatelyHiddenStartNeverRequestPermissions() async throws {
        let fixture = DictationFixture()
        let store = DictationToolStore(driver: fixture.driver, speechPermission: {
            fixture.speech += 1; return true
        }, microphonePermission: { fixture.microphone += 1; return true })
        store.setVisible(true); store.setVisible(false); store.shutdown()
        XCTAssertFalse(store.shortcutEnabled); XCTAssertFalse(store.backgroundMonitoring)
        XCTAssertEqual(fixture.speech, 0); XCTAssertEqual(fixture.microphone, 0); XCTAssertEqual(fixture.started, 0)
        store.setVisible(true); store.start(); store.setVisible(false)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fixture.supportChecks, 0); XCTAssertEqual(fixture.speech, 0); XCTAssertEqual(fixture.microphone, 0)
        XCTAssertEqual(fixture.started, 0); XCTAssertFalse(store.isPreparing); XCTAssertFalse(store.isListening)
        XCTAssertTrue(store.transcript.isEmpty)
    }

    @MainActor
    func testActualDriverEventsAndHiddenCancellationPreserveTranscriptAndReportQuickNoteFailure() async throws {
        let fixture = DictationFixture()
        let store = DictationToolStore(driver: fixture.driver,
            speechPermission: { fixture.speech += 1; return true },
            microphonePermission: { fixture.microphone += 1; return true })
        store.setVisible(true); store.start()
        try await NativeFeatureEvaluation.waitUntil("Injected dictation driver starts") { store.isListening }
        XCTAssertEqual(fixture.speech, 1); XCTAssertEqual(fixture.microphone, 1); XCTAssertEqual(fixture.started, 1)
        let events = try XCTUnwrap(fixture.events)
        events(.transcript("Actual recognized fixture words", isFinal: false)); events(.level(0.25))
        try await NativeFeatureEvaluation.waitUntil("Actual driver text and level published") {
            store.transcript == "Actual recognized fixture words" && store.amplitude == 0.25
        }
        XCTAssertEqual(store.waveform, [0.25])
        store.setVisible(false)
        events(.transcript("Stale replacement", isFinal: true)); events(.level(0.9))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(store.isListening); XCTAssertEqual(store.amplitude, 0); XCTAssertTrue(store.waveform.isEmpty)
        XCTAssertEqual(store.transcript, "Actual recognized fixture words")
        store.onAppendToQuickNote = { _ in throw CocoaError(.fileWriteNoPermission) }
        store.sendToQuickNote()
        XCTAssertNotNil(store.error); XCTAssertEqual(store.status, "Quick Note was not updated; the transcript is retained.")
        store.onAppendToQuickNote = { fixture.appended = $0 }
        store.sendToQuickNote()
        XCTAssertEqual(fixture.appended, "Actual recognized fixture words"); XCTAssertNil(store.error)
        store.shutdown()
    }

    @MainActor
    func testCancelledSpeechConsentCannotProceedToMicrophoneOrAudioStart() async throws {
        let fixture = DictationFixture()
        let store = DictationToolStore(driver: fixture.driver, speechPermission: {
            fixture.speech += 1
            return await withCheckedContinuation { fixture.speechContinuation = $0 }
        }, microphonePermission: { fixture.microphone += 1; return true })
        store.start()
        try await NativeFeatureEvaluation.waitUntil("Speech consent fixture pending") { fixture.speechContinuation != nil }
        store.cancel()
        fixture.speechContinuation?.resume(returning: true); fixture.speechContinuation = nil
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fixture.speech, 1); XCTAssertEqual(fixture.microphone, 0); XCTAssertEqual(fixture.started, 0)
        XCTAssertFalse(store.isPreparing); XCTAssertFalse(store.isListening)
        XCTAssertTrue(store.transcript.isEmpty); XCTAssertNil(store.error)
        store.shutdown()
    }

    @MainActor
    func testUnsupportedOnDeviceRecognizerFailsBeforeConsentAndExplicitBackgroundOptInControlsHide() async throws {
        let fixture = DictationFixture(); fixture.supported = false
        let store = DictationToolStore(driver: fixture.driver,
            speechPermission: { fixture.speech += 1; return true },
            microphonePermission: { fixture.microphone += 1; return true })
        store.start()
        try await NativeFeatureEvaluation.waitUntil("Unsupported recognizer error") { store.error != nil }
        XCTAssertEqual(fixture.speech, 0); XCTAssertEqual(fixture.microphone, 0); XCTAssertEqual(fixture.started, 0)
        fixture.supported = true; store.setVisible(true); store.setBackgroundMonitoring(true); store.start()
        try await NativeFeatureEvaluation.waitUntil("Explicit background dictation started") { store.isListening }
        store.setVisible(false); XCTAssertTrue(store.isListening)
        store.setBackgroundMonitoring(false); XCTAssertFalse(store.isListening)
        store.shutdown()
    }

    @MainActor
    func testDictationControlsAndMeasuredLevelFixtureRenderWithoutRealSpeechOrMicrophone() async throws {
        let fixture = DictationFixture()
        let store = DictationToolStore(driver: fixture.driver, speechPermission: { true }, microphonePermission: { true })
        try await NativeFeatureEvaluation.render(AnyView(DictationToolView(store: store)),
                                                named: "NotchOrbitPlus-Dictation-fixture-unstarted.png")
        XCTAssertEqual(fixture.started, 0); XCTAssertFalse(store.shortcutEnabled)
        store.setVisible(true); store.start()
        try await NativeFeatureEvaluation.waitUntil("Injected listening fixture") { store.isListening }
        let events = try XCTUnwrap(fixture.events)
        events(.transcript("Recognized fixture text ready for Quick Note.", isFinal: false))
        for value in [0.02, 0.15, 0.35, 0.22, 0.08, 0.4, 0.31] {
            events(.level(value)); try await Task.sleep(for: .milliseconds(60))
        }
        try await NativeFeatureEvaluation.render(AnyView(DictationToolView(store: store)),
                                                named: "NotchOrbitPlus-Dictation-fixture-recognized-levels.png")
        XCTAssertEqual(fixture.started, 1)
        store.shutdown()
    }
}

@MainActor
private final class DictationFixture {
    var supported = true
    var supportChecks = 0
    var speech = 0
    var microphone = 0
    var started = 0
    var cancelled = 0
    var finished = 0
    var appended: String?
    var events: (@Sendable (DictationEvent) -> Void)?
    var speechContinuation: CheckedContinuation<Bool, Never>?
    var driver: DictationDriver {
        .init(supports: { [self] _ in supportChecks += 1; return supported },
              start: { [self] _, callback in started += 1; events = callback },
              finish: { [self] in finished += 1 }, cancel: { [self] in cancelled += 1 })
    }
}
