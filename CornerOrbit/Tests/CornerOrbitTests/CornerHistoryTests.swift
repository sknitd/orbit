import Foundation
import SQLite3
import XCTest
import CornerCore
@testable import CornerOrbit

final class CornerHistoryTests: XCTestCase, @unchecked Sendable {
    func testActualSQLiteQuerySortsBoundsConvertsChromeDatesAndPreservesSource() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("History"), database = try database(file)
        try insert(database, url: "https://example.com/old", title: "Older", seconds: 1_700_000_000, count: 3)
        try insert(database, url: "HTTPS://Example.com/new?q=keep%20query#section", title: "Latest", seconds: 1_700_000_100, count: 7)
        try insert(database, url: "https://example.org/middle", title: "Middle", seconds: 1_700_000_050, count: 2)
        sqlite3_close_v2(database)
        let before = try inventory(root)
        let entries = try await ChromeHistoryReader().read(from: file, limit: 2)
        XCTAssertEqual(entries.count, 2); XCTAssertEqual(entries.map(\.title), ["Latest", "Middle"])
        XCTAssertEqual(entries.first?.lastVisited.timeIntervalSince1970, 1_700_000_100)
        XCTAssertEqual(entries.first?.visitCount, 7); XCTAssertEqual(entries.first?.source, .chrome)
        XCTAssertEqual(entries.first?.url.query, "q=keep%20query"); XCTAssertEqual(entries.first?.url.fragment, "section")
        XCTAssertEqual(try inventory(root), before, "Rollback-journal read must leave source bytes and directory inventory unchanged")
    }

    func testActualLiveWALReaderSeesCommittedRowsWithoutChangingDatabaseOrWAL() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("History"), database = try database(file, wal: true)
        defer { sqlite3_close_v2(database) }
        try insert(database, url: "https://example.com/one", title: "One", seconds: 1_700_000_001)
        try insert(database, url: "https://example.com/two", title: "Two", seconds: 1_700_000_002)
        let wal = URL(fileURLWithPath: file.path + "-wal")
        let beforeDB = try Data(contentsOf: file), beforeWAL = try Data(contentsOf: wal)
        XCTAssertFalse(beforeWAL.isEmpty)
        let first = try await ChromeHistoryReader().read(from: file, limit: 100)
        XCTAssertEqual(first.map(\.title), ["Two", "One"])
        XCTAssertEqual(try Data(contentsOf: file), beforeDB); XCTAssertEqual(try Data(contentsOf: wal), beforeWAL)
        try insert(database, url: "https://example.com/three", title: "Three", seconds: 1_700_000_003)
        let secondDB = try Data(contentsOf: file), secondWAL = try Data(contentsOf: wal)
        let second = try await ChromeHistoryReader().read(from: file, limit: 100)
        XCTAssertEqual(second.map(\.title), ["Three", "Two", "One"])
        XCTAssertEqual(try Data(contentsOf: file), secondDB); XCTAssertEqual(try Data(contentsOf: wal), secondWAL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { ["History", "History-wal", "History-shm"].contains($0) })
        // SQLite-managed transient SHM coordination is permitted; no history
        // database/WAL contents are written by the read-only reader.
    }

    func testSupportedReadOnlyWALRecoveryCoordinatesMissingSHMWithoutHistoryWrites() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("History"), database = try database(file, wal: true)
        try insert(database, url: "https://example.com/committed", title: "Committed WAL row", seconds: 1_700_000_010)
        let wal = URL(fileURLWithPath: file.path + "-wal")
        // This synthetic fixture reproduces a committed database/WAL pair
        // after an unclean shutdown. No browser or personal database is copied.
        let originalDB = try Data(contentsOf: file), originalWAL = try Data(contentsOf: wal)
        sqlite3_close_v2(database)
        try originalDB.write(to: file); try originalWAL.write(to: wal)
        let shm = URL(fileURLWithPath: file.path + "-shm")
        // Apple SQLite may persist WAL/SHM after close. Only this private
        // synthetic fixture removes its SHM after all connections are closed.
        if FileManager.default.fileExists(atPath: shm.path) { try FileManager.default.removeItem(at: shm) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: shm.path))
        let entries = try await ChromeHistoryReader().read(from: file, limit: 100)
        XCTAssertEqual(entries.map(\.title), ["Committed WAL row"])
        XCTAssertEqual(try Data(contentsOf: file), originalDB); XCTAssertEqual(try Data(contentsOf: wal), originalWAL)
    }

    func testParentFolderAliasReadsSameHistoryButFinalHistorySymlinkIsRefused() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("physical-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        let file = profile.appendingPathComponent("History"), database = try database(file)
        try insert(database, url: "https://example.com/alias", title: "Parent alias", seconds: 1_700_000_123); sqlite3_close_v2(database)
        let alias = root.appendingPathComponent("profile-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: profile)
        let before = try Data(contentsOf: file)
        let entries = try await ChromeHistoryReader().read(from: alias.appendingPathComponent("History"), limit: 100)
        XCTAssertEqual(entries.map(\.title), ["Parent alias"])
        XCTAssertEqual(try Data(contentsOf: file), before)
        let finalLink = profile.appendingPathComponent("History-link")
        try FileManager.default.createSymbolicLink(at: finalLink, withDestinationURL: file)
        do { _ = try await ChromeHistoryReader().read(from: alias.appendingPathComponent("History-link"), limit: 100); XCTFail("A final History symlink must still be refused") }
        catch ChromeHistoryError.invalidFile {}
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: finalLink.path), file.path)
    }

    func testActualSQLiteSkipsUnsafeURLsMalformedDatesAndTypedRowsWithoutInventingEntries() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("History"), database = try database(file)
        for url in ["file:///tmp/secret", "data:text/plain,secret", "chrome://history", "https://user:password@example.com", "javascript:alert(1)"] {
            try insert(database, url: url, title: "Unsafe", seconds: 1_700_000_000)
        }
        try insert(database, url: "https://example.com/valid", title: "Valid", seconds: 1_700_000_050)
        try insert(database, url: "https://example.com/controls", title: "Bad\ntitle", seconds: 1_700_000_000)
        try exec(database, "INSERT INTO urls VALUES ('https://example.com/bad-date','Bad date',-1,1)")
        try exec(database, "INSERT INTO urls VALUES ('https://example.com/bad-count','Bad count',13344473600000000,'many')")
        try exec(database, "INSERT INTO urls VALUES ('https://example.com/future','Future',9223372036854775807,1)")
        sqlite3_close_v2(database)
        let before = try Data(contentsOf: file)
        let entries = try await ChromeHistoryReader().read(from: file, limit: 100)
        XCTAssertEqual(entries.map(\.title), ["Valid"])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testSchemaCorruptionOversizeAndSymlinksFailWithoutChangingOriginals() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let wrong = root.appendingPathComponent("WrongSchema"), database = try database(wrong, createTable: false)
        try exec(database, "CREATE TABLE urls(url TEXT)"); sqlite3_close_v2(database)
        let wrongBytes = try Data(contentsOf: wrong)
        do { _ = try await ChromeHistoryReader().read(from: wrong, limit: 100); XCTFail("Wrong schema must fail") }
        catch ChromeHistoryError.unsupportedSchema {}
        XCTAssertEqual(try Data(contentsOf: wrong), wrongBytes)
        let corrupt = root.appendingPathComponent("Corrupt"), corruptBytes = Data(repeating: 0x5b, count: 256)
        try corruptBytes.write(to: corrupt)
        do { _ = try await ChromeHistoryReader().read(from: corrupt, limit: 100); XCTFail("Corrupt database must fail") }
        catch ChromeHistoryError.invalidDatabase {}
        XCTAssertEqual(try Data(contentsOf: corrupt), corruptBytes)
        let sparse = root.appendingPathComponent("Oversized")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse); try handle.truncate(atOffset: UInt64(ChromeHistoryReader.maximumFileBytes + 1)); try handle.close()
        do { _ = try await ChromeHistoryReader().read(from: sparse, limit: 100); XCTFail("Oversized database must fail before opening") }
        catch ChromeHistoryError.oversizedFile {}
        let link = root.appendingPathComponent("Link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: wrong)
        do { _ = try await ChromeHistoryReader().read(from: link, limit: 100); XCTFail("Symlink selection must fail") }
        catch ChromeHistoryError.invalidFile {}
        XCTAssertEqual(try Data(contentsOf: wrong), wrongBytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), wrong.path)
    }

    func testLockedDatabaseReturnsBoundedHonestBusyError() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("History"), database = try database(file)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); sqlite3_close_v2(database) }
        try insert(database, url: "https://example.com/locked", title: "Locked fixture", seconds: 1_700_000_000)
        try exec(database, "BEGIN EXCLUSIVE")
        let before = try Data(contentsOf: file), start = ProcessInfo.processInfo.systemUptime
        do { _ = try await ChromeHistoryReader().read(from: file, limit: 100); XCTFail("Exclusive lock must surface") }
        catch ChromeHistoryError.busy {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testCancelledActualReaderReturnsCancellationAndPreservesSource() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("History"), database = try database(file)
        try insert(database, url: "https://example.com/cancel", title: "Cancelled fixture", seconds: 1_700_000_000); sqlite3_close_v2(database)
        let before = try inventory(root)
        let job = Task { try await ChromeHistoryReader().read(from: file, limit: 100) }
        job.cancel()
        do { _ = try await job.value; XCTFail("Cancelled request must not return rows") } catch is CancellationError {}
        XCTAssertEqual(try inventory(root), before)
    }

    @MainActor
    func testConstructionAndPreviewNeverResolveSavedBookmarkOrReadChrome() async throws {
        let (defaults, suite) = try preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-a-resolved-bookmark".utf8), forKey: "cornerorbit.chromeHistory.bookmark")
        let reader = HistoryReaderFixture()
        let store = ChromeHistoryStore(reader: reader, defaults: defaults); defer { store.shutdown() }
        XCTAssertTrue(store.isConnected); XCTAssertTrue(store.entries.isEmpty); XCTAssertNil(store.lastRefreshed)
        let calls = await reader.callCount(); XCTAssertEqual(calls, 0)
        let preview = ChromeHistoryStore(reader: reader, defaults: defaults, previewEntries: [entry("Preview")])
        XCTAssertEqual(preview.entries.map(\.title), ["Preview"]); XCTAssertFalse(preview.isRefreshing)
        let previewCalls = await reader.callCount(); XCTAssertEqual(previewCalls, 0)
    }

    @MainActor
    func testRefreshFailureRetainsDatedCacheAndConnectionAndDisconnectClearsThem() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("History"); try Data("Explicit selection fixture".utf8).write(to: file)
        let (defaults, suite) = try preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let expected = entry("Cached"), reader = HistoryReaderFixture(replies: [.success([expected]), .failure(.busy)])
        let store = ChromeHistoryStore(reader: reader, defaults: defaults); defer { store.shutdown() }
        store.connect(to: file); try await settled(store)
        XCTAssertEqual(store.entries, [expected]); let date = try XCTUnwrap(store.lastRefreshed)
        store.refresh(); try await settled(store)
        XCTAssertEqual(store.entries, [expected]); XCTAssertEqual(store.lastRefreshed, date)
        XCTAssertTrue(store.isConnected); XCTAssertNotNil(store.errorMessage)
        let calls = await reader.callCount(); XCTAssertEqual(calls, 2)
        store.disconnect(); XCTAssertFalse(store.isConnected); XCTAssertTrue(store.entries.isEmpty); XCTAssertNil(store.lastRefreshed)
        XCTAssertNil(defaults.object(forKey: "cornerorbit.chromeHistory.bookmark"))
    }

    @MainActor
    func testDisconnectCancelsAndRejectsAStaleReaderCompletion() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("History"); try Data("Explicit selection fixture".utf8).write(to: file)
        let (defaults, suite) = try preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let reader = HistoryReaderFixture(hold: true), store = ChromeHistoryStore(reader: reader, defaults: defaults)
        store.connect(to: file)
        for _ in 0..<100 {
            if await reader.callCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let calls = await reader.callCount(); XCTAssertEqual(calls, 1)
        store.disconnect(); await reader.complete([entry("Stale")])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(store.isConnected); XCTAssertFalse(store.isRefreshing); XCTAssertTrue(store.entries.isEmpty); XCTAssertNil(store.lastRefreshed)
    }

    @MainActor
    func testRecentLinksAreOptInBoundedPersistentAndClearedOnDisable() throws {
        let (defaults, suite) = try preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentlyOpenedStore(defaults: defaults), url = try XCTUnwrap(URL(string: "https://example.com/?q=preserved"))
        XCTAssertFalse(store.enabled); store.record(url, title: "No implicit tracking"); XCTAssertTrue(store.entries.isEmpty)
        store.setEnabled(true); store.record(url, title: "Explicitly opened"); store.record(url, title: "Explicitly opened again")
        XCTAssertEqual(store.entries.count, 1); XCTAssertEqual(store.entries.first?.visitCount, 2)
        for index in 0..<210 { store.record(try XCTUnwrap(URL(string: "https://example.com/\(index)")), title: "Fixture \(index)") }
        XCTAssertEqual(store.entries.count, 200)
        let reopened = RecentlyOpenedStore(defaults: defaults); XCTAssertEqual(reopened.entries, store.entries)
        reopened.record(try XCTUnwrap(URL(string: "https://user:secret@example.com"))); XCTAssertEqual(reopened.entries.count, 200)
        reopened.setEnabled(false); XCTAssertTrue(reopened.entries.isEmpty); XCTAssertNil(defaults.object(forKey: "cornerorbit.recentHistory.entries"))
        XCTAssertFalse(RecentlyOpenedStore(defaults: defaults).enabled)
    }

    @MainActor
    func testCorruptRecentOriginalSurvivesUntilExplicitClearAndPreviewDoesNotPersist() throws {
        let (defaults, suite) = try preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("{unreadable-history".utf8)
        defaults.set(true, forKey: "cornerorbit.recentHistory.enabled"); defaults.set(corrupt, forKey: "cornerorbit.recentHistory.entries")
        let store = RecentlyOpenedStore(defaults: defaults), item = entry("Preview")
        store.record(item.url, title: item.title); XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(defaults.data(forKey: "cornerorbit.recentHistory.entries"), corrupt)
        let preview = RecentlyOpenedStore(defaults: defaults, previewEntries: [item]); preview.clear()
        XCTAssertEqual(defaults.data(forKey: "cornerorbit.recentHistory.entries"), corrupt)
        store.clear(); XCTAssertNil(defaults.object(forKey: "cornerorbit.recentHistory.entries"))
        store.record(item.url, title: item.title); XCTAssertEqual(store.entries.count, 1)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CornerHistoryFixture.\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return root
    }
    private func database(_ url: URL, wal: Bool = false, createTable: Bool = true) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else { throw ChromeHistoryError.invalidDatabase }
        if wal { try exec(pointer, "PRAGMA journal_mode=WAL"); try exec(pointer, "PRAGMA wal_autocheckpoint=0") }
        if createTable { try exec(pointer, "CREATE TABLE urls(url TEXT, title TEXT, last_visit_time INTEGER, visit_count INTEGER)") }
        return pointer
    }
    private func exec(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ChromeHistoryError.invalidDatabase }
    }
    private func insert(_ database: OpaquePointer, url: String, title: String, seconds: Int64, count: Int64 = 1) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO urls VALUES (?1,?2,?3,?4)", -1, &statement, nil) == SQLITE_OK, let statement else { throw ChromeHistoryError.invalidDatabase }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)
        _ = url.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        _ = title.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
        sqlite3_bind_int64(statement, 3, (seconds + 11_644_473_600) * 1_000_000); sqlite3_bind_int64(statement, 4, count)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ChromeHistoryError.invalidDatabase }
    }
    private func inventory(_ root: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
    @MainActor private func preferences() throws -> (UserDefaults, String) {
        let suite = "CornerHistoryTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
    private func entry(_ title: String) -> CornerHistoryEntry {
        .init(url: URL(string: "https://example.com/fixture")!, title: title, lastVisited: Date(timeIntervalSince1970: 1_700_000_000), source: .chrome)
    }
    @MainActor private func settled(_ store: ChromeHistoryStore) async throws {
        for _ in 0..<200 where store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isRefreshing)
    }
}

private actor HistoryReaderFixture: ChromeHistoryReading {
    private var calls = 0
    private var replies: [Result<[CornerHistoryEntry], ChromeHistoryError>]
    private let hold: Bool
    private var continuation: CheckedContinuation<[CornerHistoryEntry], Error>?
    init(replies: [Result<[CornerHistoryEntry], ChromeHistoryError>] = [], hold: Bool = false) { self.replies = replies; self.hold = hold }
    func read(from: URL, limit: Int) async throws -> [CornerHistoryEntry] {
        calls += 1
        if hold { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return try replies.isEmpty ? [] : replies.removeFirst().get()
    }
    func callCount() -> Int { calls }
    func complete(_ entries: [CornerHistoryEntry]) { continuation?.resume(returning: entries); continuation = nil }
}
