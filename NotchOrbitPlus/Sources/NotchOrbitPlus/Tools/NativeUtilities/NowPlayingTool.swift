import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NotchCore

private enum OrbitSupportedPlayer: String, Sendable, CaseIterable, Identifiable {
    case music, spotify
    var id: String { rawValue }
    var title: String { self == .music ? "Music" : "Spotify" }
    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
}

private struct OrbitPlayerSnapshot: Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let playing: Bool
    let artwork: Data?
    let artworkURL: URL?
}

private actor OrbitPlayerScripting {
    func read(_ player: OrbitSupportedPlayer) throws -> OrbitPlayerSnapshot {
        let artwork = player == .music
            ? "set cover to missing value\ntry\nset cover to raw data of artwork 1 of current track\nend try"
            : "set cover to artwork url of current track"
        let script = """
        with timeout of 3 seconds
            tell application id "\(player.bundleID)"
                if player state is stopped then return {"", "", "", 0, 0, "stopped", missing value}
                \(artwork)
                return {name of current track, artist of current track, album of current track, duration of current track, player position, player state as string, cover}
            end tell
        end timeout
        """
        let result = try execute(script)
        let duration = result.atIndex(4)?.doubleValue ?? 0
        let cover = result.atIndex(7)
        return OrbitPlayerSnapshot(
            title: result.atIndex(1)?.stringValue ?? "", artist: result.atIndex(2)?.stringValue ?? "",
            album: result.atIndex(3)?.stringValue ?? "", duration: player == .spotify ? duration / 1_000 : duration,
            position: result.atIndex(5)?.doubleValue ?? 0,
            playing: result.atIndex(6)?.stringValue == "playing",
            artwork: player == .music ? cover?.data : nil,
            artworkURL: player == .spotify ? cover?.stringValue.flatMap(URL.init(string:)) : nil
        )
    }

    func command(_ command: String, player: OrbitSupportedPlayer) throws {
        guard ["playpause", "previous track", "next track"].contains(command) else { return }
        _ = try execute("with timeout of 3 seconds\ntell application id \"\(player.bundleID)\" to \(command)\nend timeout")
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
private final class OrbitNowPlayingModel: ObservableObject {
    @Published var player: OrbitSupportedPlayer = .music
    @Published var snapshot: OrbitPlayerSnapshot?
    @Published var artwork: NSImage?
    @Published var error: String?
    @Published var connected = false
    @Published var lyrics: [OrbitLRCLine] = []
    @Published var lyricsName: String?
    private let scripting = OrbitPlayerScripting()
    private var polling: Task<Void, Never>?
    private var generation = UUID()
    private var artworkKey = ""

    func connect() {
        stop()
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == player.bundleID }) else {
            error = "Open \(player.title) first, then connect."
            return
        }
        // The first scripting request, and its Automation grant, occur only
        // after this explicit user control. Polling stops after any denial.
        connected = true; error = nil; snapshot = nil; artwork = nil; artworkKey = ""
        resume()
    }

    func resume() {
        guard connected, polling == nil else { return }
        let id = UUID(); generation = id
        polling = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == id { self.polling = nil } }
            while !Task.isCancelled, self.generation == id, self.connected {
                do {
                    guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == self.player.bundleID }) else {
                        throw NSError(domain: "NotchOrbitPlus.NowPlaying", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(self.player.title) is no longer running. Open it and reconnect."])
                    }
                    let value = try await self.scripting.read(self.player)
                    try Task.checkCancellation()
                    guard self.generation == id else { return }
                    self.snapshot = value
                    let key = value.title + "\n" + value.artist + "\n" + (value.artworkURL?.absoluteString ?? value.album)
                    if key != self.artworkKey {
                        self.artworkKey = key; self.artwork = nil
                        if let data = value.artwork { self.artwork = NSImage(data: data) }
                        else if let url = value.artworkURL, url.scheme?.lowercased() == "https" {
                            var request = URLRequest(url: url); request.timeoutInterval = 6
                            let (data, response) = try await URLSession.shared.data(for: request)
                            if (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4_194_304,
                               self.generation == id { self.artwork = NSImage(data: data) }
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError { return }
                catch {
                    guard self.generation == id else { return }
                    self.error = error.localizedDescription; self.connected = false
                    return
                }
            }
        }
    }

    func stop() { generation = UUID(); polling?.cancel(); polling = nil }
    func disconnect() { stop(); connected = false; snapshot = nil; artwork = nil }
    func command(_ command: String) {
        guard connected else { return }
        let chosen = player
        Task {
            do { try await scripting.command(command, player: chosen) }
            catch { self.error = error.localizedDescription; disconnect() }
        }
    }

    func importLyrics() {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        chooser.allowsMultipleSelection = false
        guard chooser.runModal() == .OK, let url = chooser.url else { return }
        Task {
            do {
                let lines = try await Task.detached {
                    let data = try Data(contentsOf: url)
                    guard data.count <= 2_097_152, let text = String(data: data, encoding: .utf8) else {
                        throw NSError(domain: "NotchOrbitPlus.Lyrics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a UTF-8 LRC file smaller than 2 MB."])
                    }
                    return OrbitLRCParser.parse(text)
                }.value
                guard !lines.isEmpty else { error = "This file has no valid LRC timing tags."; return }
                lyrics = lines; lyricsName = url.lastPathComponent; error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
struct NowPlayingToolView: View {
    @StateObject private var model = OrbitNowPlayingModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Now Playing").font(.headline)
            Picker("Player", selection: $model.player) {
                ForEach(OrbitSupportedPlayer.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).onChange(of: model.player) { _, _ in model.disconnect() }
            HStack {
                Button(model.connected ? "Reconnect" : "Connect \(model.player.title)", action: model.connect)
                if model.connected { Button("Disconnect", action: model.disconnect) }
            }
            if let value = model.snapshot, !value.title.isEmpty {
                HStack(spacing: 12) {
                    if let cover = model.artwork { Image(nsImage: cover).resizable().scaledToFit().frame(width: 64, height: 64) }
                    VStack(alignment: .leading) {
                        Text(value.title).font(.headline)
                        Text(value.artist).foregroundStyle(.secondary)
                        Text(value.album).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if value.duration > 0 { ProgressView(value: min(value.duration, max(0, value.position)), total: value.duration) }
                HStack {
                    Button { model.command("previous track") } label: { Image(systemName: "backward.end.fill") }.help("Previous track")
                    Button { model.command("playpause") } label: { Image(systemName: value.playing ? "pause.fill" : "play.fill") }.help("Play or pause")
                    Button { model.command("next track") } label: { Image(systemName: "forward.end.fill") }.help("Next track")
                }
            } else if model.connected { Text("No track is playing in \(model.player.title).").foregroundStyle(.secondary) }
            Button("Import synced lyrics (.lrc)", action: model.importLyrics)
            if !model.lyrics.isEmpty {
                let active = OrbitLRCParser.activeIndex(in: model.lyrics, at: model.snapshot?.position ?? 0)
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
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("Public scripting supports Music and Spotify. Other players and automatic lyric fetching are unavailable. Spotify artwork may load from the player's image URL.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { model.resume() }.onDisappear { model.stop() }
            .background(OrbitNativeToolVisibility(onVisible: model.resume, onHidden: model.stop).frame(width: 0, height: 0))
    }
}
