import AppKit
import SwiftUI
import NotchCore

private final class GithubNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Only GET requests to GitHub's API are constructed, with finite page limits.
/// Injectable transport supports account-free fixtures without touching Keychain.
struct GithubActionsClient: Sendable {
    typealias Loader = @Sendable (URLRequest) async throws -> Data
    let load: Loader
    init(load: @escaping Loader = GithubActionsClient.networkLoad) { self.load = load }
    func repositories(token: String) async throws -> (items: [GithubRepository], limited: Bool) {
        var result: [GithubRepository] = [], seen = Set<Int64>()
        for page in 1...GithubActionsData.maximumRepositoryPages {
            try Task.checkCancellation()
            let rows = try GithubActionsData.repositories(try await load(request(try GithubActionsData.repositoryURL(page: page), token: token)))
            for row in rows where seen.insert(row.id).inserted { result.append(row) }
            if rows.count < GithubActionsData.pageSize { return (result, false) }
        }
        return (result, true)
    }
    func runs(repository: String, token: String) async throws -> (items: [GithubWorkflowRun], total: Int) {
        var result: [GithubWorkflowRun] = [], seen = Set<Int64>(), total = 0
        for page in 1...GithubActionsData.maximumRunPages {
            try Task.checkCancellation()
            let rows = try GithubActionsData.runPage(try await load(request(try GithubActionsData.runsURL(repository: repository, page: page), token: token)))
            total = rows.totalCount
            for row in rows.runs where seen.insert(row.id).inserted { result.append(row) }
            if rows.runs.count < GithubActionsData.pageSize || result.count >= total { break }
        }
        return (result.sorted { $0.updatedAt > $1.updatedAt }, total)
    }
    private func request(_ url: URL, token: String) throws -> URLRequest {
        guard !token.isEmpty, token.utf8.count <= 8_192, !token.contains("\n"), !token.contains("\r") else {
            throw OnlineServiceError.message("Enter a valid GitHub personal access token.")
        }
        var request = URLRequest(url: url); request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }
    private static func networkLoad(_ request: URLRequest) async throws -> Data {
        guard let url = request.url, url.scheme == "https", url.host == "api.github.com", url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil, request.httpMethod == "GET" else {
            throw OnlineServiceError.message("Refused an unsafe GitHub API request.")
        }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: GithubNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw OnlineServiceError.message("GitHub returned no HTTP response.") }
            guard (200..<300).contains(http.statusCode) else {
                let reason: String
                switch http.statusCode {
                case 401: reason = "The token was rejected. Save a valid GitHub token."
                case 403, 429: reason = "GitHub denied access or rate-limited the request. Check repository and Actions read permissions, then retry later."
                case 404: reason = "The repository is unavailable or Actions read access is missing."
                default: reason = "GitHub request failed (HTTP \(http.statusCode)). Try again later."
                }
                throw OnlineServiceError.message(reason)
            }
            guard response.expectedContentLength <= 4 * 1_024 * 1_024 else { throw OnlineServiceError.message("GitHub's response is too large.") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 4 * 1_024 * 1_024 else { throw OnlineServiceError.message("GitHub's response exceeds 4 MB.") }
                data.append(byte)
            }
            try Task.checkCancellation(); return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as OnlineServiceError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw OnlineServiceError.message("GitHub could not be reached. Check your connection and retry.")
        }
    }
}

