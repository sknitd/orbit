import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NotchCore

enum PlusSupportedPlayer: String, Sendable, CaseIterable, Identifiable {
    case music, spotify, system
    var id: String { rawValue }
    var title: String { switch self { case .music: "Music"; case .spotify: "Spotify"; case .system: "System" } }
    var bundleID: String? { switch self { case .music: "com.apple.Music"; case .spotify: "com.spotify.client"; case .system: nil } }
}

struct PlusPlayerSnapshot: Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let playing: Bool
    let artwork: Data?
    let artworkURL: URL?
    let positionAvailable: Bool
    let playbackStateKnown: Bool
    init(title: String, artist: String, album: String, duration: Double, position: Double, playing: Bool,
         artwork: Data?, artworkURL: URL?, positionAvailable: Bool = true, playbackStateKnown: Bool = true) {
        self.title = title; self.artist = artist; self.album = album; self.duration = duration
        self.position = position; self.playing = playing; self.artwork = artwork; self.artworkURL = artworkURL
        self.positionAvailable = positionAvailable; self.playbackStateKnown = playbackStateKnown
    }
}

private actor OrbitPlayerScripting {
    func read(_ player: PlusSupportedPlayer) throws -> PlusPlayerSnapshot {
        try Task.checkCancellation()
        guard let bundleID = player.bundleID else { throw error("Choose Music or Spotify for public scripting.") }
        let artwork = player == .music
            ? "set cover to missing value\ntry\nset cover to raw data of artwork 1 of current track\nend try"
            : "set cover to artwork url of current track"
        let script = """
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                if player state is stopped then return {"", "", "", 0, 0, "stopped", missing value}
                \(artwork)
                return {name of current track, artist of current track, album of current track, duration of current track, player position, player state as string, cover}
            end tell
        end timeout
        """
        let result = try execute(script)
        let rawDuration = result.atIndex(4)?.doubleValue ?? 0
        let seconds = player == .spotify ? rawDuration / 1_000 : rawDuration
        let duration = seconds.isFinite ? max(0, seconds) : 0
        let rawPosition = result.atIndex(5)?.doubleValue ?? 0
        let position = rawPosition.isFinite ? max(0, rawPosition) : 0
        let cover = result.atIndex(7)
        return PlusPlayerSnapshot(
            title: result.atIndex(1)?.stringValue ?? "", artist: result.atIndex(2)?.stringValue ?? "",
            album: result.atIndex(3)?.stringValue ?? "", duration: duration,
            position: duration > 0 ? min(duration, position) : position,
            playing: result.atIndex(6)?.stringValue == "playing",
            artwork: player == .music ? cover?.data : nil,
            artworkURL: player == .spotify ? cover?.stringValue.flatMap(URL.init(string:)) : nil
        )
    }

    func command(_ command: String, player: PlusSupportedPlayer) throws {
        try Task.checkCancellation()
        guard ["playpause", "previous track", "next track"].contains(command) else { return }
        guard let bundleID = player.bundleID else { throw error("Choose Music or Spotify for public scripting.") }
        _ = try execute("with timeout of 3 seconds\ntell application id \"\(bundleID)\" to \(command)\nend timeout")
    }

    private func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw error("The player script could not be created.") }
        var failure: NSDictionary?
        let result = script.executeAndReturnError(&failure)
        if let failure { throw error(failure[NSAppleScript.errorMessage] as? String ?? "The player could not be contacted. Check Automation access in System Settings.") }
        return result
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "NotchOrbitPlus.NowPlaying", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
final class PlusNowPlayingStore: NSObject, ObservableObject {
    static let shared = PlusNowPlayingStore(defaults: .standard, systemSource: PlusMediaRemoteSource())
    static let backgroundDefaultsKey = "plus.music.background"
    static let lyricsLookupDefaultsKey = "plus.music.lrclibLookup"
    @Published var player: PlusSupportedPlayer = .music {
        didSet { if oldValue != player { disconnect() } }
    }
    @Published private(set) var snapshot: PlusPlayerSnapshot?
    @Published private(set) var artwork: NSImage?
    @Published var artworkMessage: String?
    @Published var error: String?
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var monitoring = false
    @Published private(set) var controlsAvailable = false
    @Published private(set) var sourceMessage: String?
    @Published var backgroundMonitoring = false {
        didSet {
            defaults.set(backgroundMonitoring, forKey: Self.backgroundDefaultsKey)
            reconcileMonitoring()
        }
    }
    @Published var lyrics: [OrbitLRCLine] = []
    @Published var lyricsName: String?
    @Published private(set) var plainLyrics: String?
    @Published private(set) var lyricsMessage: String?
    @Published private(set) var lyricsLoading = false
    @Published var lyricsLookupEnabled = false {
        didSet {
            defaults.set(lyricsLookupEnabled, forKey: Self.lyricsLookupDefaultsKey)
            if !lyricsLookupEnabled { cancelLyricsLookup() }
        }
    }
    private let scripting = OrbitPlayerScripting()
    private let defaults: UserDefaults
    private let systemSource: any PlusSystemMediaSource
    private let lyricsClient: any PlusLyricsLookupClient
    private let artworkClient: any PlusArtworkLoading
    private var lyricsTask: Task<Void, Never>?
    private var lyricsRequestID = UUID()
    private var lyricsTrackKey: String?
    private var importTask: Task<Void, Never>?
    private var importID = UUID()
    private var polling: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var connectionID: UUID?
    private var toolVisible = false
    private var terminated = false
    private var generation = UUID()
    private var sessionID = UUID()
    private var commands: [UUID: Task<Void, Never>] = [:]
    private var artworkKey = ""

