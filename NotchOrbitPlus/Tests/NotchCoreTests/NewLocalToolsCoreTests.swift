import Foundation
import XCTest
@testable import NotchCore

final class NewLocalToolsCoreTests: XCTestCase {
    func testTransformersPreserveJSONNumbersAndEscapesAndRejectMalformedInput() throws {
        let input = #"{ "number": 123456789012345678901, "text": "a\"b\\c", "list": [true,null,1.500e+2] }"#
        let minified = try CoreClipboardTransform.jsonMinify.apply(to: input)
        XCTAssertTrue(minified.contains("123456789012345678901")); XCTAssertTrue(minified.contains("1.500e+2"))
        XCTAssertTrue(minified.contains(#"a\"b\\c"#))
        XCTAssertEqual(try CoreClipboardTransform.jsonMinify.apply(to: CoreClipboardTransform.jsonPretty.apply(to: input)), minified)
        XCTAssertThrowsError(try CoreClipboardTransform.jsonPretty.apply(to: "{bad}"))
        XCTAssertThrowsError(try CoreClipboardTransform.base64Decode.apply(to: "%%%"))
        XCTAssertThrowsError(try CoreClipboardTransform.base64Decode.apply(to: Data([255]).base64EncodedString()))
        XCTAssertThrowsError(try CoreClipboardTransform.urlDecode.apply(to: "%ZZ"))
    }
    func testURLBase64TextAndTrackingTransformationsHaveActualResults() throws {
        let text = "Café + / ?"
        XCTAssertEqual(try CoreClipboardTransform.urlDecode.apply(to: CoreClipboardTransform.urlEncode.apply(to: text)), text)
        XCTAssertEqual(try CoreClipboardTransform.base64Decode.apply(to: CoreClipboardTransform.base64Encode.apply(to: text)), text)
        XCTAssertEqual(try CoreClipboardTransform.stripTracking.apply(to: "https://example.com/path?utm_source=ad&keep=two&gclid=123#part"), "https://example.com/path?keep=two#part")
        XCTAssertEqual(try CoreClipboardTransform.stripTracking.apply(to: "https://example.com/?name=a%2Bb&name=a+b&utm_source=ad"), "https://example.com/?name=a%2Bb&name=a+b")
        XCTAssertThrowsError(try CoreClipboardTransform.stripTracking.apply(to: "https://example.com/?name=%ZZ"))
        XCTAssertThrowsError(try CoreClipboardTransform.stripTracking.apply(to: "javascript:alert(1)"))
        XCTAssertEqual(try CoreClipboardTransform.deduplicateLines.apply(to: "a\r\nb\r\na\r\n"), "a\nb\n")
        XCTAssertEqual(try CoreClipboardTransform.trim.apply(to: " \n hello \t"), "hello")
        XCTAssertThrowsError(try CoreClipboardTransform.uppercase.apply(to: String(repeating: "a", count: 100_001)))
    }
    func testVerificationCodesRequireContextAndExpireAtOneMinute() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(CoreVerificationCodeParser.code(in: "Your verification code is 012345."), "012345")
        XCTAssertNil(CoreVerificationCodeParser.code(in: "Invoice number 123456 costs $4000"))
        XCTAssertNil(CoreVerificationCodeParser.code(in: "Your code is abc123456xyz"))
        let code = try XCTUnwrap(CoreVerificationCode(id: 1, text: "Login code 543210", messageDate: 800_000_000_000_000_000, now: now))
        XCTAssertTrue(code.isVisible(at: now.addingTimeInterval(59.9)))
        XCTAssertFalse(code.isVisible(at: now.addingTimeInterval(60)))
        XCTAssertNil(CoreVerificationCode(id: 2, text: "Code 543210", messageDate: 799_999_939, now: now))
        XCTAssertNil(CoreVerificationCode(id: 3, text: "Code 543210", messageDate: 800_000_006, now: now))
    }
    func testSearchRanksTitlesRequiresAllTokensAndMovesSelection() {
        let content = CoreSearchEntry(id: "note", title: "Quick Note", content: "Café report", toolID: "quickNote")
        let title = CoreSearchEntry(id: "file", title: "Café Report", toolID: "fileShelf")
        let unrelated = CoreSearchEntry(id: "other", title: "Café", toolID: "quickNote")
        let values = CoreGlobalSearch.results(query: "cafe report", entries: [content, unrelated, title, title])
        XCTAssertEqual(values.map(\.id), ["file", "note"])
        XCTAssertEqual(CoreGlobalSearch.selection(in: values, current: nil, offset: 1), "file")
        XCTAssertEqual(CoreGlobalSearch.selection(in: values, current: "file", offset: 1), "note")
        XCTAssertEqual(CoreGlobalSearch.selection(in: values, current: "note", offset: 1), "note")
        XCTAssertTrue(CoreGlobalSearch.results(query: "", entries: [title]).isEmpty)
    }
    func testPluginV1RejectsTraversalPermissionsAndUndeclaredButtons() throws {
        let valid = #"{"version":1,"id":"fixture","name":"Fixture","permissions":[],"items":[{"kind":"button","title":"Run","commandID":"hello"}],"commands":[{"id":"hello","script":"hello.sh"}]}"#
        let manifest = try CorePluginManifest.decode(Data(valid.utf8))
        XCTAssertEqual(manifest.commands.first?.script, "hello.sh")
        XCTAssertThrowsError(try CorePluginManifest.decode(Data(valid.replacingOccurrences(of: "hello.sh", with: "../outside.sh").utf8)))
        XCTAssertThrowsError(try CorePluginManifest.decode(Data(valid.replacingOccurrences(of: #""permissions":[]"#, with: #""permissions":["network"]"#).utf8)))
        XCTAssertThrowsError(try CorePluginOutput.decode(Data(#"{"items":[{"kind":"button","title":"Bad","commandID":"undeclared"}]}"#.utf8), manifest: manifest))
        XCTAssertThrowsError(try CorePluginOutput.decode(Data(#"{"items":[],"clipboardText":"secret"}"#.utf8), manifest: manifest))
    }
}
