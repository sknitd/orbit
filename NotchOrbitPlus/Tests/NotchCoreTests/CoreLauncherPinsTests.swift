import XCTest
@testable import NotchCore

final class CoreLauncherPinsTests: XCTestCase {
    func testPersistenceReorderingAndSearchKeepOpaqueBookmarksAndIdentities() throws {
        let folder = PlusLauncherPin(label: "Résumé", kind: .folder, targetIdentifier: "/Users/example/Documents", bookmark: Data([1, 2, 3]))
        let shortcut = PlusLauncherPin(label: "Daily Check", kind: .shortcut, targetIdentifier: "12345678-1234-1234-1234-1234567890AB")
        let decoded = try PlusLauncherPins.decode(PlusLauncherPins.encode([folder, shortcut]))
        XCTAssertEqual(decoded, [folder, shortcut])
        XCTAssertEqual(PlusLauncherPins.moved(decoded, id: shortcut.id, by: -1), [shortcut, folder])
        XCTAssertEqual(PlusLauncherPins.moved(decoded, id: folder.id, by: -1), decoded)
        XCTAssertTrue(PlusLauncherPins.matches(folder, query: "resume"))
        XCTAssertTrue(PlusLauncherPins.matches(shortcut, query: "SHORTCUT"))
        XCTAssertFalse(PlusLauncherPins.matches(folder, query: "Daily"))
    }
    func testMalformedShortcutCannotInjectCLIFlagsAndDuplicatesAreRejected() throws {
        let invalid = PlusLauncherPin(label: "Bad", kind: .shortcut, targetIdentifier: "--input-path /tmp/file")
        XCTAssertThrowsError(try PlusLauncherPins.encode([invalid]))
        let first = PlusLauncherPin(label: "A", kind: .shortcut, targetIdentifier: "12345678-1234-1234-1234-1234567890AB")
        let duplicate = PlusLauncherPin(label: "Other label", kind: .shortcut, targetIdentifier: first.targetIdentifier.lowercased())
        XCTAssertThrowsError(try PlusLauncherPins.inserting(duplicate, into: [first]))
        XCTAssertThrowsError(try PlusLauncherPins.encode([first, first]))
        XCTAssertThrowsError(try PlusLauncherPins.encode([PlusLauncherPin(label: "Empty", kind: .folder, targetIdentifier: "/tmp")]))
    }
}
