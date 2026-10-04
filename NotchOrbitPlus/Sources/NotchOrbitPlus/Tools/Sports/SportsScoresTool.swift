import SwiftUI
import NotchCore

@MainActor
final class SportsScoresService: ObservableObject {
    static let shared = SportsScoresService()
    static let keyAccount = "api-sports-football"
    @Published var keyInput = ""
    @Published var teamQuery = ""
    @Published private(set) var searchResults: [ProviderSportsTeam] = []
    @Published private(set) var teams: [ProviderSportsTeam] = []
    @Published private(set) var games: [ProviderSportsGame] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var coverage = ""
    @Published var liveEnabled: Bool { didSet { defaults.set(liveEnabled, forKey: "plus.sports.live") } }
    @Published var monitoringEnabled: Bool {
        didSet { defaults.set(monitoringEnabled, forKey: "plus.sports.monitoring"); configureMonitoring(); if !monitoringEnabled && requestIsBackground { cancel() } }
    }
    private let defaults: UserDefaults
    private let load: ProviderReadOnlyHTTPS.Loader
    private let readKey: @MainActor () throws -> String?
    private var job: Task<Void, Never>?, monitoring: Task<Void, Never>?
    private var started = false, requestIsBackground = false
    private var generation = UUID()
    init(defaults: UserDefaults = .standard, load: @escaping ProviderReadOnlyHTTPS.Loader = ProviderReadOnlyHTTPS.load,
         readKey: @escaping @MainActor () throws -> String? = { try OnlineServiceKeychain.read(SportsScoresService.keyAccount) }) {
        self.defaults = defaults; self.load = load; self.readKey = readKey
        liveEnabled = defaults.bool(forKey: "plus.sports.live"); monitoringEnabled = defaults.bool(forKey: "plus.sports.monitoring")
        if let raw = defaults.object(forKey: "plus.sports.teams") {
            do {
                teams = try Self.decodeTeams(raw)
            } catch { self.error = "Could not read saved teams. The original selection is preserved: \(error.localizedDescription)" }
        }
    }
    deinit { job?.cancel(); monitoring?.cancel() }
    func start() { started = true; configureMonitoring() }
    func shutdown() { started = false; monitoring?.cancel(); monitoring = nil; cancel() }
    func setToolVisible(_ visible: Bool) { if !visible && !monitoringEnabled { cancel() } }
    func saveKey() {
        do { try OnlineServiceKeychain.save(keyInput, account: Self.keyAccount); keyInput = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func forgetKey() {
        monitoringEnabled = false; cancel()
        do { try OnlineServiceKeychain.remove(Self.keyAccount); games = []; fetchedAt = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func add(_ team: ProviderSportsTeam) {
        do {
            try team.validate()
            guard teams.count < 8, !teams.contains(where: { $0.id == team.id }) else { throw OnlineServiceError.message("Choose up to eight unique teams.") }
            teams.append(team); try persist(); error = nil; configureMonitoring()
        } catch { self.error = error.localizedDescription }
    }
    func remove(_ team: ProviderSportsTeam) {
        cancel(); teams.removeAll { $0.id == team.id }
        let ids = Set(teams.map(\.id)); games.removeAll { !ids.contains($0.home.id) && !ids.contains($0.away.id) }
        do { try persist(); error = nil; configureMonitoring() } catch { self.error = error.localizedDescription }
    }
    private func persist() throws {
        if let old = defaults.object(forKey: "plus.sports.teams"), (try? Self.decodeTeams(old)) == nil {
            defaults.set(old, forKey: "plus.sports.teams.backup." + UUID().uuidString)
        }
        defaults.set(try JSONEncoder().encode(teams), forKey: "plus.sports.teams")
    }
    private static func decodeTeams(_ raw: Any) throws -> [ProviderSportsTeam] {
        guard let data = raw as? Data, data.count <= 100_000 else { throw OnlineServiceError.message("Saved teams have an unsupported type or size.") }
        let values = try JSONDecoder().decode([ProviderSportsTeam].self, from: data)
        guard values.count <= 8, Set(values.map(\.id)).count == values.count else { throw OnlineServiceError.message("Invalid saved team selection.") }
        try values.forEach { try $0.validate() }; return values
    }
    func searchTeams() {
        let search = teamQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...80).contains(search.count) else { error = "Enter a team name with 3–80 characters."; return }
        begin(background: false) { [load] key in
            let url = try ProviderReadOnlyHTTPS.url(host: "v3.football.api-sports.io", path: "/teams", query: [.init(name: "search", value: search)])
            return .teams(try APIFootballData.teams(try await load(ProviderReadOnlyHTTPS.request(url, key: key, header: "x-apisports-key"))))
        }
    }
    func refresh(background: Bool = false) {
        guard !teams.isEmpty else { error = "Search and choose at least one real provider team first."; return }
        let ids = Set(teams.map(\.id))
        begin(background: background) { [load] key in
            let url = try ProviderReadOnlyHTTPS.url(host: "v3.football.api-sports.io", path: "/fixtures", query: [.init(name: "live", value: "all")])
            let games = try APIFootballData.games(try await load(ProviderReadOnlyHTTPS.request(url, key: key, header: "x-apisports-key")))
            return .games(games.filter { ids.contains($0.home.id) || ids.contains($0.away.id) })
        }
    }
    private enum Result: Sendable { case teams([ProviderSportsTeam]), games([ProviderSportsGame]) }
    private func begin(background: Bool, operation: @escaping @Sendable (String) async throws -> Result) {
        if background && busy { return }
        cancel(); busy = true; error = nil; requestIsBackground = background
        let ticket = generation
        job = Task { @MainActor [weak self] in
            guard let self, generation == ticket, !Task.isCancelled else { return }
            defer { if generation == ticket { busy = false; job = nil; requestIsBackground = false } }
            do {
                try Task.checkCancellation()
                guard let key = try readKey() else { throw OnlineServiceError.message("Save your API-FOOTBALL key first.") }
                try Task.checkCancellation()
                let result = try await operation(key); try Task.checkCancellation(); guard generation == ticket else { return }
                switch result {
                case .teams(let values): searchResults = values; if values.isEmpty { error = "No team matched the provider search." }
                case .games(let values): games = values; fetchedAt = Date(); coverage = "\(values.count) matches for saved teams from one live-fixture response (maximum 500 provider records)."
                }
            } catch is CancellationError {} catch { if generation == ticket { self.error = error.localizedDescription } }
        }
    }
    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false; requestIsBackground = false }
    private func configureMonitoring() {
        monitoring?.cancel(); monitoring = nil
        guard monitoringEnabled, !teams.isEmpty else { return }
        // The opt-in is sufficient for a visible user toggle; start() restores
        // the same persisted opt-in at launch without enabling it implicitly.
        monitoring = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                self?.refresh(background: true)
            }
        }
    }
    var liveStatus: LiveNotchStatus? {
        guard liveEnabled, let fetchedAt, Date().timeIntervalSince(fetchedAt) <= 360,
              let game = games.first(where: \.isInProgress) else { return nil }
        return LiveNotchStatus(id: "sports-\(game.id)", kind: .sports, title: "\(game.home.name) \(game.scoreText) \(game.away.name)",
                               detail: "\(game.statusLabel)\(game.elapsed.map { " · \($0)′" } ?? "") · read \(fetchedAt.formatted(date: .omitted, time: .shortened))", toolID: "sportsScores")
    }
}

