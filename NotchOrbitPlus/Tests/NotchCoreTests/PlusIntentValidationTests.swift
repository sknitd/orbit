import XCTest
@testable import NotchCore

final class PlusIntentValidationTests: XCTestCase {
    func testFocusBoundsRejectOverflowAndZero() throws {
        XCTAssertEqual(try PlusIntentValidation.focusMinutes(1), 1)
        XCTAssertEqual(try PlusIntentValidation.focusMinutes(1_440), 1_440)
        for value in [Int.min, -1, 0, 1_441, Int.max] { XCTAssertThrowsError(try PlusIntentValidation.focusMinutes(value)) }
    }
    func testShortcutFilenameCannotTraverseOrHideItsTemporaryFile() throws {
        XCTAssertEqual(try PlusIntentValidation.filename("Meeting screenshot.png"), "Meeting screenshot.png")
        for value in ["", "../note", "a/b", "a\\b", ".hidden", " padded", "line\nname", String(repeating: "é", count: 101)] {
            XCTAssertThrowsError(try PlusIntentValidation.filename(value))
        }
    }
    func testWorkflowIdentityMustBeCanonicalAndCannotContainArguments() throws {
        let id = UUID()
        XCTAssertEqual(try PlusIntentValidation.presetID(id.uuidString), id)
        for value in ["", "--preset", "$(command)", id.uuidString + " extra"] {
            XCTAssertThrowsError(try PlusIntentValidation.presetID(value))
        }
    }
}
