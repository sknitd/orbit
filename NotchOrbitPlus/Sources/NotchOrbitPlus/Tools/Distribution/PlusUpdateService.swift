import AppKit
import Combine
import CryptoKit
import Foundation
import NotchCore

enum PlusUpdateNetworkError: LocalizedError, Sendable {
    case unpublished, response(Int), redirect, oversized
    var errorDescription: String? {
        switch self {
        case .unpublished: "The public update channel has not published a build yet."
        case .response(let status): "The public update channel returned HTTP \(status). No account or credential was requested."
        case .redirect: "The update request redirected outside its exact published URL."
        case .oversized: "The update response exceeded its published size limit."
        }
    }
}

private final class PlusUpdateRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor PlusUpdateClient {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: configuration, delegate: PlusUpdateRedirectGuard(), delegateQueue: nil)
    }
    func fetchFeed() async throws -> CoreUpdateFeed {
        let (bytes, response) = try await session.bytes(for: request(CoreUpdateFeed.channelURL))
        try validate(response, requested: CoreUpdateFeed.channelURL, limit: 128 * 1_024)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 128 * 1_024 else { throw PlusUpdateNetworkError.oversized }
            data.append(byte)
            if data.count % 4_096 == 0 { try Task.checkCancellation() }
        }
        return try CoreUpdateFeed.decode(data)
    }
    func download(_ feed: CoreUpdateFeed, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard feed.archiveURL.absoluteString == "https://raw.githubusercontent.com/sknitd/orbit/codex/notch-plus-updates/packages/\(feed.version)/\(feed.sourceCommit)/NotchOrbitPlus.app.zip",
              (1...CoreUpdateFeed.maximumArchiveBytes).contains(feed.archiveBytes) else { throw CoreUpdateError.invalidArchiveURL }
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("com.sknitd.NotchOrbitPlus/Updates/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = cache.appendingPathComponent("NotchOrbitPlus.app.zip")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: cache) } }
        let (bytes, response) = try await session.bytes(for: request(feed.archiveURL))
        try validate(response, requested: feed.archiveURL, limit: feed.archiveBytes)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var buffer = Data(); buffer.reserveCapacity(64 * 1_024)
        var hash = SHA256(); var count = 0
        for try await byte in bytes {
            count += 1
            guard count <= feed.archiveBytes && count <= CoreUpdateFeed.maximumArchiveBytes else { throw PlusUpdateNetworkError.oversized }
            buffer.append(byte)
            if buffer.count == 64 * 1_024 {
                try Task.checkCancellation(); hash.update(data: buffer); try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                progress(Double(count) / Double(feed.archiveBytes))
            }
        }
        try Task.checkCancellation()
        hash.update(data: buffer); try handle.write(contentsOf: buffer); try handle.synchronize()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        try feed.verifySHA256(digest, bytes: count)
        try Data(JSONEncoder().encode(PlusDownloadProvenance(version: feed.version, sourceCommit: feed.sourceCommit,
                                                           sha256: digest, bytes: count))).write(to: cache.appendingPathComponent("download-verification.json"), options: .atomic)
        completed = true; progress(1)
        return output
    }
    func install(_ file: URL, feed: CoreUpdateFeed, automatic: Bool) throws -> PlusInstalledUpdate {
        try PlusUpdateInstaller.install(archive: file, feed: feed, automatic: automatic)
    }
    func rollback(_ update: PlusInstalledUpdate) throws { try PlusUpdateInstaller.rollback(update) }
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("NotchOrbitPlus-update/0.2", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }
    private func validate(_ response: URLResponse, requested: URL, limit: Int) throws {
        guard let http = response as? HTTPURLResponse else { throw PlusUpdateNetworkError.response(0) }
        guard http.url?.absoluteString == requested.absoluteString else { throw PlusUpdateNetworkError.redirect }
        if http.statusCode == 404 { throw PlusUpdateNetworkError.unpublished }
        guard http.statusCode == 200 else { throw PlusUpdateNetworkError.response(http.statusCode) }
        guard response.expectedContentLength < 0 || response.expectedContentLength <= limit else { throw PlusUpdateNetworkError.oversized }
    }
}

private struct PlusDownloadProvenance: Encodable { let version: String; let sourceCommit: String; let sha256: String; let bytes: Int }

