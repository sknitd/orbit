import Foundation
import XCTest
@testable import CornerCore

final class CornerClipboardTests: XCTestCase {
    func testPlainTextCleanupPreservesEmojiJoinersLanguageMarksAndUsefulWhitespace() throws {
        let text = "\u{feff}Hi\u{200b}\u{0000}\r\n👩‍💻\tनमस्ते\rnext"
        XCTAssertEqual(try CornerClipboardTransform.apply(text, mode: .plainText), "Hi\n👩‍💻\tनमस्ते\nnext")
    }
    func testJSONPrettyMinifyPreserveNumberLexemesDuplicateKeysAndEscapedStrings() throws {
        let compact = #"{"large":9007199254740993,"decimal":1.2300,"exponent":1e-3,"same":1,"same":2,"text":"quotes \" and [ ] \\ paths"}"#
        let pretty = try CornerClipboardTransform.apply(compact, mode: .jsonPretty)
        XCTAssertTrue(pretty.contains("\n  \"large\": 9007199254740993")); XCTAssertTrue(pretty.contains("\"decimal\": 1.2300"))
        XCTAssertEqual(try CornerClipboardTransform.apply(pretty, mode: .jsonMinify), compact)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(pretty.utf8)))
    }
    func testJSONHandlesEmptyContainersFragmentsAndInvalidSyntaxHonestly() throws {
        XCTAssertEqual(try CornerClipboardTransform.apply(" { \"a\" : [ ], \"b\" : { } } ", mode: .jsonPretty), "{\n  \"a\": [],\n  \"b\": {}\n}")
        XCTAssertEqual(try CornerClipboardTransform.apply(" true \n", mode: .jsonMinify), "true")
        for malformed in ["{broken", "[1,]", "{\"x\": NaN}", "\"unfinished", "01", "1.", "1e+", "1 2", "t r u e", "[1 2]", #""\uD800""#, #""\uDC00""#] { XCTAssertThrowsError(try CornerClipboardTransform.apply(malformed, mode: .jsonPretty)) }
        XCTAssertEqual(try CornerClipboardTransform.apply("1e999", mode: .jsonMinify), "1e999", "Valid JSON number lexemes never round-trip through a floating-point value")
    }
    func testJSONNestingAndOutputExpansionAreBounded() throws {
        let tooDeep = String(repeating: "[", count: 129) + "0" + String(repeating: "]", count: 129)
        XCTAssertThrowsError(try CornerClipboardTransform.apply(tooDeep, mode: .jsonPretty)) { XCTAssertEqual($0 as? CornerClipboardError, .nestingTooDeep) }
        let prefix = String(repeating: "[", count: 100), suffix = String(repeating: "]", count: 100)
        let expands = prefix + Array(repeating: "0", count: 15_000).joined(separator: ",") + suffix
        XCTAssertThrowsError(try CornerClipboardTransform.apply(expands, mode: .jsonPretty)) { XCTAssertEqual($0 as? CornerClipboardError, .outputTooLarge) }
    }
    func testURLValueEncodingRoundTripsUnicodeAndLeavesLiteralPlusOnDecode() throws {
        let input = "café / a+b? 👩‍💻"
        let encoded = try CornerClipboardTransform.apply(input, mode: .urlEncode)
        XCTAssertTrue(encoded.contains("%C3%A9")); XCTAssertTrue(encoded.contains("%2B")); XCTAssertFalse(encoded.contains(" "))
        XCTAssertEqual(try CornerClipboardTransform.apply(encoded, mode: .urlDecode), input)
        XCTAssertEqual(try CornerClipboardTransform.apply("a+b", mode: .urlDecode), "a+b")
        for malformed in ["%", "%2", "%ZZ", "%FF"] { XCTAssertThrowsError(try CornerClipboardTransform.apply(malformed, mode: .urlDecode)) }
    }
    func testBase64RoundTripsUnicodeAndRejectsInvalidPaddingBitsAndBinary() throws {
        let input = "مرحبا 👋 café"
        let encoded = try CornerClipboardTransform.apply(input, mode: .base64Encode)
        XCTAssertEqual(try CornerClipboardTransform.apply(encoded, mode: .base64Decode), input)
        XCTAssertEqual(try CornerClipboardTransform.apply("", mode: .base64Decode), "")
        for malformed in ["%%%", "Zg", "Zh==", "Zg===", "Zm 9v"] { XCTAssertThrowsError(try CornerClipboardTransform.apply(malformed, mode: .base64Decode)) }
        XCTAssertThrowsError(try CornerClipboardTransform.apply("/w==", mode: .base64Decode)) { XCTAssertEqual($0 as? CornerClipboardError, .binaryBase64) }
    }
    func testUnicodeCaseAndCamelAcronymWordConversions() throws {
        XCTAssertEqual(try CornerClipboardTransform.apply("straße élAN", mode: .uppercase), "STRASSE ÉLAN")
        XCTAssertEqual(try CornerClipboardTransform.apply("CAFÉ", mode: .lowercase), "café")
        XCTAssertEqual(try CornerClipboardTransform.apply("élAN café", mode: .titleCase), "Élan Café")
        XCTAssertEqual(try CornerClipboardTransform.apply("URLParser déjàVu v2Update", mode: .snakeCase), "url_parser_déjà_vu_v2_update")
        XCTAssertEqual(try CornerClipboardTransform.apply("URLParser déjàVu v2Update", mode: .kebabCase), "url-parser-déjà-vu-v2-update")
    }
    func testTrackingRemovalKeepsNonTrackingQueryEscapesDuplicatesPlusAndFragment() throws {
        let source = "HTTPS://Example.com/path?utm_source=mail&q=a+b&%75tm_campaign=x&ref=important&q=%2F&fbclid=123#anchor"
        XCTAssertEqual(try CornerClipboardTransform.apply(source, mode: .stripTracking), "https://example.com/path?q=a+b&ref=important&q=%2F#anchor")
        XCTAssertEqual(try CornerClipboardTransform.apply("https://example.com/?gclid=123#keep", mode: .stripTracking), "https://example.com/#keep")
        XCTAssertThrowsError(try CornerClipboardTransform.apply("https://user:secret@example.com", mode: .stripTracking))
        XCTAssertThrowsError(try CornerClipboardTransform.apply("file:///private/file", mode: .stripTracking))
    }
    func testTrimAndDedupeKeepFirstLineOrderAndRemainSeparateOperations() throws {
        XCTAssertEqual(try CornerClipboardTransform.apply(" a \r\n\tb\t\r\n", mode: .trimLines), "a\nb\n")
        XCTAssertEqual(try CornerClipboardTransform.apply("a\n\nb\na\n\nb", mode: .dedupeLines), "a\n\nb")
        XCTAssertEqual(try CornerClipboardTransform.apply(" A \nA\n A ", mode: .dedupeLines), " A \nA")
    }
    func testInputAndEncodedOutputLimitsRejectBeforeReturningReplacement() throws {
        XCTAssertThrowsError(try CornerClipboardTransform.apply(String(repeating: "x", count: CornerClipboardTransform.maximumInputBytes + 1), mode: .plainText)) { XCTAssertEqual($0 as? CornerClipboardError, .inputTooLarge) }
        XCTAssertThrowsError(try CornerClipboardTransform.apply(String(repeating: " ", count: 800_000), mode: .urlEncode)) { XCTAssertEqual($0 as? CornerClipboardError, .outputTooLarge) }
    }
}
