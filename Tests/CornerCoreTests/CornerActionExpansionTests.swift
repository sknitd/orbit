import Foundation
import XCTest
@testable import CornerCore

final class CornerActionExpansionTests: XCTestCase {
    func testEveryCatalogEntryHasUniqueCompleteSearchMetadataAndExpectedRoutes() {
        XCTAssertEqual(CornerActionCatalog.all.count, 60)
        XCTAssertEqual(Set(CornerActionCatalog.all).count, 60)
        for kind in CornerActionCatalog.all {
            XCTAssertFalse(kind.title.isEmpty); XCTAssertFalse(kind.systemImage.isEmpty)
            XCTAssertFalse(kind.category.isEmpty); XCTAssertFalse(kind.purpose.isEmpty)
            XCTAssertTrue(kind.searchTerms.contains(kind.title))
        }
        XCTAssertEqual(CornerActionCatalog.all.filter(\.isWindowAction).count, 10)
        XCTAssertEqual(CornerActionCatalog.all.filter(\.isClipboardTransform).count, 16)
        XCTAssertEqual(CornerActionKind.chromeSearchClipboard.defaultBundleID, "com.google.Chrome")
        XCTAssertNil(CornerActionKind.chromeSearchClipboard.defaultURL)
        XCTAssertTrue(CornerActionKind.chromeSearchClipboard.title.contains("Google"))
        XCTAssertTrue(CornerActionKind.screenSaver.purpose.contains("does not lock"))
        XCTAssertTrue(CornerActionKind.screenshotToolbar.purpose.contains("toolbar"))
    }
    func testLegacyVersionOneActionsDecodeWithNoArgumentAndNewActionsRoundTrip() throws {
        let legacy = try JSONDecoder().decode(CornerAction.self, from: Data("{\"kind\":\"newTextEdit\"}".utf8))
        XCTAssertEqual(legacy, .init(kind: .newTextEdit)); XCTAssertNil(legacy.argument)
        let cases = [CornerAction(kind: .openFile, argument: "/tmp/A folder/report.txt"),
                     CornerAction(kind: .runShortcut, argument: "My \"quoted\" Shortcut; $(not-a-shell)"),
                     CornerAction(kind: .openURLGroup, argument: "a04f9a3c-6db5-4caa-a2b9-42d7860d1564")]
        for action in cases {
            let normalized = try action.validated()
            XCTAssertEqual(try JSONDecoder().decode(CornerAction.self, from: JSONEncoder().encode(action)), normalized)
        }
    }
    func testParameterKindsOnlyPermitTheirOwnFieldsAndRequiredArgument() throws {
        let kinds: [(CornerActionKind, CornerActionParameterKind)] = [(.openURL, .website), (.openApplication, .application), (.openFile, .file), (.runShortcut, .shortcut), (.openURLGroup, .urlGroup)]
        for (kind, parameter) in kinds {
            XCTAssertEqual(kind.parameterKind, parameter)
            XCTAssertThrowsError(try CornerAction(kind: kind).validated())
        }
        for kind in CornerActionCatalog.all where kind.parameterKind == .none {
            XCTAssertThrowsError(try CornerAction(kind: kind, argument: "unexpected").validated())
            XCTAssertThrowsError(try CornerAction(kind: kind, url: "https://example.com").validated())
            XCTAssertNoThrow(try CornerAction(kind: kind).validated())
        }
        XCTAssertThrowsError(try CornerAction(kind: .runShortcut, url: "https://example.com", argument: "Good").validated())
        XCTAssertThrowsError(try CornerAction(kind: .openFile, bundleID: "com.apple.TextEdit", argument: "/tmp/file").validated())
        XCTAssertThrowsError(try CornerAction(kind: .openURL, url: "https://example.com", argument: "extra").validated())
    }
    func testAbsoluteLocalPathsRejectSchemesTraversalAndControlCharacters() throws {
        XCTAssertEqual(try CornerActionArgumentValidation.localPath("/tmp/a folder/./file.txt"), "/tmp/a folder/file.txt")
        for path in ["relative.txt", "~/file", "file:///tmp/file", "/tmp/../private", "/tmp/file\nother", "/tmp/a\0b", "/" + String(repeating: "a", count: 4_097)] {
            XCTAssertThrowsError(try CornerActionArgumentValidation.localPath(path), path)
        }
        XCTAssertThrowsError(try CornerAction(kind: .openURLGroup, argument: "../../../folder").validated())
        XCTAssertThrowsError(try CornerAction(kind: .openURLGroup, argument: "https://example.com").validated())
    }
    func testShortcutNamesPreserveRealSpacesAndRejectControlsAndExcessiveBytes() throws {
        XCTAssertEqual(try CornerActionArgumentValidation.shortcutName(" A Shortcut "), " A Shortcut ")
        for name in ["", "   ", "--input-path", "-option", "name\nsecond", "name\0second", String(repeating: "é", count: 513)] {
            XCTAssertThrowsError(try CornerActionArgumentValidation.shortcutName(name))
        }
    }
    func testClipboardSearchEncodesExactlyOneGoogleQueryAndHonorsUTF8ByteBound() throws {
        let input = "a&b=1 #fragment \"quote\"; $(command) 😀\nsecond line"
        let url = try CornerClipboardActionText.googleSearchURL(input)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https"); XCTAssertEqual(components.host, "www.google.com")
        XCTAssertEqual(components.path, "/search"); XCTAssertNil(components.fragment)
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: input)])
        XCTAssertNoThrow(try CornerClipboardActionText.bounded(String(repeating: "é", count: 32_768)))
        XCTAssertThrowsError(try CornerClipboardActionText.bounded(String(repeating: "é", count: 32_769)))
        XCTAssertThrowsError(try CornerClipboardActionText.googleSearchURL(" \n "))
    }
}
