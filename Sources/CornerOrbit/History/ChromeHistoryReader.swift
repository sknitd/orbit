import Foundation
import SQLite3
import CornerCore

protocol ChromeHistoryReading: Sendable {
    func read(from historyFile: URL, limit: Int) async throws -> [CornerHistoryEntry]
}

enum ChromeHistoryError: Error, LocalizedError, Equatable, Sendable {
    case invalidFile, oversizedFile, invalidDatabase, unsupportedSchema, busy, timedOut
    case databaseUnavailable(Int32)
    var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose a readable, regular Chrome History SQLite file, or its profile folder. Links and special files are not accepted."
        case .oversizedFile: "This History file exceeds the 512 MB read limit. Choose a smaller profile."
        case .invalidDatabase: "The selected file is not a readable SQLite history database. Its original contents were not changed."
        case .unsupportedSchema: "This database does not contain the supported Chrome urls table (URL, title, visit time and visit count)."
        case .busy: "Chrome's history is temporarily locked. The previous loaded entries remain available; try Refresh again or close Chrome first."
        case .timedOut: "The bounded history query timed out. The previous loaded entries remain available."
        case .databaseUnavailable: "Chrome history could not be opened read-only. Choose a readable profile and retry. If macOS denies access, review the app's Files and Folders or Full Disk Access settings yourself."
        }
    }
}

/// No default profile is opened. The caller must supply an explicitly selected file.
/// SQLite may coordinate a live WAL through its transient -shm file; this reader
/// never copies/checkpoints/deletes the source or writes SQL history data.
struct ChromeHistoryReader: ChromeHistoryReading {
    static let defaultLocationDescription = "~/Library/Application Support/Google/Chrome/Default/History"
    static let maximumFileBytes: Int64 = 512 * 1024 * 1024
    static let maximumRows = 200
    let queryTimeout: TimeInterval
    init(queryTimeout: TimeInterval = 3) { self.queryTimeout = min(10, max(0.05, queryTimeout)) }

    func read(from historyFile: URL, limit: Int = 100) async throws -> [CornerHistoryEntry] {
        let cancellation = HistoryReadCancellation(deadline: ProcessInfo.processInfo.systemUptime + queryTimeout)
        let job = Task.detached(priority: .userInitiated) {
            try Self.readSynchronously(historyFile, limit: min(Self.maximumRows, max(1, limit)), cancellation: cancellation)
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let entries = try await job.value
            try Task.checkCancellation()
            return entries
        } onCancel: { cancellation.cancel(); job.cancel() }
    }