@MainActor
struct SportsScoresToolView: View {
    @ObservedObject private var service: SportsScoresService
    init(service: SportsScoresService = .shared) { _service = ObservedObject(wrappedValue: service) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { SecureField("API-FOOTBALL / API-SPORTS key", text: $service.keyInput); Button("Save Key") { service.saveKey() }; Button("Disconnect") { service.forgetKey() } }
            HStack { TextField("Search team", text: $service.teamQuery); Button("Search Teams") { service.searchTeams() }.disabled(service.busy); Button("Refresh Scores") { service.refresh() }.disabled(service.busy) }
            if !service.searchResults.isEmpty {
                ScrollView(.horizontal) {
                    HStack { ForEach(service.searchResults) { team in Button("Add \(team.name)") { service.add(team) }.disabled(service.teams.contains { $0.id == team.id }) } }
                }.frame(height: 28)
            }
            ScrollView(.horizontal) {
                HStack { ForEach(service.teams) { team in Button { service.remove(team) } label: { Label(team.name, systemImage: "xmark.circle") }.help("Remove team") } }
            }.frame(height: 28)
            OnlineStatusView(busy: service.busy, error: service.error, cancel: { service.cancel() })
            List(service.games) { game in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(game.home.name) \(game.scoreText) \(game.away.name)").font(.callout.weight(.medium))
                    Text("\(game.statusLabel)\(game.elapsed.map { " · \($0)′" } ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(height: 130).overlay {
                if service.games.isEmpty { Text("Refresh to read games for your chosen teams. No reported live game is a valid result.").font(.caption).foregroundStyle(.secondary).padding().allowsHitTesting(false) }
            }
            Toggle("Show freshly read in-progress game in closed notch", isOn: $service.liveEnabled).font(.caption)
            Toggle("Monitor scores in the background every 5 minutes", isOn: $service.monitoringEnabled).font(.caption)
            Text(service.coverage).font(.caption2).foregroundStyle(.secondary)
            if let date = service.fetchedAt { Text("Last provider read \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
            Text("Football via API-SPORTS. No default teams or launch-time request; background monitoring requires this toggle and uses your provider quota.").font(.caption2).foregroundStyle(.secondary)
            Link("API-FOOTBALL documentation", destination: URL(string: "https://www.api-football.com/documentation-v3")!).font(.caption2)
        }.padding(12).onDisappear { service.setToolVisible(false) }
            .background(OrbitNativeToolVisibility(onVisible: {}, onHidden: { service.setToolVisible(false) }).frame(width: 0, height: 0))
    }
}
