import XCTest
@testable import NotchCore

final class OrbitNativeParsersTests: XCTestCase {
    func testLyricsMultipleTagsFractionsOffsetAndSelection() {
        let lines = OrbitLRCParser.parse("[ar:Artist]\n[offset:+500]\n[00:10.05][01:20.5]Repeated\n[00:02.005]First\n[00:75]Invalid")
        XCTAssertEqual(lines.map(\.text), ["First", "Repeated", "Repeated"])
        XCTAssertEqual(lines[0].time, 2.505, accuracy: 0.0001)
        XCTAssertEqual(lines[1].time, 10.55, accuracy: 0.0001)
        XCTAssertEqual(lines[2].time, 81, accuracy: 0.0001)
        XCTAssertNil(OrbitLRCParser.activeIndex(in: lines, at: 0))
        XCTAssertEqual(OrbitLRCParser.activeIndex(in: lines, at: 12), 1)
    }

    func testShortcutNamesCannotBecomeCLIOptions() throws {
        let values = try OrbitShortcutListing.parse("--input-path (12345678-1234-1234-1234-1234567890ab)\nName (with brackets) (ABCDEFAB-1234-5678-ABCD-1234567890AB)")
        XCTAssertEqual(values[0].name, "--input-path")
        XCTAssertEqual(values[0].id, "12345678-1234-1234-1234-1234567890AB")
        XCTAssertEqual(values[1].name, "Name (with brackets)")
        XCTAssertThrowsError(try OrbitShortcutListing.parse("Name without an identifier"))
        XCTAssertEqual(try OrbitShortcutListing.parse("\n"), [])
    }
}
