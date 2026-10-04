import Foundation
import SwiftUI
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class PlanningServiceEvaluationTests: XCTestCase {
    @MainActor
    func testCurrencyReadsOnlyAfterRefreshAndRendersDatedCrossRates() async throws {
        let fixture = CurrencyResponseFixture(body: fxData(date: "2026-10-02", euro: 0.8, sterling: 0.6))
        let store = CurrencyConverterToolStore(load: { try await fixture.load($0) })
        defer { store.cancel() }
        XCTAssertNil(store.rates)
        XCTAssertNil(store.result.value)
        try await NativeFeatureEvaluation.render(AnyView(CurrencyConverterToolView(store: store)),
            named: "NotchOrbitPlus-Currency-fixture-unrefreshed.png")
        let initialRequests = await fixture.requests
        XCTAssertTrue(initialRequests.isEmpty, "View construction and appearance must not fetch rates")
        store.refresh()
        try await NativeFeatureEvaluation.waitUntil("Fixture rates finished") { !store.busy }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.host, "api.frankfurter.dev")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests.first), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "base", value: "USD")])
        XCTAssertEqual(store.rates?.rateDate, "2026-10-02")
        XCTAssertNotNil(store.fetchedAt)
        store.input = "100"; store.from = "EUR"; store.to = "GBP"
        XCTAssertEqual(store.result.value, Decimal(75))
        store.swap()
        XCTAssertEqual(store.from, "GBP")
        XCTAssertEqual(store.to, "EUR")
        XCTAssertEqual(store.result.value, Decimal(100))
        try await NativeFeatureEvaluation.render(AnyView(CurrencyConverterToolView(store: store)),
            named: "NotchOrbitPlus-Currency-fixture-dated-rates.png")
        let finalRequests = await fixture.requests
        XCTAssertEqual(finalRequests.count, 1, "Conversion and rendering stay local")
    }

    @MainActor
    func testCancelledOlderCurrencyReadCannotOverwriteNewerRates() async throws {
        let fixture = CurrencyResponseFixture(body: fxData(date: "2026-10-01", euro: 0.8, sterling: 0.6), blocked: true)
        let store = CurrencyConverterToolStore(load: { try await fixture.load($0) })
        defer { store.cancel() }
        store.refresh()
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(3))
        while await fixture.requests.isEmpty, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let oldRequests = await fixture.requests
        XCTAssertEqual(oldRequests.count, 1)
        await fixture.replace(body: fxData(date: "2026-10-02", euro: 0.9, sterling: 0.7), blocked: false)
        store.refresh()
        try await NativeFeatureEvaluation.waitUntil("Newer FX response finished") { !store.busy }
        XCTAssertEqual(store.rates?.rateDate, "2026-10-02")
        await fixture.releasePending()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(store.busy)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.rates?.rateDate, "2026-10-02")
        XCTAssertEqual(store.rates?.ratesPerUSD["EUR"], Decimal(string: "0.9"))
    }

    @MainActor
    func testWorldClockMalformedPreferencesRequireBackupBeforeEditingAndRealRowsRender() async throws {
        let suite = "WorldClockEvaluation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = ["America/New_York", "not/a/timezone"]
        defaults.set(original, forKey: WorldClockToolModel.zonesKey)
        var changes = 0
        let model = WorldClockToolModel(defaults: defaults, settingsDidChange: { changes += 1 })
        defer { model.stop() }
        XCTAssertTrue(model.malformedPreferences)
        XCTAssertTrue(model.zoneIDs.isEmpty)
        model.add("Europe/London")
        XCTAssertEqual(changes, 0)
        XCTAssertThrowsError(try model.applySyncedZoneIDs(["Europe/London"]))
        XCTAssertEqual(defaults.stringArray(forKey: WorldClockToolModel.zonesKey), original)
        model.resetMalformedZonesWithBackup()
        let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(WorldClockToolModel.zonesKey + ".backup.") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(backups.values.first as? [String], original)
        model.add("Europe/London"); model.add("Asia/Tokyo")
        let beforeDuplicate = changes
        model.add("Asia/Tokyo")
        XCTAssertEqual(changes, beforeDuplicate)
        XCTAssertEqual(model.zoneIDs, ["Europe/London", "Asia/Tokyo"])
        XCTAssertEqual(try model.exportSyncZoneIDs(), model.zoneIDs)
        try await NativeFeatureEvaluation.render(AnyView(WorldClockToolView(model: model)),
            named: "NotchOrbitPlus-WorldClock-fixture-saved-zones.png")
        model.stop()
        let stoppedTime = model.now
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(model.now, stoppedTime, "Hidden clock has no surviving one-second ticker")
        let restored = WorldClockToolModel(defaults: defaults, settingsDidChange: {})
        XCTAssertEqual(restored.zoneIDs, model.zoneIDs)
        restored.stop()
    }

    @MainActor
    func testNativeFocusCompletionPersistsDeadlineHistoryOnceAndRendersRealStats() async throws {
        let suite = "FocusHistoryEvaluation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "focus.sound")
        let now = Date()
        var seed = FocusTimer()
        seed.start(minutes: 25, at: now.addingTimeInterval(-3_600))
        XCTAssertEqual(seed.finishIfDue(at: now.addingTimeInterval(-2_000)), .focus)
        seed.start(minutes: 5, phase: .rest, at: now.addingTimeInterval(-1_500))
        XCTAssertEqual(seed.finishIfDue(at: now.addingTimeInterval(-1_000)), .rest)
        defaults.set(try JSONEncoder().encode(seed), forKey: "focus.timer")
        let service = FocusTimerService(defaults: defaults)
        defer { service.shutdown() }
        XCTAssertEqual(service.timer.history.count, 1)
        service.focusMinutes = 1
        service.start()
        let deadline = try XCTUnwrap(service.timer.deadline)
        service.update(at: deadline.addingTimeInterval(120))
        service.update(at: deadline.addingTimeInterval(121))
        XCTAssertEqual(service.timer.completedSessions, 2)
        XCTAssertEqual(service.timer.history.count, 2)
        XCTAssertEqual(service.timer.history.last?.finishedAt, deadline)
        XCTAssertEqual(service.timer.history.last?.duration, 60)
        service.shutdown()
        let saved = try XCTUnwrap(defaults.data(forKey: "focus.timer"))
        XCTAssertEqual(try JSONDecoder().decode(FocusTimer.self, from: saved).history, service.timer.history)
        let restored = FocusTimerService(defaults: defaults)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.timer.history, service.timer.history)
        try await NativeFeatureEvaluation.render(AnyView(FocusStatsToolView(service: restored)),
            named: "NotchOrbitPlus-FocusStats-fixture-completed-history.png")
    }

    @MainActor
    func testMalformedFocusHistorySurvivesViewingShutdownAndInvalidStartUntilExplicitValidBackup() throws {
        let suite = "FocusHistoryMalformed-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "focus.sound")
        let original = Data("Unrecognized previous focus-history bytes".utf8)
        defaults.set(original, forKey: "focus.timer")
        let service = FocusTimerService(defaults: defaults)
        defer { service.shutdown() }
        XCTAssertNotNil(service.historyError)
        service.persist(); service.shutdown()
        service.focusMinutes = .nan; service.start()
        XCTAssertEqual(defaults.data(forKey: "focus.timer"), original)
        XCTAssertFalse(service.timer.isRunning)
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("focus.timer.backup.") })
        service.focusMinutes = 1; service.start()
        let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("focus.timer.backup.") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(backups.values.first as? Data, original)
        XCTAssertNil(service.historyError)
        XCTAssertTrue(service.timer.isRunning)
        service.stop()
        let replacement = try JSONDecoder().decode(FocusTimer.self, from: XCTUnwrap(defaults.data(forKey: "focus.timer")))
        XCTAssertTrue(replacement.history.isEmpty)
        XCTAssertEqual(replacement.completedSessions, 0)
    }

    private func fxData(date: String, euro: Double, sterling: Double) -> Data {
        Data("{\"base\":\"USD\",\"date\":\"\(date)\",\"rates\":{\"EUR\":\(euro),\"GBP\":\(sterling)}}".utf8)
    }
}

private actor CurrencyResponseFixture {
    private var body: Data
    private var blocked: Bool
    private var pending: [(CheckedContinuation<Data, Never>, Data)] = []
    private(set) var requests: [URL] = []
    init(body: Data, blocked: Bool = false) { self.body = body; self.blocked = blocked }
    func load(_ url: URL) async throws -> Data {
        requests.append(url)
        if !blocked { return body }
        let response = body
        // Deliberately complete even after cancellation to exercise the app's generation guard.
        return await withCheckedContinuation { pending.append(($0, response)) }
    }
    func replace(body: Data, blocked: Bool) { self.body = body; self.blocked = blocked }
    func releasePending() {
        let old = pending; pending = []
        for (continuation, response) in old { continuation.resume(returning: response) }
    }
}