@MainActor
final class PlusUpdateService: ObservableObject {
    static let shared = PlusUpdateService()
    @Published private(set) var status = "Check the public update channel when you choose."
    @Published private(set) var available: CoreUpdateFeed?
    @Published private(set) var downloadedArchive: URL?
    @Published private(set) var working = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastChecked: Date?
    @Published var automaticallyCheck: Bool { didSet { defaults.set(automaticallyCheck, forKey: "NotchOrbitPlus.Updates.check"); start() } }
    @Published var automaticallyDownload: Bool { didSet { defaults.set(automaticallyDownload, forKey: "NotchOrbitPlus.Updates.download") } }
    @Published var automaticallyInstall: Bool { didSet { defaults.set(automaticallyInstall, forKey: "NotchOrbitPlus.Updates.install") } }
    private let defaults: UserDefaults
    private let client: PlusUpdateClient
    private var scheduler: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0" }
    var trustedInstallationAvailable: Bool { (try? PlusUpdateInstaller.currentTrustedTeamIdentifier()) != nil }
    init(defaults: UserDefaults = .standard, client: PlusUpdateClient = PlusUpdateClient()) {
        self.defaults = defaults; self.client = client
        automaticallyCheck = defaults.bool(forKey: "NotchOrbitPlus.Updates.check")
        automaticallyDownload = defaults.bool(forKey: "NotchOrbitPlus.Updates.download")
        automaticallyInstall = defaults.bool(forKey: "NotchOrbitPlus.Updates.install")
    }
    func start() {
        scheduler?.cancel(); scheduler = nil
        guard automaticallyCheck else { return }
        scheduler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.check(automatic: true)
                do { try await Task.sleep(for: .seconds(6 * 60 * 60)) } catch { return }
            }
        }
    }
    func shutdown() { scheduler?.cancel(); scheduler = nil; operation?.cancel(); operation = nil }
    func cancel() { operation?.cancel() }
    func check(automatic: Bool = false) {
        guard !working else { return }
        working = true; progress = 0; status = "Checking the public update channel…"
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { working = false; operation = nil }
            do {
                let feed = try await client.fetchFeed(); try Task.checkCancellation()
                let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
                guard feed.supportsMacOS(major: operatingSystem.majorVersion, minor: operatingSystem.minorVersion,
                                         patch: operatingSystem.patchVersion) else { throw CoreUpdateError.incompatibleSystem }
                lastChecked = .now
                guard try feed.isNewer(than: currentVersion) else { available = nil; downloadedArchive = nil; status = "You have the latest published version (\(currentVersion))."; return }
                if available?.archiveSHA256 != feed.archiveSHA256 { downloadedArchive = nil }
                available = feed; status = "Version \(feed.version) is available."
                if automatic && automaticallyDownload {
                    let file = try await downloadFile(feed)
                    if automaticallyInstall && trustedInstallationAvailable {
                        try await installFile(file, feed: feed, automatic: true)
                    }
                }
            } catch is CancellationError { status = "Update check cancelled." }
            catch { status = error.localizedDescription }
        }
    }
    func download() {
        guard !working, let feed = available else { return }
        working = true
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { working = false; operation = nil }
            do { _ = try await downloadFile(feed) }
            catch is CancellationError { status = "Download cancelled; partial data was removed." }
            catch { status = error.localizedDescription }
        }
    }
    func install() {
        guard !working, let file = downloadedArchive, let feed = available else { return }
        working = true
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { working = false; operation = nil }
            do { try await installFile(file, feed: feed, automatic: false) }
            catch { status = error.localizedDescription }
        }
    }
    private func downloadFile(_ feed: CoreUpdateFeed) async throws -> URL {
        status = "Downloading version \(feed.version)…"; progress = 0
        let file = try await client.download(feed) { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
        downloadedArchive = file; status = "Download complete. Published size and SHA-256 verified."
        return file
    }
    private func installFile(_ file: URL, feed: CoreUpdateFeed, automatic: Bool) async throws {
        status = "Verifying the developer signature before installation…"
        let plan = try await client.install(file, feed: feed, automatic: automatic)
        let configuration = NSWorkspace.OpenConfiguration(); configuration.createsNewApplicationInstance = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: plan.applicationURL, configuration: configuration) { application, error in
                    if let error { continuation.resume(throwing: error) }
                    else if application != nil { continuation.resume() }
                    else { continuation.resume(throwing: PlusUpdateInstallError.untrustedCandidate) }
                }
            }
            status = "The update is installed. Restarting…"
            NSApp.terminate(nil)
        } catch {
            try await client.rollback(plan)
            throw error
        }
    }
}
