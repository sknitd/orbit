import AppKit
import SwiftUI
import SQLite3
import NotchCore

protocol PlusVerificationCodeReading: Sendable { func read(now: Date) async throws -> [CoreVerificationCode] }

struct MessagesVerificationCodeReader: PlusVerificationCodeReading {
    let databaseURL: URL
    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")) { self.databaseURL = databaseURL }
    func read(now: Date) async throws -> [CoreVerificationCode] {
        let url = databaseURL
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let since = now.addingTimeInterval(-60).timeIntervalSinceReferenceDate
            guard since.isFinite, abs(since * 1_000_000_000) < Double(Int64.max) else {
                throw NSError(domain: "NotchOrbitPlus.MessagesCodes", code: 4, userInfo: [NSLocalizedDescriptionKey: "The system clock is outside the supported Messages date range."])
            }
            var database: OpaquePointer?
            let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
            defer { if let database { sqlite3_close(database) } }
            guard opened == SQLITE_OK, let database else {
                throw NSError(domain: "NotchOrbitPlus.MessagesCodes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Messages could not be opened read-only. Enable Full Disk Access for NotchOrbitPlus in System Settings, then retry. No Messages data was changed."])
            }
            sqlite3_busy_timeout(database, 250)
            sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 131_072)
            let sql = "SELECT ROWID, date, substr(text, 1, 4096) FROM message WHERE is_from_me = 0 AND text IS NOT NULL AND length(CAST(text AS BLOB)) <= 16384 AND (date >= ? OR (date < 10000000000 AND date >= ?)) ORDER BY date DESC LIMIT 50"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw NSError(domain: "NotchOrbitPlus.MessagesCodes", code: 2, userInfo: [NSLocalizedDescriptionKey: "This Messages database schema is unsupported or unavailable. Only recent incoming plain-text messages are supported."])
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(since * 1_000_000_000)); sqlite3_bind_int64(statement, 2, Int64(since))
            var codes: [CoreVerificationCode] = []
            while true {
                try Task.checkCancellation()
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw NSError(domain: "NotchOrbitPlus.MessagesCodes", code: 3, userInfo: [NSLocalizedDescriptionKey: "Messages is busy or the read-only query failed. Try again."]) }
                guard let bytes = sqlite3_column_text(statement, 2) else { continue }
                let text = String(cString: bytes)
                if let code = CoreVerificationCode(id: sqlite3_column_int64(statement, 0), text: text,
                    messageDate: sqlite3_column_int64(statement, 1), now: now) { codes.append(code) }
            }
            return Array(codes.prefix(5))
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

@MainActor
final class VerificationCodesStore: NSObject, ObservableObject {
    static let shared = VerificationCodesStore()
    @Published private(set) var enabled = false
    @Published var backgroundEnabled = false { didSet { reconcile() } }
    @Published private(set) var codes: [CoreVerificationCode] = []
    @Published private(set) var error: String?
    @Published private(set) var reading = false
    private let reader: any PlusVerificationCodeReading
    private let pasteboard: NSPasteboard
    private var visible = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(reader: any PlusVerificationCodeReading = MessagesVerificationCodeReader(), pasteboard: NSPasteboard = .general) {
        self.reader = reader; self.pasteboard = pasteboard; super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(terminate), name: NSApplication.willTerminateNotification, object: nil)
    }
    @objc private func terminate() { setEnabled(false) }
    var liveStatus: CoreVerificationCode? { codes.first { $0.isVisible(at: Date()) } }
    var visibleCodes: [CoreVerificationCode] { codes.filter { $0.isVisible(at: Date()) } }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled; reconcile() }
    func setVisible(_ visible: Bool) { self.visible = visible; reconcile() }
    private func reconcile() {
        guard enabled, visible || backgroundEnabled else {
            generation = UUID(); task?.cancel(); task = nil; reading = false; codes = []; return
        }
        guard task == nil else { return }
        let id = UUID(); generation = id
        task = Task {
            defer { if self.generation == id { self.task = nil; self.reading = false } }
            while !Task.isCancelled, self.generation == id {
                self.reading = true
                do {
                    let codes = try await self.reader.read(now: Date())
                    try Task.checkCancellation()
                    guard self.generation == id else { return }
                    self.codes = codes; self.error = nil; self.reading = false
                    for _ in 0..<3 {
                        try await Task.sleep(for: .seconds(1))
                        self.codes.removeAll { !$0.isVisible(at: Date()) }
                    }
                } catch is CancellationError { return }
                catch {
                    guard self.generation == id else { return }
                    self.error = error.localizedDescription; self.codes = []; self.reading = false
                    return
                }
            }
        }
    }
    func refresh() { guard enabled else { return }; generation = UUID(); task?.cancel(); task = nil; reconcile() }
    func shutdown() { backgroundEnabled = false; setEnabled(false) }
    func copyCurrentCode() { if let current = liveStatus { copy(current) } }
    func copy(_ code: CoreVerificationCode) {
        guard visibleCodes.contains(code) else { return }
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.declareTypes([.string, concealed], owner: nil)
        guard pasteboard.setString(code.code, forType: .string), pasteboard.setData(Data(), forType: concealed) else {
            error = "macOS could not copy this code."; return
        }
    }
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }
}

@MainActor
struct VerificationCodesToolView: View {
    @ObservedObject private var store: VerificationCodesStore
    init(store: VerificationCodesStore = .shared) { self.store = store }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Messages Verification Codes").font(.headline)
            Text("Enable reads up to 50 incoming plain-text Messages from the last minute. Full Disk Access is required. Codes stay in memory for 60 seconds from the message timestamp; messages and codes are never saved by this tool.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Enable read-only Messages codes", isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) }))
            Toggle("Keep reading while the notch is closed", isOn: $store.backgroundEnabled).disabled(!store.enabled)
            HStack { Button("Open Full Disk Access Settings") { store.openFullDiskAccessSettings() }; Button("Retry / Refresh") { store.refresh() }.disabled(!store.enabled) }
            if store.reading { ProgressView().controlSize(.small) }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.codes.filter { $0.isVisible(at: context.date) }) { code in
                        HStack { Text(code.code).font(.system(.title2, design: .monospaced)); Spacer()
                            Text("\(max(0, Int(code.expiresAt.timeIntervalSince(context.date))))s").font(.caption)
                            Button("Copy") { store.copy(code) } }
                    }
                    if store.visibleCodes.isEmpty { Text(store.enabled ? "No supported recent code is available." : "Messages access is off at launch.").foregroundStyle(.secondary) }
                }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("Rich-body-only messages and code formats without a nearby verification keyword are unsupported. Copy marks the pasteboard as concealed so Orbit clipboard history skips it.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { store.setVisible(true) }.onDisappear { store.setVisible(false) }
            .background(OrbitNativeToolVisibility(onVisible: { store.setVisible(true) }, onHidden: { store.setVisible(false) }).frame(width: 0, height: 0))
    }
}
