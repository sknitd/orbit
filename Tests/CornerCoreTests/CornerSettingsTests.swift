import Foundation
import XCTest
@testable import CornerCore

final class CornerSettingsTests: XCTestCase {
    func testDefaultsProvideTwentyDisabledBindingsAndPresetNeverEnablesMonitoring() throws {
        let settings = try CornerSettings.defaults.validated()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.corners.count, 4)
        XCTAssertEqual(settings.corners.values.reduce(0) { $0 + $1.bindings.count }, 20)
        XCTAssertTrue(settings.corners.values.allSatisfy { $0.bindings.values.allSatisfy { $0 == .none } })
        let sample = try CornerSettings.samplePreset.validated()
        XCTAssertFalse(sample.enabled)
        XCTAssertEqual(sample.corners[.topLeft]?.action(for: .singleClick).kind, .chromeNewTab)
        XCTAssertTrue(CornerSettings.defaults.corners.values.allSatisfy { $0.bindings.values.allSatisfy { $0 == .none } })
    }
    func testCodableRoundTripRetainsEveryIndependentBindingAndDisplaySelection() throws {
        var settings = CornerSettings.defaults
        settings.enabled = true; settings.enabledDisplayIDs = ["123", "456"]
        settings.modifierRequirement = [.control, .option]
        for (index, corner) in Corner.allCases.enumerated() {
            for (offset, gesture) in CornerGesture.allCases.enumerated() {
                settings.corners[corner]?.bindings[gesture] = .init(kind: .openURL, url: "https://example.com/\(index)/\(offset)?q=kept")
            }
        }
        let bytes = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(CornerSettings.self, from: bytes)
        XCTAssertEqual(decoded, settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let corners = try XCTUnwrap(object["corners"] as? [String: Any])
        XCTAssertEqual(Set(corners.keys), Set(Corner.allCases.map(\.rawValue)))
        let topLeft = try XCTUnwrap(corners["topLeft"] as? [String: Any])
        XCTAssertEqual((topLeft["bindings"] as? [String: Any])?.count, 5)
    }
    func testUnsupportedSchemaAndUnknownCornerOrGestureAreRejected() throws {
        let data = try JSONEncoder().encode(CornerSettings.defaults)
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var future = base; future["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(CornerSettings.self, from: JSONSerialization.data(withJSONObject: future)))
        var badCorner = base
        var corners = try XCTUnwrap(base["corners"] as? [String: Any]); corners["center"] = corners["topLeft"]
        badCorner["corners"] = corners
        XCTAssertThrowsError(try JSONDecoder().decode(CornerSettings.self, from: JSONSerialization.data(withJSONObject: badCorner)))
        var badGesture = base
        var topLeft = try XCTUnwrap(corners["topLeft"] as? [String: Any])
        var bindings = try XCTUnwrap(topLeft["bindings"] as? [String: Any]); bindings["quadrupleClick"] = ["kind": "finder"]
        topLeft["bindings"] = bindings; corners.removeValue(forKey: "center"); corners["topLeft"] = topLeft; badGesture["corners"] = corners
        XCTAssertThrowsError(try JSONDecoder().decode(CornerSettings.self, from: JSONSerialization.data(withJSONObject: badGesture)))
    }
    func testNumericBoundsAndNonfiniteValuesRejectRatherThanSilentlyClamp() throws {
        var valid = CornerSettings(cornerSize: 4, clickInterval: 0.15, dragThreshold: 2, cooldown: 0)
        XCTAssertNoThrow(try valid.validated())
        valid.cornerSize = 128; valid.clickInterval = 1; valid.dragThreshold = 100; valid.cooldown = 5
        XCTAssertNoThrow(try valid.validated())
        for value in [Double.nan, .infinity, -.infinity, 3.99, 128.01] {
            var bad = valid; bad.cornerSize = value; XCTAssertThrowsError(try bad.validated())
        }
        for value in [0.149, 1.001, Double.nan] { var bad = valid; bad.clickInterval = value; XCTAssertThrowsError(try bad.validated()) }
        for value in [1.99, 100.01, Double.infinity] { var bad = valid; bad.dragThreshold = value; XCTAssertThrowsError(try bad.validated()) }
        for value in [-0.01, 5.01, Double.nan] { var bad = valid; bad.cooldown = value; XCTAssertThrowsError(try bad.validated()) }
    }
    func testModifierAndDisplayLimitsAreValidated() throws {
        var value = CornerSettings.defaults
        value.modifierRequirement = .init(rawValue: 128)
        XCTAssertThrowsError(try value.validated())
        value.modifierRequirement = .all; value.enabledDisplayIDs = [""]
        XCTAssertThrowsError(try value.validated())
        value.enabledDisplayIDs = ["display\nspoof"]
        XCTAssertThrowsError(try value.validated())
        value.enabledDisplayIDs = Set((0..<33).map(String.init))
        XCTAssertThrowsError(try value.validated())
        value.enabledDisplayIDs = ["1"]
        XCTAssertNoThrow(try value.validated()); XCTAssertTrue(value.permits(displayID: "1")); XCTAssertFalse(value.permits(displayID: "2"))
    }
    func testCustomActionsTrimNormalizeAndRejectExecutableOrCredentialURLs() throws {
        let good = try CornerAction(kind: .openURL, url: "  HTTPS://EXAMPLE.COM/path?q=hello#anchor  ").validated()
        XCTAssertEqual(good.url, "https://example.com/path?q=hello#anchor")
        for raw in ["javascript:alert(1)", "file:///tmp/run.sh", "data:text/plain,hello", "https://user:password@example.com", "https://example.com:70000", "https://bad host.example/", "https://example.com/\ninjected", "https://example.com\\escape"] {
            XCTAssertThrowsError(try CornerAction(kind: .openURL, url: raw).validated(), raw)
        }
        XCTAssertThrowsError(try CornerAction(kind: .openURL).validated())
        XCTAssertThrowsError(try CornerAction(kind: .openURL, url: "https://example.com", bundleID: "com.apple.finder").validated())
        XCTAssertThrowsError(try CornerAction(kind: .finder, url: "https://example.com").validated())
    }
    func testCustomApplicationRequiresBundleIDAndDirectCodableValidation() throws {
        XCTAssertEqual(try CornerAction(kind: .openApplication, bundleID: " com.apple.TextEdit ").validated().bundleID, "com.apple.TextEdit")
        for raw in ["Finder", "com..app", "com.app; open /tmp", "com.app\nother", String(repeating: "a", count: 256) + ".app"] {
            XCTAssertThrowsError(try CornerAction(kind: .openApplication, bundleID: raw).validated())
        }
        XCTAssertThrowsError(try JSONDecoder().decode(CornerAction.self, from: Data("{\"kind\":\"openURL\",\"url\":\"file:///tmp/executable\"}".utf8)))
        XCTAssertThrowsError(try JSONEncoder().encode(CornerAction(kind: .none, bundleID: "com.app.test")))
    }
    func testDesktopAssistantActionsHaveNoWebsiteFallback() {
        XCTAssertEqual(CornerActionKind.chatGPT.defaultBundleID, "com.openai.chat")
        XCTAssertEqual(CornerActionKind.claude.defaultBundleID, "com.anthropic.claudefordesktop")
        XCTAssertNil(CornerActionKind.chatGPT.defaultURL); XCTAssertNil(CornerActionKind.claude.defaultURL)
        XCTAssertEqual(CornerActionKind.whatsAppWeb.defaultURL?.host, "web.whatsapp.com")
        XCTAssertEqual(Set(CornerActionCatalog.all).count, CornerActionCatalog.all.count)
        XCTAssertTrue(CornerActionCatalog.all.allSatisfy { !$0.title.isEmpty && !$0.systemImage.isEmpty })
    }
}