    private static func readSynchronously(_ file: URL, limit: Int, cancellation: HistoryReadCancellation) throws -> [CornerHistoryEntry] {
        try cancellation.check()
        guard file.isFileURL, (file.host ?? "").isEmpty || file.host == "localhost" else { throw ChromeHistoryError.invalidFile }
        let info: URLResourceValues
        do { info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch { throw ChromeHistoryError.databaseUnavailable(SQLITE_CANTOPEN) }
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw ChromeHistoryError.invalidFile }
        guard let size = info.fileSize, size >= 100 else { throw ChromeHistoryError.invalidDatabase }
        guard Int64(size) <= maximumFileBytes else { throw ChromeHistoryError.oversizedFile }

        var database: OpaquePointer?
        let code = sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard code == SQLITE_OK, let database else { if let database { sqlite3_close_v2(database) }; throw mappedError(code, cancellation: cancellation) }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_db_readonly(database, "main") == 1 else { throw ChromeHistoryError.invalidDatabase }
        sqlite3_busy_timeout(database, 750)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 64 * 1024)
        sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 16 * 1024)
        sqlite3_limit(database, SQLITE_LIMIT_ATTACHED, 0)
        // Apple system SQLite omits the extension-loading API. This reader
        // never enables or requests extensions; it uses only fixed read SQL.
        let context = Unmanaged.passUnretained(cancellation).toOpaque()
        sqlite3_progress_handler(database, 1_000, { context in
            guard let context else { return 1 }
            return Unmanaged<HistoryReadCancellation>.fromOpaque(context).takeUnretainedValue().mustStop ? 1 : 0
        }, context)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        try execute("PRAGMA query_only=ON", database: database, cancellation: cancellation)
        try execute("PRAGMA trusted_schema=OFF", database: database, cancellation: cancellation)
        try execute("BEGIN DEFERRED TRANSACTION", database: database, cancellation: cancellation)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        try validateSchema(database, cancellation: cancellation)

        var statement: OpaquePointer?
        // Parameters and static SQL only; no selected filename or title enters SQL.
        let sql = "SELECT url, title, last_visit_time, visit_count FROM urls ORDER BY last_visit_time DESC, url COLLATE BINARY ASC LIMIT ?1"
        let prepare = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else { throw mappedError(prepare, cancellation: cancellation) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int(statement, 1, Int32(limit)) == SQLITE_OK else { throw ChromeHistoryError.invalidDatabase }
        var entries: [CornerHistoryEntry] = []
        while true {
            try cancellation.check()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw mappedError(step, cancellation: cancellation) }
            guard sqlite3_column_type(statement, 2) == SQLITE_INTEGER, sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
                  sqlite3_column_int64(statement, 2) > 0,
                  let rawURL = string(statement, column: 0, maximumBytes: 8_192),
                  let url = URL(string: rawURL), let visited = CornerHistorySanitizer.chromeVisitDate(microsecondsSince1601: sqlite3_column_int64(statement, 2)) else { continue }
            let visits = sqlite3_column_int64(statement, 3)
            guard visits >= 0, visits <= Int64(Int.max) else { continue }
            let title: String
            if sqlite3_column_type(statement, 1) == SQLITE_NULL { title = "" }
            else { guard let decoded = string(statement, column: 1, maximumBytes: 4_096) else { continue }; title = decoded }
            let entry = CornerHistoryEntry(url: url, title: title, lastVisited: visited, visitCount: Int(visits), source: .chrome)
            guard (try? entry.validated()) != nil else { continue }
            entries.append(entry)
        }
        try cancellation.check()
        return CornerHistorySanitizer.sanitize(entries, limit: limit)
    }

    private static func validateSchema(_ database: OpaquePointer, cancellation: HistoryReadCancellation) throws {
        var table: OpaquePointer?
        let result = sqlite3_prepare_v2(database, "SELECT sql FROM sqlite_master WHERE type='table' AND name='urls'", -1, &table, nil)
        guard result == SQLITE_OK, let table else { throw mappedError(result, cancellation: cancellation) }
        defer { sqlite3_finalize(table) }
        let firstStep = sqlite3_step(table)
        guard firstStep == SQLITE_ROW else {
            if firstStep == SQLITE_DONE { throw ChromeHistoryError.unsupportedSchema }
            throw mappedError(firstStep, cancellation: cancellation)
        }
        guard let createSQL = string(table, column: 0, maximumBytes: 16_384),
              createSQL.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("CREATE TABLE") else { throw ChromeHistoryError.unsupportedSchema }
        var columns: OpaquePointer?
        let prepare = sqlite3_prepare_v2(database, "PRAGMA table_info(urls)", -1, &columns, nil)
        guard prepare == SQLITE_OK, let columns else { throw mappedError(prepare, cancellation: cancellation) }
        defer { sqlite3_finalize(columns) }
        var names = Set<String>(), count = 0
        while true {
            try cancellation.check()
            let step = sqlite3_step(columns)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw mappedError(step, cancellation: cancellation) }
            count += 1
            guard count <= 64 else { throw ChromeHistoryError.unsupportedSchema }
            if let name = string(columns, column: 1, maximumBytes: 256) { names.insert(name) }
        }
        guard Set(["url", "title", "last_visit_time", "visit_count"]).isSubset(of: names) else { throw ChromeHistoryError.unsupportedSchema }
    }
    private static func string(_ statement: OpaquePointer, column: Int32, maximumBytes: Int) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= maximumBytes, let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(data: Data(bytes: pointer, count: count), encoding: .utf8)
    }
    private static func execute(_ sql: String, database: OpaquePointer, cancellation: HistoryReadCancellation) throws {
        try cancellation.check()
        let code = sqlite3_exec(database, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw mappedError(code, cancellation: cancellation) }
    }
    private static func mappedError(_ code: Int32, cancellation: HistoryReadCancellation) -> Error {
        if cancellation.cancelled { return CancellationError() }
        if cancellation.mustStop { return ChromeHistoryError.timedOut }
        switch code & 0xff {
        case SQLITE_BUSY, SQLITE_LOCKED: return ChromeHistoryError.busy
        case SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_TOOBIG: return ChromeHistoryError.invalidDatabase
        default: return ChromeHistoryError.databaseUnavailable(code)
        }
    }
}

private final class HistoryReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private let deadline: TimeInterval
    init(deadline: TimeInterval) { self.deadline = deadline }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return requested }
    var mustStop: Bool { cancelled || ProcessInfo.processInfo.systemUptime >= deadline }
    func cancel() { lock.lock(); requested = true; lock.unlock() }
    func check() throws {
        if cancelled || Task.isCancelled { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw ChromeHistoryError.timedOut }
    }
}
