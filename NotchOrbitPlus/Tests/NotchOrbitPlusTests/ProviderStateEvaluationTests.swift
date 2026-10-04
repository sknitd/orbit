import AppKit
import SwiftUI
import XCTest
import NotchCore
@testable import NotchOrbitPlus

private actor EvaluationProviderResponse {
    private(set) var calls = 0
    let bytes: Data
    let delay: Duration
    init(bytes: Data = Data(), delay: Duration = .zero) { self.bytes = bytes; self.delay = delay }
    func load(_ request: URLRequest) async throws -> Data {
        calls += 1
        // Deliberately return even after cancellation to exercise the store's publication guard.
        if delay > .zero { try? await Task.sleep(for: delay) }
        return bytes
    }
}

final class ProviderStateEvaluationTests: XCTestCase {
    @MainActor
    func testPackageSemanticAndWrongTypedOriginalsArePreservedThenBackedUpOnExplicitAdd() throws {
        let invalid = Data("[{\"number\":\"x\"}]".utf8)
        let duplicate = Data("[{\"number\":\"ABC123\"},{\"number\":\"abc123\"}]".utf8)
        for original: Any in [invalid, duplicate, "wrong property-list type"] {
            let suite = "PackageOriginalPreservation-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let key = "plus.package.references"
            defaults.set(original, forKey: key)
            let service = PackageTrackerService(defaults: defaults, load: { _ in
                XCTFail("Editing a local package reference must not use the network"); throw CancellationError()
            }, readKey: { XCTFail("Editing a reference must not read credentials"); return nil })
            defer { service.shutdown() }
            XCTAssertTrue(service.references.isEmpty); XCTAssertNotNil(service.error)
            assertExactOriginal(original, stored: defaults.object(forKey: key))
            service.setToolVisible(true); service.setToolVisible(false)
            assertExactOriginal(original, stored: defaults.object(forKey: key))
            service.numberInput = "NEW123"; service.add()
            XCTAssertEqual(service.references.map(\.number), ["NEW123"])
            let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(key + ".backup.") }
            XCTAssertEqual(backups.count, 1)
            assertExactOriginal(original, stored: backups.first?.value)
            let saved = try JSONDecoder().decode([PackageReference].self, from: XCTUnwrap(defaults.data(forKey: key)))
            XCTAssertEqual(saved.map(\.number), ["NEW123"])
        }
    }

    @MainActor
    func testTeamSemanticAndWrongTypedOriginalsArePreservedThenBackedUpOnExplicitAdd() throws {
        let invalid = Data("[{\"id\":0,\"name\":\"Invalid team\"}]".utf8)
        let duplicate = Data("[{\"id\":7,\"name\":\"A\"},{\"id\":7,\"name\":\"B\"}]".utf8)
        let team = try JSONDecoder().decode(ProviderSportsTeam.self, from: Data("{\"id\":42,\"name\":\"Fixture team\"}".utf8))
        for original: Any in [invalid, duplicate, "wrong property-list type"] {
            let suite = "SportsOriginalPreservation-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let key = "plus.sports.teams"
            defaults.set(original, forKey: key)
            let service = SportsScoresService(defaults: defaults, load: { _ in
                XCTFail("Editing a team must not use the network"); throw CancellationError()
            }, readKey: { XCTFail("Editing a team must not read credentials"); return nil })
            defer { service.shutdown() }
            XCTAssertTrue(service.teams.isEmpty); XCTAssertNotNil(service.error)
            assertExactOriginal(original, stored: defaults.object(forKey: key))
            service.setToolVisible(true); service.setToolVisible(false)
            assertExactOriginal(original, stored: defaults.object(forKey: key))
            service.add(team)
            XCTAssertEqual(service.teams.map(\.id), [42])
            let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(key + ".backup.") }
            XCTAssertEqual(backups.count, 1)
            assertExactOriginal(original, stored: backups.first?.value)
            let saved = try JSONDecoder().decode([ProviderSportsTeam].self, from: XCTUnwrap(defaults.data(forKey: key)))
            XCTAssertEqual(saved.map(\.id), [42])
        }
    }

    @MainActor
    func testProviderInitializationAndActualViewsNeverReadKeysCalendarOrNetwork() async throws {
        let suite = "ProviderNoImplicitAccess-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let loader = EvaluationProviderResponse()
        var keyReads = 0, calendarReads = 0
        let package = PackageTrackerService(defaults: defaults, load: { try await loader.load($0) }, readKey: { keyReads += 1; return nil })
        let sports = SportsScoresService(defaults: defaults, load: { try await loader.load($0) }, readKey: { keyReads += 1; return nil })
        let travel = TravelStatusService(defaults: defaults, load: { try await loader.load($0) }, readKey: { keyReads += 1; return nil }, readCalendar: { calendarReads += 1; return [] })
        defer { package.shutdown(); sports.shutdown(); travel.shutdown() }
        package.start(); sports.start(); travel.start()
        try await NativeFeatureEvaluation.render(AnyView(PackageTrackerToolView(service: package)), named: "NotchOrbitPlus-Package-fixture-disconnected.png")
        try await NativeFeatureEvaluation.render(AnyView(SportsScoresToolView(service: sports)), named: "NotchOrbitPlus-Sports-fixture-disconnected.png")
        try await NativeFeatureEvaluation.render(AnyView(TravelStatusToolView(service: travel)), named: "NotchOrbitPlus-Travel-fixture-disconnected.png")
        XCTAssertEqual(keyReads, 0); XCTAssertEqual(calendarReads, 0)
        let calls = await loader.calls; XCTAssertEqual(calls, 0)
        XCTAssertNil(package.liveStatus); XCTAssertNil(sports.liveStatus); XCTAssertNil(travel.liveStatus)
        travel.refreshCalendar()
        XCTAssertEqual(calendarReads, 1, "Only the explicit authorized-calendar action reads its injected source")
        XCTAssertEqual(keyReads, 0)
    }

    @MainActor
    func testRefreshImmediatelyHiddenBeforeItsTaskStartsCannotReadAKeyOrStartTransport() async throws {
        let suite = "ProviderEarlyCancellation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let loader = EvaluationProviderResponse()
        var keyReads = 0
        let package = PackageTrackerService(defaults: defaults, load: { try await loader.load($0) }, readKey: { keyReads += 1; return "fixture-key" })
        let sports = SportsScoresService(defaults: defaults, load: { try await loader.load($0) }, readKey: { keyReads += 1; return "fixture-key" })
        let travel = TravelStatusService(defaults: defaults, load: { try await loader.load($0) }, readKey: { keyReads += 1; return "fixture-key" }, readCalendar: { [] })
        defer { package.shutdown(); sports.shutdown(); travel.shutdown() }
        package.numberInput = "ABC123"; package.add()
        let team = try JSONDecoder().decode(ProviderSportsTeam.self, from: Data("{\"id\":42,\"name\":\"Fixture team\"}".utf8)); sports.add(team)
        travel.flightCodeInput = "BA123"
        package.refresh(); package.setToolVisible(false)
        sports.refresh(); sports.setToolVisible(false)
        travel.refreshFlight(); travel.setToolVisible(false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(keyReads, 0)
        let calls = await loader.calls; XCTAssertEqual(calls, 0)
        XCTAssertFalse(package.busy); XCTAssertFalse(sports.busy); XCTAssertFalse(travel.busy)
        XCTAssertTrue(package.trackings.isEmpty); XCTAssertTrue(sports.games.isEmpty); XCTAssertTrue(travel.flights.isEmpty)
        XCTAssertNil(package.error); XCTAssertNil(sports.error); XCTAssertNil(travel.error)
    }

    @MainActor
    func testCanceledLatePackageResponseCannotPublishAndExplicitRefreshRendersRealDecodedFixture() async throws {
        let suite = "ProviderLateCancellation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = Data("{\"meta\":{\"code\":200},\"data\":{\"trackings\":[{\"id\":\"fixture-record\",\"tracking_number\":\"ABC123\",\"slug\":\"fixture-carrier\",\"tag\":\"InTransit\",\"checkpoints\":[{\"message\":\"Fixture checkpoint\"}]}]}}".utf8)
        let loader = EvaluationProviderResponse(bytes: bytes, delay: .milliseconds(100))
        let service = PackageTrackerService(defaults: defaults, load: { try await loader.load($0) }, readKey: { "fixture-key" })
        defer { service.shutdown() }
        service.numberInput = "ABC123"; service.add(); service.liveEnabled = true
        service.refresh()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await loader.calls == 0, ContinuousClock.now < deadline { await Task.yield() }
        let started = await loader.calls; XCTAssertEqual(started, 1)
        service.setToolVisible(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(service.trackings.isEmpty); XCTAssertNil(service.fetchedAt); XCTAssertNil(service.liveStatus)
        XCTAssertFalse(service.busy); XCTAssertNil(service.error)
        service.refresh()
        try await NativeFeatureEvaluation.waitUntil("An explicit refresh decodes its injected provider fixture", condition: { !service.busy })
        XCTAssertEqual(service.trackings.map(\.number), ["ABC123"])
        XCTAssertEqual(service.trackings.first?.checkpoint, "Fixture checkpoint")
        XCTAssertEqual(service.liveStatus?.kind, .package)
        try await NativeFeatureEvaluation.render(AnyView(PackageTrackerToolView(service: service)),
            named: "NotchOrbitPlus-Package-fixture-provider-response.png")
    }

    private func assertExactOriginal(_ original: Any, stored: Any?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue((stored as? NSObject)?.isEqual(original) == true, "The exact original property-list value must remain recoverable", file: file, line: line)
    }
}