    init(defaults: UserDefaults, systemSource: any PlusSystemMediaSource, lyricsClient: any PlusLyricsLookupClient = PlusLRCLyricsClient(),
         artworkClient: any PlusArtworkLoading = PlusSpotifyArtworkClient()) {
        self.defaults = defaults; self.systemSource = systemSource; self.lyricsClient = lyricsClient
        self.artworkClient = artworkClient
        _backgroundMonitoring = Published(initialValue: defaults.bool(forKey: PlusNowPlayingStore.backgroundDefaultsKey))
        _lyricsLookupEnabled = Published(initialValue: defaults.bool(forKey: PlusNowPlayingStore.lyricsLookupDefaultsKey))
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
        // Loading a preference never sends Apple Events or launches a player.
        // A successful Connect is required for this app session.
    }
    @objc private func applicationWillTerminate() { shutdown() }

    func connect() {
        guard !terminated else { return }
        disconnect()
        if let bundleID = player.bundleID,
           !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
            error = "Open \(player.title) first, then connect."
            return
        }
        // The first scripting request, and its Automation grant, occur only
        // after this explicit user control. Polling stops after any denial.
        let id = UUID(); connectionID = id; connecting = true; error = nil
        let chosen = player
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.connectionID == id {
                    self.connecting = false; self.connectionTask = nil; self.connectionID = nil
                }
            }
            do {
                let value = try await self.readSource(chosen)
                try Task.checkCancellation()
                guard self.connectionID == id, !self.terminated, self.player == chosen else { return }
                self.connected = true
                self.accept(value.snapshot, controlsAvailable: value.controlsAvailable)
                self.reconcileMonitoring()
            } catch is CancellationError { return }
            catch { if self.connectionID == id { self.error = error.localizedDescription } }
        }
    }

    func setToolVisible(_ visible: Bool) {
        toolVisible = visible
        if !visible { cancelLyricsLookup() }
        reconcileMonitoring()
    }
    private func readSource(_ chosen: PlusSupportedPlayer) async throws -> (snapshot: PlusPlayerSnapshot?, controlsAvailable: Bool) {
        if chosen == .system {
            let value = try await systemSource.read()
            let snapshot = value.metadata.map {
                PlusPlayerSnapshot(title: $0.title, artist: $0.artist, album: $0.album,
                    duration: $0.duration, position: $0.position, playing: $0.playing,
                    artwork: $0.artwork, artworkURL: nil, positionAvailable: $0.positionAvailable,
                    playbackStateKnown: $0.playbackStateKnown)
            }
            return (snapshot, value.controlsAvailable)
        }
        return (try await scripting.read(chosen), true)
    }
    private func trackKey(_ value: PlusPlayerSnapshot?) -> String? {
        guard let value, !value.title.isEmpty else { return nil }
        return player.rawValue + "\n" + value.title + "\n" + value.artist + "\n" + value.album + "\n" + String(value.duration)
    }
    private func accept(_ value: PlusPlayerSnapshot?, controlsAvailable: Bool) {
        let old = snapshot
        let nextTrack = trackKey(value)
        if let lyricsTrackKey, lyricsTrackKey != nextTrack {
            cancelLyricsLookup(); importID = UUID(); importTask?.cancel(); importTask = nil
            lyrics = []; lyricsName = nil; plainLyrics = nil; lyricsMessage = nil; self.lyricsTrackKey = nil
        }
        snapshot = value; self.controlsAvailable = controlsAvailable
        sourceMessage = player == .system && value == nil
            ? "No system now-playing metadata is available. Start playback and retry; macOS 15.4 and later may restrict MediaRemote. Music and Spotify remain available through public scripting."
            : nil
        let key = (nextTrack ?? "") + "\n" + (value?.artworkURL?.absoluteString ?? "")
        if key != artworkKey {
            artworkTask?.cancel(); artworkTask = nil
            artworkKey = key; artwork = nil; artworkMessage = nil
            if let url = value?.artworkURL, url.scheme?.lowercased() == "https" {
                loadArtwork(url, key: key, generation: generation)
            }
        }
        // Artwork can arrive after the metadata; keep existing art when the
        // framework briefly omits it for an unchanged track.
        if let data = value?.artwork, artwork == nil || old?.artwork != data {
            if let image = NSImage(data: data) { artwork = image; artworkMessage = nil }
        }
    }
    private func reconcileMonitoring() {
        if !terminated, connected, toolVisible || backgroundMonitoring { resume() }
        else { stopPolling() }
    }
    private func resume() {
        guard !terminated, connected, polling == nil else { return }
        let id = generation
        monitoring = true
        polling = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == id { self.polling = nil } }
            while !Task.isCancelled, self.generation == id, self.connected {
                do {
                    if let bundleID = self.player.bundleID,
                       !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
                        throw NSError(domain: "NotchOrbitPlus.NowPlaying", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(self.player.title) is no longer running. Open it and reconnect."])
                    }
                    let value = try await self.readSource(self.player)
                    try Task.checkCancellation()
                    guard self.generation == id else { return }
                    self.accept(value.snapshot, controlsAvailable: value.controlsAvailable)
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError { return }
                catch {
                    guard self.generation == id else { return }
                    self.error = error.localizedDescription; self.disconnect()
                    return
                }
            }
        }
    }

    private func loadArtwork(_ url: URL, key: String, generation id: UUID) {
        artworkTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == id, self.artworkKey == key { self.artworkTask = nil } }
            do {
                let data = try await self.artworkClient.load(url)
                try Task.checkCancellation()
                guard self.generation == id, self.artworkKey == key else { return }
                guard let image = NSImage(data: data) else {
                    self.artworkMessage = "The player's artwork image could not be loaded. Playback controls remain available."
                    return
                }
                self.artwork = image
            } catch is CancellationError { return }
            catch {
                guard self.generation == id, self.artworkKey == key else { return }
                self.artworkMessage = "Artwork unavailable: \(error.localizedDescription)"
            }
        }
    }
    func retryArtwork() { artworkKey = ""; artworkMessage = nil }
    private func stopPolling() {
        generation = UUID(); polling?.cancel(); polling = nil
        monitoring = false
        if artworkTask != nil, artwork == nil { artworkKey = "" }
        artworkTask?.cancel(); artworkTask = nil
    }
    func disconnect() {
        cancelLyricsLookup(); importID = UUID(); importTask?.cancel(); importTask = nil
        sessionID = UUID()
        for command in commands.values { command.cancel() }
        commands.removeAll()
        connectionID = nil; connectionTask?.cancel(); connectionTask = nil; connecting = false
        stopPolling(); connected = false; controlsAvailable = false; sourceMessage = nil
        snapshot = nil; artwork = nil; artworkMessage = nil; artworkKey = ""
        lyrics = []; lyricsName = nil; plainLyrics = nil; lyricsMessage = nil; lyricsTrackKey = nil
    }
    func shutdown() { terminated = true; disconnect() }
    func command(_ command: String) {
        guard !terminated, connected, controlsAvailable, ["playpause", "previous track", "next track"].contains(command) else { return }
        let chosen = player
        let session = sessionID; let id = UUID()
        commands[id] = Task {
            defer { self.commands[id] = nil }
            do {
                if chosen == .system { try await systemSource.command(command) }
                else { try await scripting.command(command, player: chosen) }
            }
            catch is CancellationError { return }
            catch {
                guard self.sessionID == session, self.player == chosen, self.connected else { return }
                self.error = error.localizedDescription
                if chosen != .system { disconnect() }
            }
        }
    }

    private var currentLyricsQuery: CoreLyricsQuery? {
        guard let value = snapshot, !value.title.isEmpty else { return nil }
        return CoreLyricsQuery(title: value.title, artist: value.artist, album: value.album, duration: value.duration)
    }
    var canLookupLyrics: Bool {
        guard !terminated, connected, lyricsLookupEnabled, !lyricsLoading, let query = currentLyricsQuery else { return false }
        return (try? query.requestURL()) != nil
    }
    func lookupLyrics() {
        guard canLookupLyrics, let query = currentLyricsQuery, let track = trackKey(snapshot) else { return }
        importID = UUID(); importTask?.cancel(); importTask = nil
        cancelLyricsLookup()
        let id = UUID(); lyricsRequestID = id; lyricsLoading = true; lyricsTrackKey = track
        lyricsMessage = "Looking up this song on LRCLIB…"
        lyricsTask = Task {
            defer { if self.lyricsRequestID == id { self.lyricsLoading = false; self.lyricsTask = nil } }
            do {
                let result = try await lyricsClient.lookup(query)
                try Task.checkCancellation()
                guard self.lyricsRequestID == id, self.lyricsLookupEnabled, self.trackKey(self.snapshot) == track else { return }
                self.lyrics = result.lines; self.plainLyrics = result.kind == .plain ? result.plainLyrics : nil
                self.lyricsName = "LRCLIB · \(result.title)"
                switch result.kind {
                case .synced: self.lyricsMessage = "Synced lyrics from LRCLIB. Timing and words are supplied by contributors."
                case .plain: self.lyricsMessage = "LRCLIB supplied plain lyrics without synchronized timing."
                case .instrumental: self.lyricsMessage = "LRCLIB marks this track as instrumental."
                }
            } catch is CancellationError { return }
            catch { if self.lyricsRequestID == id { self.lyricsMessage = error.localizedDescription } }
        }
    }
    func cancelLyricsLookup() {
        lyricsRequestID = UUID(); lyricsTask?.cancel(); lyricsTask = nil
        if lyricsLoading { lyricsMessage = "Lyrics lookup cancelled." }
        lyricsLoading = false
    }

    func importLyrics() {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        chooser.allowsMultipleSelection = false
        guard chooser.runModal() == .OK, let url = chooser.url else { return }
        cancelLyricsLookup()
        importID = UUID(); importTask?.cancel()
        let id = importID; let track = trackKey(snapshot)
        importTask = Task {
            defer { if self.importID == id { self.importTask = nil } }
            do {
                let lines = try await Task.detached {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    var data = Data()
                    while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
                        try Task.checkCancellation()
                        guard data.count + chunk.count <= 2_097_152 else { throw CoreLyricsError.oversized }
                        data.append(chunk)
                    }
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw NSError(domain: "NotchOrbitPlus.Lyrics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a UTF-8 LRC file smaller than 2 MB."])
                    }
                    return OrbitLRCParser.parse(text)
                }.value
                try Task.checkCancellation()
                guard self.importID == id, self.trackKey(self.snapshot) == track else { return }
                guard !lines.isEmpty else { error = "This file has no valid LRC timing tags."; return }
                lyrics = lines; lyricsName = url.lastPathComponent; plainLyrics = nil
                lyricsMessage = "Imported local LRC lyrics."; lyricsTrackKey = track; error = nil
            } catch is CancellationError { return }
            catch { if self.importID == id { self.error = error.localizedDescription } }
        }
    }
}

