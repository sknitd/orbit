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
        XCTAssertFalse(store.appendHoldToQuickNote)
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
    func testFailedHoldRevealAndRepeatedHiddenStateCannotStartPermissionOrPublishText() async throws {
        let fixture = DictationFixture()
        let store = DictationToolStore(driver: fixture.driver,
            speechPermission: { fixture.speech += 1; return true },
            microphonePermission: { fixture.microphone += 1; return true })
        var reveals = 0
        store.onRequestShow = { reveals += 1; return false }
        store.holdShortcutChanged(true)
        XCTAssertEqual(reveals, 1); XCTAssertNotNil(store.error)
        XCTAssertFalse(store.isPreparing); XCTAssertFalse(store.isListening)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fixture.supportChecks, 0); XCTAssertEqual(fixture.speech, 0)
        XCTAssertEqual(fixture.microphone, 0); XCTAssertEqual(fixture.started, 0)
        // A repeated hidden notification must also invalidate work started
        // before the native visibility observer has reported its first show.
        store.start(); store.setVisible(false)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fixture.supportChecks, 0); XCTAssertEqual(fixture.speech, 0)
        XCTAssertEqual(fixture.microphone, 0); XCTAssertEqual(fixture.started, 0)
        XCTAssertFalse(store.isPreparing); XCTAssertTrue(store.transcript.isEmpty)
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
    func testOptedInHoldReleaseAppendsOnlyOneFinalTranscriptAndManualStartStillRequiresSend() async throws {
        let fixture = DictationFixture()
        let store = DictationToolStore(driver: fixture.driver, speechPermission: { true }, microphonePermission: { true })
        store.onAppendToQuickNote = { fixture.appendCount += 1; fixture.appended = $0 }
        store.setVisible(true); store.setAppendHoldToQuickNote(true); store.start(fromHoldShortcut: true)
        try await NativeFeatureEvaluation.waitUntil("Hold dictation is listening") { store.isListening }
        let events = try XCTUnwrap(fixture.events)
        events(.transcript("Partial hold words", isFinal: false))
        try await NativeFeatureEvaluation.waitUntil("Partial hold transcript retained") { store.transcript == "Partial hold words" }
        XCTAssertEqual(fixture.appendCount, 0)
        store.stop(); XCTAssertEqual(fixture.finished, 1)
        events(.transcript("Final hold words", isFinal: true))
        events(.transcript("Duplicate final event", isFinal: true))
        try await NativeFeatureEvaluation.waitUntil("Final hold transcript appended") { fixture.appendCount == 1 }
        XCTAssertEqual(fixture.appended, "Final hold words"); XCTAssertEqual(store.transcript, "Final hold words")
        XCTAssertFalse(store.isFinishing); XCTAssertNil(store.error)
        store.start()
        try await NativeFeatureEvaluation.waitUntil("Manual Start is listening") { store.isListening }
        let manualEvents = try XCTUnwrap(fixture.events)
        store.stop(); manualEvents(.transcript("Manual preview words", isFinal: true))
        try await NativeFeatureEvaluation.waitUntil("Manual transcript is ready") { !store.isFinishing }
        XCTAssertEqual(fixture.appendCount, 1)
        store.sendToQuickNote()
        XCTAssertEqual(fixture.appendCount, 2); XCTAssertEqual(fixture.appended, "Manual preview words")
        store.shutdown()
    }

    @MainActor
    func testHoldAppendFailureRetainsFinalTextAndCanceledOrFailedRecognitionNeverAppends() async throws {
        let fixture = DictationFixture()
        let store = DictationToolStore(driver: fixture.driver, speechPermission: { true }, microphonePermission: { true })
        store.setVisible(true); store.setAppendHoldToQuickNote(true)
        store.onAppendToQuickNote = { _ in fixture.appendCount += 1; throw CocoaError(.fileWriteNoPermission) }
        store.start(fromHoldShortcut: true)
        try await NativeFeatureEvaluation.waitUntil("Hold recording before save failure") { store.isListening }
        let failedSaveEvents = try XCTUnwrap(fixture.events)
        store.stop(); failedSaveEvents(.transcript("Final text remains after save failure", isFinal: true))
        try await NativeFeatureEvaluation.waitUntil("Actual append error reported") { store.error != nil }
        XCTAssertEqual(fixture.appendCount, 1)
        XCTAssertEqual(store.transcript, "Final text remains after save failure")
        XCTAssertEqual(store.status, "Quick Note was not updated; the transcript is retained.")
        store.onAppendToQuickNote = { fixture.appendCount += 1; fixture.appended = $0 }
        store.start(fromHoldShortcut: true)
        try await NativeFeatureEvaluation.waitUntil("Hold recording before recognition failure") { store.isListening }
        let partialEvents = try XCTUnwrap(fixture.events)
        partialEvents(.transcript("Actual partial words", isFinal: false))
        try await NativeFeatureEvaluation.waitUntil("Partial transcript present") { store.transcript == "Actual partial words" }
        store.stop(); partialEvents(.failure("Recognition fixture ended without a final result"))
        try await NativeFeatureEvaluation.waitUntil("Failed finishing preserves partial") { !store.isFinishing }
        XCTAssertEqual(fixture.appendCount, 1); XCTAssertEqual(store.transcript, "Actual partial words")
        store.start(fromHoldShortcut: true)
        try await NativeFeatureEvaluation.waitUntil("Hold recording before cancellation") { store.isListening }
        let canceledEvents = try XCTUnwrap(fixture.events)
        store.cancel(); canceledEvents(.transcript("Late canceled result", isFinal: true))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fixture.appendCount, 1); XCTAssertTrue(store.transcript.isEmpty)
        store.shutdown()
    }

    @MainActor
    func testDictationControlsAndMeasuredLevelFixtureRenderWithoutRealSpeechOrMicrophone() async throws {
        let unstartedFixture = DictationFixture()
        let unstartedStore = DictationToolStore(driver: unstartedFixture.driver, speechPermission: { true }, microphonePermission: { true })
        try await NativeFeatureEvaluation.render(AnyView(DictationToolView(store: unstartedStore)),
                                                named: "NotchOrbitPlus-Dictation-fixture-unstarted.png")
        XCTAssertEqual(unstartedFixture.started, 0); XCTAssertFalse(unstartedStore.shortcutEnabled)
        unstartedStore.shutdown()
        // Closing the first hosted window intentionally sends a deferred
        // hidden callback. A new store prevents that old host from stopping
        // this separate live fixture before its capture.
        let fixture = DictationFixture()
        let store = DictationToolStore(driver: fixture.driver, speechPermission: { true }, microphonePermission: { true })
        defer { store.shutdown() }
        store.setVisible(true); store.start()
        try await NativeFeatureEvaluation.waitUntil("Injected listening fixture") { store.isListening }
        let events = try XCTUnwrap(fixture.events)
        events(.transcript("Recognized fixture text ready for Quick Note.", isFinal: false))
        for value in [0.02, 0.15, 0.35, 0.22, 0.08, 0.4, 0.31] {
            events(.level(value)); try await Task.sleep(for: .milliseconds(60))
        }
        try await NativeFeatureEvaluation.render(AnyView(DictationToolView(store: store)),
            named: "NotchOrbitPlus-Dictation-fixture-recognized-levels.png", size: NSSize(width: 560, height: 560),
            beforeCapture: {
                XCTAssertTrue(store.isListening)
                XCTAssertEqual(store.transcript, "Recognized fixture text ready for Quick Note.")
                XCTAssertEqual(store.waveform, [0.02, 0.15, 0.35, 0.22, 0.08, 0.4, 0.31])
                XCTAssertEqual(store.amplitude, 0.31)
                XCTAssertEqual(fixture.cancelled, 0)
            })
        XCTAssertEqual(fixture.started, 1)
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
    var appendCount = 0
    var events: (@Sendable (DictationEvent) -> Void)?
    var speechContinuation: CheckedContinuation<Bool, Never>?
    var driver: DictationDriver {
        .init(supports: { [self] _ in supportChecks += 1; return supported },
              start: { [self] _, callback in started += 1; events = callback },
              finish: { [self] in finished += 1 }, cancel: { [self] in cancelled += 1 })
    }
}
