import AppKit
import SwiftUI
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class HUDLifecycleEvaluationTests: XCTestCase {
    @MainActor
    func testFreshServicesAndDisabledLifecycleDoNotStartBackgroundMonitoringOrInterception() {
        let controls = SystemControlsService()
        let devices = DevicesService()
        let status = StatusService()
        let network = NetworkService()
        XCTAssertFalse(controls.enabled)
        XCTAssertNil(controls.hud)
        XCTAssertFalse(devices.isSampling)
        XCTAssertFalse(status.isSampling)
        XCTAssertFalse(network.isSampling)
        XCTAssertFalse(devices.backgroundMonitoring)
        XCTAssertFalse(status.backgroundMonitoring)
        XCTAssertFalse(status.focusConnected)
        XCTAssertFalse(status.requestingFocus)
        XCTAssertEqual(status.focus.authorization, .notConnected)
        XCTAssertFalse(network.backgroundMonitoring)
        XCTAssertTrue(devices.devices.isEmpty)
        XCTAssertTrue(devices.bluetoothDevices.isEmpty)
        XCTAssertNil(network.reading)
        var cleared = 0
        controls.onHUD = { value in XCTAssertNil(value); cleared += 1 }
        controls.disable()
        devices.stop(); devices.shutdown()
        status.stop(); status.shutdown()
        network.stop(); network.shutdown()
        XCTAssertEqual(cleared, 1)
        XCTAssertFalse(controls.enabled)
        XCTAssertFalse(devices.isSampling)
        XCTAssertFalse(status.isSampling)
        XCTAssertFalse(network.isSampling)
        XCTAssertTrue(network.rates.isEmpty)
        XCTAssertNil(network.reading)
    }

    @MainActor
    func testRealHUDAndCompactViewsRenderExplicitLevelFixturesWithoutHardwareChanges() async throws {
        let fixtures: [(String, SystemHUDSnapshot)] = [
            ("volume", try XCTUnwrap(SystemHUDSnapshot(kind: .volume, level: 0.625))),
            ("muted", try XCTUnwrap(SystemHUDSnapshot(kind: .volume, level: 0.5, muted: true))),
            ("brightness", try XCTUnwrap(SystemHUDSnapshot(kind: .brightness, level: 0.25)))
        ]
        XCTAssertEqual(fixtures[0].1.percent, 63)
        for (label, snapshot) in fixtures {
            try await NativeFeatureEvaluation.render(AnyView(SystemHUDCompactView(snapshot: snapshot).padding(12)),
                named: "NotchOrbitPlus-HUD-fixture-\(label).png", size: NSSize(width: 320, height: 64))
        }
        let hud = fixtures[0].1
        let status = LiveNotchStatus(id: "hud-fixture", kind: .hud, title: hud.label,
                                    detail: "\(hud.percent)%", toolID: "hud", progress: hud.level)
        try await NativeFeatureEvaluation.render(AnyView(LiveCompactContent(statuses: [status], hudSnapshot: hud)
            .padding(.horizontal, 12).frame(width: 260, height: 38).background(.black).foregroundStyle(.white)),
            named: "NotchOrbitPlus-Compact-fixture-hud.png", size: NSSize(width: 260, height: 38))
    }
}