@MainActor
struct NowPlayingToolView: View {
    @StateObject private var model: PlusNowPlayingStore
    init(model: PlusNowPlayingStore = .shared) { _model = StateObject(wrappedValue: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Now Playing").font(.headline)
            Picker("Player", selection: $model.player) {
                ForEach(PlusSupportedPlayer.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(model.connecting)
            if model.player == .system {
                Text("System playback access varies by macOS version. If unavailable, choose Music or Spotify.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(model.connecting ? "Connecting…" : model.connected ? "Reconnect" : "Connect \(model.player.title)", action: model.connect).disabled(model.connecting)
                if model.connected { Button("Disconnect", action: model.disconnect) }
            }
            Toggle("Keep music live while the notch is closed", isOn: $model.backgroundMonitoring)
            Text("Connect a supported player for this app session, then opt in to monitoring outside this tool. Turning this off stops background polling.")
                .font(.caption).foregroundStyle(.secondary)
            if let value = model.snapshot, !value.title.isEmpty {
                HStack(spacing: 12) {
                    if let cover = model.artwork { Image(nsImage: cover).resizable().scaledToFit().frame(width: 64, height: 64) }
                    VStack(alignment: .leading) {
                        Text(value.title).font(.headline)
                        Text(value.artist).foregroundStyle(.secondary)
                        Text(value.album).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if value.positionAvailable, value.duration > 0 { ProgressView(value: min(value.duration, max(0, value.position)), total: value.duration) }
                HStack {
                    Button { model.command("previous track") } label: { Image(systemName: "backward.end.fill") }.help("Previous track")
                    Button { model.command("playpause") } label: { Image(systemName: value.playing ? "pause.fill" : "play.fill") }.help("Play or pause")
                    Button { model.command("next track") } label: { Image(systemName: "forward.end.fill") }.help("Next track")
                }.disabled(!model.controlsAvailable)
                if !value.playbackStateKnown { Text("This player did not report playback state.").font(.caption).foregroundStyle(.secondary) }
                if !model.controlsAvailable { Text("System playback controls are unavailable on this macOS version.").font(.caption).foregroundStyle(.secondary) }
            } else if model.connected, model.player != .system { Text("No track is playing in \(model.player.title).").foregroundStyle(.secondary) }
            if let status = model.sourceMessage { Text(status).font(.caption).foregroundStyle(.secondary) }
            Button("Import synced lyrics (.lrc)", action: model.importLyrics)
            Toggle("Enable LRCLIB lyrics lookup", isOn: $model.lyricsLookupEnabled)
            if model.lyricsLookupEnabled {
                Text("Lookup sends this song's title, artist, album, and duration to lrclib.net. Requests start only when you click Lookup.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Lookup lyrics on LRCLIB", action: model.lookupLyrics).disabled(!model.canLookupLyrics)
                    if model.lyricsLoading { ProgressView().controlSize(.small); Button("Cancel", action: model.cancelLyricsLookup) }
                }
            }
            if !model.lyrics.isEmpty {
                let active = model.snapshot?.positionAvailable == true
                    ? OrbitLRCParser.activeIndex(in: model.lyrics, at: model.snapshot?.position ?? 0) : nil
                Text(model.lyricsName ?? "Imported lyrics").font(.caption).foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.lyrics.enumerated()), id: \.element.id) { index, line in
                                Text(line.text.isEmpty ? "♪" : line.text).foregroundStyle(index == active ? .primary : .secondary)
                                    .fontWeight(index == active ? .semibold : .regular).id(index)
                            }
                        }
                    }.frame(height: 115).onChange(of: active) { _, index in
                        if let index { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }
            if let plain = model.plainLyrics {
                Text(model.lyricsName ?? "Plain lyrics").font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(plain).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 115)
            }
            if let status = model.lyricsMessage { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let status = model.artworkMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
                Button("Retry artwork", action: model.retryArtwork).disabled(!model.connected)
            }
            Text("Music and Spotify use public scripting with Automation consent. System mode uses macOS's private MediaRemote API and can be restricted or changed by Apple. Spotify artwork may load from the player's image URL. Local LRC import works without lyrics network access.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { model.setToolVisible(true) }.onDisappear { model.setToolVisible(false) }
            .background(OrbitNativeToolVisibility(onVisible: { model.setToolVisible(true) }, onHidden: { model.setToolVisible(false) }).frame(width: 0, height: 0))
    }
}
