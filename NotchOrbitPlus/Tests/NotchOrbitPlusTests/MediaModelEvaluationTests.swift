import Foundation
import SwiftUI
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class MediaModelEvaluationTests: XCTestCase {
    @MainActor
    func testPersistedOptInsAndViewAppearanceNeverConnectOrLookUpLyrics() async throws {
        let suite = "MediaNoImplicitRequests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PlusNowPlayingStore.backgroundDefaultsKey)
        defaults.set(true, forKey: PlusNowPlayingStore.lyricsLookupDefaultsKey)
        let source = MediaModelSourceFixture(reading: reading(knownPlayback: true, controls: true))
        let lyrics = MediaModelLyricsFixture()
        let model = PlusNowPlayingStore(defaults: defaults, systemSource: source, lyricsClient: lyrics)
        defer { model.shutdown() }
        model.player = .system
        model.setToolVisible(true)
        model.command("playpause"); model.lookupLyrics()
        try await NativeFeatureEvaluation.render(AnyView(ScrollView { NowPlayingToolView(model: model).padding(18) }),
            named: "NotchOrbitPlus-Media-fixture-unconnected.png")
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.connecting)
        XCTAssertFalse(model.monitoring)
        let reads = await source.readCount
        let commands = await source.commands
        let lookups = await lyrics.queries
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(lookups.isEmpty)
    }

    @MainActor
    func testMissingPlaybackStateAndControlsRemainExplicitAndLyricsRequireSeparateAction() async throws {
        let suite = "MediaUnavailableControls-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = MediaModelSourceFixture(reading: reading(knownPlayback: false, controls: false))
        let lyrics = MediaModelLyricsFixture()
        let model = PlusNowPlayingStore(defaults: defaults, systemSource: source, lyricsClient: lyrics)
        defer { model.shutdown() }
        model.player = .system; model.connect()
        try await NativeFeatureEvaluation.waitUntil("Injected system metadata connected") { model.connected }
        let snapshot = try XCTUnwrap(model.snapshot)
        XCTAssertFalse(snapshot.playbackStateKnown)
        XCTAssertFalse(snapshot.positionAvailable)
        XCTAssertFalse(model.controlsAvailable)
        model.command("playpause")
        model.lyricsLookupEnabled = true
        let beforeLookup = await lyrics.queries
        XCTAssertTrue(beforeLookup.isEmpty, "Enabling lyrics and accepting a song does not request lyrics")
        model.lookupLyrics()
        try await NativeFeatureEvaluation.waitUntil("Explicit fixture lyrics finished") { !model.lyricsLoading }
        let queries = await lyrics.queries
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries.first?.title, "Native fixture song")
        XCTAssertEqual(model.lyrics.map(\.text), ["Fixture first line", "Fixture second line"])
        let commands = await source.commands
        XCTAssertTrue(commands.isEmpty, "Unavailable controls cannot send a command")
        try await NativeFeatureEvaluation.render(AnyView(ScrollView { NowPlayingToolView(model: model).padding(18) }),
            named: "NotchOrbitPlus-Media-fixture-restricted-controls.png", size: NSSize(width: 560, height: 680))
        let finalQueries = await lyrics.queries
        XCTAssertEqual(finalQueries.count, 1, "Rendering contributor lyrics does not refresh them")
    }

    @MainActor
    func testHiddenOptOutStopsPollingAndShutdownInvalidatesConnectedSession() async throws {
        let suite = "MediaHiddenLifecycle-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = MediaModelSourceFixture(reading: reading(knownPlayback: true, controls: true))
        let lyrics = MediaModelLyricsFixture()
        let model = PlusNowPlayingStore(defaults: defaults, systemSource: source, lyricsClient: lyrics)
        defer { model.shutdown() }
        model.player = .system; model.connect()
        try await NativeFeatureEvaluation.waitUntil("Fixture player connected") { model.connected }
        XCTAssertFalse(model.monitoring)
        model.setToolVisible(true)
        XCTAssertTrue(model.monitoring)
        try await waitForReads(source, atLeast: 2)
        model.setToolVisible(false)
        XCTAssertFalse(model.monitoring)
        let hiddenReads = await source.readCount
        try await Task.sleep(for: .milliseconds(1_100))
        let stoppedReads = await source.readCount
        XCTAssertEqual(stoppedReads, hiddenReads)
        model.backgroundMonitoring = true
        XCTAssertTrue(model.monitoring)
        try await waitForReads(source, atLeast: hiddenReads + 1)
        let backgroundReads = await source.readCount
        XCTAssertGreaterThan(backgroundReads, hiddenReads)
        model.command("playpause")
        try await Task.sleep(for: .milliseconds(50))
        let commands = await source.commands
        XCTAssertEqual(commands, ["playpause"])
        model.backgroundMonitoring = false
        XCTAssertFalse(model.monitoring)
        model.shutdown(); model.connect(); model.setToolVisible(true)
        XCTAssertFalse(model.connected)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.monitoring)
        let shutdownReads = await source.readCount
        try await Task.sleep(for: .milliseconds(100))
        let finalReads = await source.readCount
        XCTAssertEqual(finalReads, shutdownReads)
        let lookups = await lyrics.queries
        XCTAssertTrue(lookups.isEmpty)
    }

    private func reading(knownPlayback: Bool, controls: Bool) -> PlusMediaRemoteReading {
        let fields = CoreSystemMediaFields(title: "Native fixture song", artist: "Fixture artist", album: "Fixture album",
            duration: 180, elapsed: knownPlayback ? 30 : nil, playbackRate: knownPlayback ? 1 : nil)
        return PlusMediaRemoteReading(metadata: CoreSystemMediaReading(fields: fields,
            playing: knownPlayback ? true : nil, now: Date()), controlsAvailable: controls)
    }

    @MainActor
    private func waitForReads(_ source: MediaModelSourceFixture, atLeast count: Int) async throws {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(3))
        while await source.readCount < count, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let actual = await source.readCount
        XCTAssertGreaterThanOrEqual(actual, count)
    }
}

private actor MediaModelSourceFixture: PlusSystemMediaSource {
    private let reading: PlusMediaRemoteReading
    private(set) var readCount = 0
    private(set) var commands: [String] = []
    init(reading: PlusMediaRemoteReading) { self.reading = reading }
    func read() async throws -> PlusMediaRemoteReading { readCount += 1; return reading }
    func command(_ command: String) async throws { commands.append(command) }
}

private actor MediaModelLyricsFixture: PlusLyricsLookupClient {
    private(set) var queries: [CoreLyricsQuery] = []
    func lookup(_ query: CoreLyricsQuery) async throws -> CoreLyricsResult {
        queries.append(query)
        let data = try JSONSerialization.data(withJSONObject: [
            "id": 42, "trackName": query.title, "artistName": query.artist, "albumName": query.album,
            "duration": query.duration, "instrumental": false,
            "syncedLyrics": "[00:05.00]Fixture first line\n[00:20.00]Fixture second line"
        ])
        return try CoreLyricsResult.decode(data, for: query)
    }
}
