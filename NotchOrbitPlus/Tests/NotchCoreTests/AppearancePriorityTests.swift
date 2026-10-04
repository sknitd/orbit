import Foundation
import XCTest
@testable import NotchCore

final class AppearancePriorityTests: XCTestCase {
    func testAppearanceRoundTripDefaultsSilentAndRejectsUnknownOrOversizedData() throws {
        let defaults = CoreAppearancePreferences()
        XCTAssertFalse(defaults.dropSound); XCTAssertEqual(defaults.theme, .system); XCTAssertEqual(defaults.accent, .blue)
        let value = CoreAppearancePreferences(theme: .dark, accent: .teal, dropSound: true)
        XCTAssertEqual(try CoreAppearancePreferences.decode(value.encoded()), value)
        XCTAssertThrowsError(try CoreAppearancePreferences.decode(Data("{\"theme\":\"unknown\",\"accent\":\"blue\",\"dropSound\":false}".utf8)))
        XCTAssertThrowsError(try CoreAppearancePreferences.decode(Data(repeating: 65, count: 4_097)))
    }
    func testCustomPriorityChangesActualSelectionWhileDefaultRetainsExistingRelativeOrder() throws {
        let kinds = LiveNotchKind.allCases
        let values = kinds.map { LiveNotchStatus(id: $0.rawValue, kind: $0, title: $0.title, toolID: "fileActions") }
        XCTAssertEqual(LiveNotchSelection.ordered(values).map(\.kind), LiveNotchKind.defaultOrder)
        let order: [LiveNotchKind] = [.music] + LiveNotchKind.defaultOrder.filter { $0 != .music }
        let configuration = LiveNotchPriorityConfiguration(order: order)
        XCTAssertEqual(try LiveNotchPriorityConfiguration.decode(configuration.encoded()), configuration)
        XCTAssertEqual(LiveNotchSelection.ordered(values, priorityOrder: order).first?.kind, .music)
        XCTAssertThrowsError(try LiveNotchPriorityConfiguration(order: [.music, .music]).encoded())
        XCTAssertEqual(LiveNotchSelection.ordered(values, priorityOrder: [.music, .music]).first?.kind, .processing)
    }
    func testPortableSettingsValidateZonesAndPriorityAndExcludeMacConfiguration() throws {
        let value = SyncSharedSettings(appearance: .init(theme: .dark, accent: .purple), livePriority: .init(), worldZoneIDs: ["Europe/Berlin", "America/New_York"])
        try value.validate()
        XCTAssertEqual(try JSONDecoder().decode(SyncSharedSettings.self, from: JSONEncoder().encode(value)), value)
        var invalid = value; invalid.worldZoneIDs = ["Europe/Berlin", "Europe/Berlin"]; XCTAssertThrowsError(try invalid.validate())
        invalid = value; invalid.worldZoneIDs = ["not/a-zone"]; XCTAssertThrowsError(try invalid.validate())
        invalid = value; invalid.livePriority = .init(order: [.processing]); XCTAssertThrowsError(try invalid.validate())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["toolOrder", "hiddenToolIDs", "openMode", "hoverDelay", "appearance", "livePriority", "worldZoneIDs"])
    }
}