@MainActor
final class GithubActionsToolModel: ObservableObject {
    static let tokenAccount = "github-actions"
    @Published var tokenInput = ""
    @Published private(set) var hasSavedToken = false
    @Published private(set) var repositories: [GithubRepository] = []
    @Published var selectedRepository = ""
    @Published private(set) var runs: [GithubWorkflowRun] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var busy = false
    @Published private(set) var coverage = ""
    @Published private(set) var repositoryCoverage = ""
    @Published var error: String?
    private let client: GithubActionsClient
    private var task: Task<Void, Never>?
    private var generation = 0
    init(client: GithubActionsClient = .init()) {
        self.client = client
        do { hasSavedToken = try OnlineServiceKeychain.read(Self.tokenAccount) != nil }
        catch { self.error = error.localizedDescription }
    }
    deinit { task?.cancel() }
    func connect() {
        do {
            if !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try OnlineServiceKeychain.save(tokenInput, account: Self.tokenAccount); tokenInput = ""; hasSavedToken = true
            }
            guard hasSavedToken else { throw OnlineServiceError.message("Enter a GitHub token with repository metadata and Actions read access.") }
            refreshRepositories()
        } catch { self.error = error.localizedDescription }
    }
    func disconnect() {
        cancel()
        do { try OnlineServiceKeychain.remove(Self.tokenAccount); hasSavedToken = false; repositories = []; runs = []; fetchedAt = nil; coverage = ""; repositoryCoverage = ""; selectedRepository = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func refreshRepositories() {
        begin { [client] token in
            let result = try await client.repositories(token: token)
            return .repositories(result.items, result.limited)
        }
    }
    func refreshRuns() {
        let repository = selectedRepository
        guard repositories.contains(where: { $0.fullName == repository }) else { error = "Choose a repository returned by GitHub."; return }
        begin { [client] token in
            let result = try await client.runs(repository: repository, token: token)
            return .runs(repository, result.items, result.total)
        }
    }
    private enum Result: Sendable { case repositories([GithubRepository], Bool), runs(String, [GithubWorkflowRun], Int) }
    private func begin(_ operation: @escaping @Sendable (String) async throws -> Result) {
        cancel(); let requestGeneration = generation
        busy = true; error = nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let token = try OnlineServiceKeychain.read(Self.tokenAccount) else { throw OnlineServiceError.message("The saved GitHub token is unavailable. Connect again.") }
                let result = try await operation(token)
                guard !Task.isCancelled, self.generation == requestGeneration else { return }
                switch result {
                case let .repositories(items, limited):
                    self.repositories = items; self.runs = []
                    if !items.contains(where: { $0.fullName == self.selectedRepository }) { self.selectedRepository = items.first?.fullName ?? "" }
                    self.repositoryCoverage = limited ? "Limited to the first 250 owned repositories; other repositories may be omitted." : "\(items.count) owned repositories returned by GitHub."
                    self.coverage = "Choose Refresh Runs to read this repository's workflows."
                case let .runs(repository, items, total):
                    guard self.selectedRepository == repository else { self.busy = false; self.task = nil; return }
                    self.runs = items
                    self.coverage = "\(items.count) of \(total) workflow runs returned.\(total > items.count ? " Limited to 150 recent runs." : "")"
                }
                self.fetchedAt = Date(); self.busy = false; self.task = nil
            } catch {
                guard self.generation == requestGeneration else { return }
                self.busy = false; self.task = nil
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() { generation += 1; task?.cancel(); task = nil; busy = false }
    func selectionChanged() { cancel(); runs = []; fetchedAt = nil; coverage = "Choose Refresh Runs to read this repository's workflows." }
}

@MainActor
struct GithubActionsToolView: View {
    @StateObject private var model = GithubActionsToolModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SecureField("GitHub personal access token", text: $model.tokenInput).textFieldStyle(.roundedBorder)
                Button("Connect") { model.connect() }.disabled(model.busy)
                if model.hasSavedToken { Button("Disconnect") { model.disconnect() } }
            }
            Text("Fine-grained token: repository Metadata and Actions read access. Token stays in this app's Keychain. Requests occur only on Connect or Refresh.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Repository", selection: $model.selectedRepository) {
                    if model.repositories.isEmpty { Text("Connect to load owned repositories").tag("") }
                    ForEach(model.repositories) { Text($0.fullName).tag($0.fullName) }
                }.onChange(of: model.selectedRepository) { _, _ in model.selectionChanged() }
                Button("Refresh Runs") { model.refreshRuns() }.disabled(model.busy || model.selectedRepository.isEmpty)
                Button { model.refreshRepositories() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh owned repositories").disabled(model.busy || !model.hasSavedToken)
            }
            OnlineStatusView(busy: model.busy, error: model.error, cancel: { model.cancel() })
            List(model.runs) { run in
                HStack(alignment: .top) {
                    Image(systemName: run.conclusion == "success" ? "checkmark.circle.fill" : run.conclusion == "failure" ? "xmark.circle.fill" : "clock")
                        .foregroundStyle(run.conclusion == "success" ? .green : run.conclusion == "failure" ? .red : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.name).lineLimit(2)
                        Text("\(run.branch) · \(run.resultLabel) · \(run.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(run.htmlURL) }.buttonStyle(.borderless)
                }
            }.frame(height: 160).overlay {
                if model.runs.isEmpty { Text("Choose a repository and refresh its runs.").font(.caption).foregroundStyle(.secondary).allowsHitTesting(false) }
            }
            if let date = model.fetchedAt { Text("Read \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
            Text(model.coverage).font(.caption2).foregroundStyle(.secondary)
            Text(model.repositoryCoverage).font(.caption2).foregroundStyle(.secondary)
            Text("Read only: no workflow dispatch, cancellation, reruns or repository changes.").font(.caption2).foregroundStyle(.secondary)
        }.padding(12).onDisappear { model.cancel() }
            .background(OrbitNativeToolVisibility(onVisible: {}, onHidden: { model.cancel() }).frame(width: 0, height: 0))
    }
}
