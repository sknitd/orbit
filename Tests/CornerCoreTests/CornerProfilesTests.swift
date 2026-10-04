import Foundation
import XCTest
@testable import CornerCore

final class CornerProfilesTests: XCTestCase {
    func testSnapshotsAndImportedEnabledSettingsAlwaysDisableMonitoring() throws {
        var armed = CornerSettings.samplePreset; armed.enabled = true
        let profile = CornerProfile(name: " Work ", settings: armed)
        XCTAssertFalse(profile.settings.enabled)
        XCTAssertEqual(try profile.validated().name, "Work")
        let encoded = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var settings = try XCTUnwrap(object["settings"] as? [String: Any]); settings["enabled"] = true; object["settings"] = settings
        let decoded = try JSONDecoder().decode(CornerProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.settings.enabled)
        XCTAssertEqual(decoded.settings.corners, armed.corners)
    }
    func testDefaultArchiveIsEmptyAndNeverOptedIn() throws {
        let archive = try CornerProfilesArchive.defaults.validated()
        XCTAssertTrue(archive.profiles.isEmpty); XCTAssertTrue(archive.rules.isEmpty); XCTAssertTrue(archive.excludedAppIDs.isEmpty)
        XCTAssertNil(archive.activeProfileID); XCTAssertFalse(archive.autoSwitchEnabled)
    }
    func testNamesRespectCharacterByteAndControlBounds() throws {
        XCTAssertEqual(try CornerProfileValidation.name("  Personal  "), "Personal")
        for name in ["", "   ", "one\ntwo", String(repeating: "a", count: 81), String(repeating: "🪐", count: 80)] {
            XCTAssertThrowsError(try CornerProfileValidation.name(name))
        }
        XCTAssertNoThrow(try CornerProfileValidation.name(String(repeating: "a", count: 80)))
    }
    func testArchiveRejectsDuplicateIDsNamesAndMissingReferences() throws {
        let first = CornerProfile(name: "Work", settings: .defaults)
        let sameID = CornerProfile(id: first.id, name: "Other", settings: .defaults)
        XCTAssertThrowsError(try CornerProfilesArchive(profiles: [first, sameID]).validated())
        let sameName = CornerProfile(name: "wórk", settings: .defaults)
        XCTAssertThrowsError(try CornerProfilesArchive(profiles: [first, sameName]).validated())
        XCTAssertThrowsError(try CornerProfilesArchive(profiles: [first], activeProfileID: UUID()).validated())
        XCTAssertThrowsError(try CornerProfilesArchive(profiles: [first], rules: [.init(bundleID: "com.example.App", profileID: UUID())]).validated())
    }
    func testRulesAreOrderedOffByDefaultAndIgnoreOwnApplication() throws {
        let first = CornerProfile(name: "First", settings: .defaults), second = CornerProfile(name: "Second", settings: .samplePreset)
        var archive = CornerProfilesArchive(profiles: [first, second], autoSwitchEnabled: true,
            rules: [.init(bundleID: "com.example.App", profileID: first.id), .init(bundleID: "com.example.App", profileID: second.id, enabled: true)])
        archive = try archive.validated()
        XCTAssertEqual(archive.profile(matching: "com.example.App")?.id, second.id)
        archive.rules[0].enabled = true
        XCTAssertEqual(archive.profile(matching: "com.example.App")?.id, first.id)
        archive.autoSwitchEnabled = false; XCTAssertNil(archive.profile(matching: "com.example.App"))
        XCTAssertNil(archive.profile(matching: "com.sknitd.CornerOrbit"))
        XCTAssertThrowsError(try CornerProfileRule(bundleID: "com.sknitd.CornerOrbit", profileID: first.id, enabled: true).validated(profileIDs: [first.id]))
    }
    func testExcludedApplicationIdentifiersAndRuleCountsAreBounded() throws {
        let profile = CornerProfile(name: "Work", settings: .defaults)
        XCTAssertThrowsError(try CornerProfilesArchive(profiles: [profile], excludedAppIDs: ["com.app;arbitrary"]).validated())
        XCTAssertThrowsError(try CornerProfilesArchive(excludedAppIDs: ["com.sknitd.CornerOrbit"]).validated())
        let many = Set((0..<65).map { "com.example.App\($0)" })
        XCTAssertThrowsError(try CornerProfilesArchive(excludedAppIDs: many).validated())
        let rules = (0..<65).map { _ in CornerProfileRule(bundleID: "com.example.App", profileID: profile.id) }
        XCTAssertThrowsError(try CornerProfilesArchive(profiles: [profile], rules: rules).validated())
    }
    func testImportPreviewMergesWithoutMutationAndRemapsIDAndNameCollisions() throws {
        let existing = CornerProfile(name: "Work", settings: .defaults)
        let incoming = CornerProfile(id: existing.id, name: "work", settings: .samplePreset)
        let replacementID = UUID()
        let bytes = try CornerProfileDocument(profiles: [incoming]).encoded()
        let preview = try CornerProfileImportPreview.prepare(data: bytes, existing: [existing], idGenerator: { replacementID })
        XCTAssertEqual(preview.count, 1); XCTAssertEqual(preview.mergedProfiles.count, 2)
        XCTAssertEqual(preview.mergedProfiles.first, existing)
        XCTAssertEqual(preview.importedProfiles.first?.id, replacementID)
        XCTAssertEqual(preview.importedProfiles.first?.name, "work (2)")
        XCTAssertFalse(try XCTUnwrap(preview.importedProfiles.first).settings.enabled)
        XCTAssertEqual(preview.renamedProfiles, ["work → work (2)"])
    }
    func testImportDocumentCannotCarryLocalOptInsAndPreservesActualActionArguments() throws {
        var settings = CornerSettings.defaults
        settings.corners[.topLeft]?.bindings[.singleClick] = .init(kind: .openURL, url: "https://example.com/search?q=actual")
        settings.corners[.bottomRight]?.bindings[.doubleClick] = .init(kind: .openApplication, bundleID: "com.example.Custom")
        let profile = CornerProfile(name: "Reviewed", settings: settings)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: CornerProfileDocument(profiles: [profile]).encoded()) as? [String: Any])
        raw["autoSwitchEnabled"] = true; raw["automationEnabled"] = true; raw["excludedAppIDs"] = ["com.example.Untrusted"]
        let preview = try CornerProfileImportPreview.prepare(data: JSONSerialization.data(withJSONObject: raw), existing: [])
        XCTAssertEqual(preview.importedProfiles.first?.settings.corners[.topLeft]?.action(for: .singleClick).url, "https://example.com/search?q=actual")
        XCTAssertEqual(preview.importedProfiles.first?.settings.corners[.bottomRight]?.action(for: .doubleClick).bundleID, "com.example.Custom")
        XCTAssertFalse(try XCTUnwrap(preview.importedProfiles.first).settings.enabled)
    }
    func testImportRejectsOversizeUnsupportedAndInvalidDataWithoutPartialMerge() throws {
        XCTAssertThrowsError(try CornerProfileDocument.decode(Data(repeating: 32, count: CornerProfileValidation.maximumBytes + 1)))
        XCTAssertThrowsError(try CornerProfileDocument.decode(Data("{broken".utf8)))
        XCTAssertThrowsError(try CornerProfileDocument.decode(Data("{\"schemaVersion\":99,\"profiles\":[]}".utf8)))
        let many = (0..<32).map { CornerProfile(name: "Profile \($0)", settings: .defaults) }
        let one = try CornerProfileDocument(profiles: [.init(name: "Extra", settings: .defaults)]).encoded()
        XCTAssertThrowsError(try CornerProfileImportPreview.prepare(data: one, existing: many))
    }
    func testCollisionGeneratorCannotLoopForeverOrOverwriteAnExistingProfile() throws {
        let existing = CornerProfile(name: "Work", settings: .defaults)
        let bytes = try CornerProfileDocument(profiles: [existing]).encoded()
        XCTAssertThrowsError(try CornerProfileImportPreview.prepare(data: bytes, existing: [existing], idGenerator: { existing.id }))
    }
}
