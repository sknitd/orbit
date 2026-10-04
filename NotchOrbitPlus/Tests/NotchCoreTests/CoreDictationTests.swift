import XCTest
@testable import NotchCore

final class CoreDictationTests: XCTestCase {
    func testMeasuredRMSAndWaveformKeepRealLevelsAndBoundMemory() {
        XCTAssertEqual(DictationText.rms([Float](repeating: 0.5, count: 8)), 0.5, accuracy: 0.000001)
        XCTAssertEqual(DictationText.rms([Float.nan, Float.infinity]), 0)
        XCTAssertEqual(DictationText.rms([Float(0), Float(1)]), sqrt(0.5), accuracy: 0.000001)
        var values: [Double] = []
        for index in 0..<50 { values = DictationText.waveform(values, appending: Double(index) / 50) }
        XCTAssertEqual(values.count, 32); XCTAssertEqual(values.last, 0.98)
        XCTAssertEqual(DictationText.waveform(values, appending: .nan), values)
    }
    func testTranscriptAndShortcutValidationPreserveRecognizedWords() throws {
        XCTAssertEqual(try DictationText.validated("Recognized words\nnext line"), "Recognized words\nnext line")
        XCTAssertThrowsError(try DictationText.validated(String(repeating: "x", count: 100_001)))
        let shortcut = DictationShortcut()
        XCTAssertEqual(shortcut.title, "Control–Option–D")
        XCTAssertEqual(try JSONDecoder().decode(DictationShortcut.self, from: JSONEncoder().encode(shortcut)), shortcut)
        XCTAssertThrowsError(try JSONDecoder().decode(DictationShortcut.self, from: Data("{\"key\":\"invalid\",\"modifiers\":\"Control–Option\"}".utf8)))
    }
}
