import Foundation
import XCTest
@testable import NotchCore

final class SystemControlsTests: XCTestCase {
    func testOnlyRecognizedAuxiliaryKeysAndPhasesDecode() {
        for key in SystemMediaKey.allCases {
            let down = SystemMediaKeyEvent(subtype: 8, data1: (key.rawValue << 16) | 0x0a00)
            XCTAssertEqual(down?.key, key); XCTAssertEqual(down?.phase, .pressed); XCTAssertEqual(down?.isRepeat, false)
            let up = SystemMediaKeyEvent(subtype: 8, data1: (key.rawValue << 16) | 0x0b01)
            XCTAssertEqual(up?.phase, .released); XCTAssertEqual(up?.isRepeat, true)
        }
        XCTAssertNil(SystemMediaKeyEvent(subtype: 7, data1: 0x0a00))
        XCTAssertNil(SystemMediaKeyEvent(subtype: 8, data1: (16 << 16) | 0x0a00))
        XCTAssertNil(SystemMediaKeyEvent(subtype: 8, data1: 0x0c00))
    }
    func testLevelsClampStepsAndRejectInvalidHardwareReadings() {
        XCTAssertEqual(SystemControlLevel.stepped(0.98, increasing: true), 1)
        XCTAssertEqual(SystemControlLevel.stepped(0.02, increasing: false), 0)
        XCTAssertEqual(SystemControlLevel.stepped(0.5, increasing: true), 0.5625)
        for value in [Double.nan, .infinity, -0.1, 1.1] {
            XCTAssertNil(SystemControlLevel.valid(value)); XCTAssertNil(SystemHUDSnapshot(kind: .volume, level: value))
        }
        XCTAssertNil(SystemControlLevel.stepped(0.5, increasing: true, step: 0))
    }
    func testHUDDoesNotInventMuteForBrightness() {
        let bright = SystemHUDSnapshot(kind: .brightness, level: 0.42, muted: true)
        XCTAssertEqual(bright?.percent, 42); XCTAssertEqual(bright?.muted, false)
        XCTAssertEqual(SystemHUDSnapshot(kind: .volume, level: 0.7, muted: true)?.label, "Muted")
    }
}
