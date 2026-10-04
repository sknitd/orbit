import XCTest
@testable import NotchCore

final class CoreTranslationTests: XCTestCase {
    func testTranslationRequestValidatesLanguagePairAndPreservesTypedText() throws {
        let request = try OrbitTranslationRequest(text: "  Hello\nworld  ", source: "en", target: "es")
        XCTAssertEqual(request.text, "Hello\nworld")
        XCTAssertEqual(request.source, "en"); XCTAssertEqual(request.target, "es")
        XCTAssertThrowsError(try OrbitTranslationRequest(text: "hello", source: "en", target: "en"))
        XCTAssertThrowsError(try OrbitTranslationRequest(text: "hello", source: "invalid", target: "es"))
        XCTAssertThrowsError(try OrbitTranslationRequest(text: " \n ", source: "en", target: "es"))
        XCTAssertThrowsError(try OrbitTranslationRequest(text: String(repeating: "a", count: 20_001), source: "en", target: "es"))
        XCTAssertEqual(Set(OrbitTranslationLanguage.choices.map(\.id)).count, OrbitTranslationLanguage.choices.count)
    }
}
