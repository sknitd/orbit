import XCTest
@testable import NotchCore

final class CoreAssistantFilesTests: XCTestCase {
    func testCSVQuotedFieldsRoundTripAndMalformedRowsAreRejected() throws {
        let text = "name,note\r\n\"Doe, Jane\",\"Line 1\nLine 2 with \"\"quotes\"\"\"\r\n"
        let rows = try AssistantFilePlanning.csvRows(text)
        XCTAssertEqual(rows, [["name", "note"], ["Doe, Jane", "Line 1\nLine 2 with \"quotes\""]])
        XCTAssertEqual(try AssistantFilePlanning.csvRows(AssistantFilePlanning.csv(rows)), rows)
        for malformed in ["a,b\n1", "a,b\n\"unfinished", "a,b\n\"closed\"extra,2", "header", "\n"] {
            XCTAssertThrowsError(try AssistantFilePlanning.csvRows(malformed))
        }
    }
    func testFilenameAndBoundedTextPlanningPreservesMeaningAndRejectsPaths() throws {
        XCTAssertEqual(try AssistantFilePlanning.filenameStem("  Project notes  "), "Project notes")
        for invalid in ["../secret", "a/b", "a\\b", ".hidden", "name\nsecond", "a:b", "", String(repeating: "a", count: 151)] {
            XCTAssertThrowsError(try AssistantFilePlanning.filenameStem(invalid))
        }
        XCTAssertEqual(try AssistantFilePlanning.boundedText("  useful text  "), "useful text")
        XCTAssertEqual(try AssistantFilePlanning.boundedText(String(repeating: "x", count: 10_000)).count, 8_000)
        XCTAssertThrowsError(try AssistantFilePlanning.boundedText(" \n "))
        XCTAssertTrue(AssistantFileAction.renameScreenshots.createsCopies)
        XCTAssertFalse(AssistantFileAction.extractCSV.createsCopies)
    }
}
