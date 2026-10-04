import AppKit
import Foundation
import SQLite3
import XCTest
@testable import NotchOrbitPlus

final class MessagesVerificationCodeTests: XCTestCase, @unchecked Sendable {
    func testReadOnlyPrivateSQLiteFixtureFiltersAgeOutgoingAndUnrelatedNumbers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitCodesFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chat.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let sql = "CREATE TABLE message(date INTEGER, text TEXT, is_from_me INTEGER); INSERT INTO message VALUES(800000000000000000,'Your verification code is 012345',0),(799999939000000000,'Login code 999999',0),(800000000000000000,'Code 222222',1),(800000000000000000,'Invoice 123456',0);"
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let original = try Data(contentsOf: file)
        let codes = try await MessagesVerificationCodeReader(databaseURL: file).read(now: now)
        XCTAssertEqual(codes.map(\.code), ["012345"])
        XCTAssertEqual(try Data(contentsOf: file), original, "Reader must never modify Messages bytes")
    }
    @MainActor
    func testOffDefaultAndConcealedCopyDoNotPersistIntoClipboardHistory() async throws {
        let reader = CodesFixtureReader()
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let codes = VerificationCodesStore(reader: reader, pasteboard: board)
        let history = ClipboardToolStore(pasteboard: board, persistHistory: false)
        defer { codes.setEnabled(false); history.shutdown() }
        codes.setVisible(true)
        let initialReads = await reader.count()
        XCTAssertEqual(initialReads, 0); XCTAssertFalse(codes.enabled)
        history.setObserving(true)
        codes.setEnabled(true)
        for _ in 0..<40 where codes.liveStatus == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(codes.liveStatus)
        codes.copyCurrentCode(); history.captureIfChanged()
        XCTAssertEqual(board.string(forType: .string), "123456")
        XCTAssertTrue(board.types?.contains(.init("org.nspasteboard.ConcealedType")) == true)
        XCTAssertTrue(history.clips.isEmpty)
        codes.setEnabled(false); XCTAssertNil(codes.liveStatus); XCTAssertTrue(codes.codes.isEmpty)
    }
}

private actor CodesFixtureReader: PlusVerificationCodeReading {
    private var reads = 0
    func read(now: Date) async throws -> [CoreVerificationCode] {
        reads += 1
        return [try XCTUnwrap(CoreVerificationCode(id: 1, text: "Verification code 123456",
            messageDate: Int64(now.timeIntervalSinceReferenceDate * 1_000_000_000), now: now))]
    }
    func count() -> Int { reads }
}
