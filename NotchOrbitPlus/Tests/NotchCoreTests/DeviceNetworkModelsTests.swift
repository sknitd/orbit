import Foundation
import XCTest
@testable import NotchCore

final class DeviceNetworkModelsTests: XCTestCase {
    func testFocusRequiresAuthorizationAndPreservesUnknownSharedState() {
        for state in SystemFocusAuthorization.allCases where state != .authorized {
            XCTAssertNil(SystemFocusSnapshot(authorization: state, isFocused: true).isFocused)
        }
        XCTAssertNil(SystemFocusSnapshot(authorization: .authorized).isFocused)
        XCTAssertEqual(SystemFocusSnapshot(authorization: .authorized, isFocused: false).isFocused, false)
        let focus = SystemFocusSnapshot(authorization: .authorized, isFocused: true)
        let reading = SystemStatusSnapshot(inputDeviceName: nil, inputDeviceIsRunning: nil,
                                           cameraInUseByAnotherApplication: nil, cameraStatus: "Unavailable", focus: focus)
        XCTAssertEqual(reading.focusIsActive, true)
        XCTAssertEqual(reading.focus.authorization, .authorized)
    }
    func testOnlyReportedValidBatteryValuesBecomePercentages() {
        XCTAssertEqual(SystemDeviceSnapshot.batteryPercent(current: 37, maximum: 50), 74)
        for bad in [Double.nan, .infinity, -1, 101] { XCTAssertNil(SystemDeviceSnapshot.validBatteryPercent(bad)) }
        XCTAssertNil(SystemDeviceSnapshot.batteryPercent(current: 10, maximum: 0))
        XCTAssertNil(SystemDeviceSnapshot.batteryPercent(current: 51, maximum: 50))
        let airpods = SystemDeviceSnapshot(id: "actual-id", name: "AirPods", connection: "Bluetooth", connected: true)
        XCTAssertNil(airpods.batteryPercent)
    }
    func testTunnelClassificationDoesNotClaimInternetReachability() {
        XCTAssertTrue(OrbitNetworkInterface(name: "utun4", isUp: true, isRunning: true).isTunnel)
        XCTAssertFalse(OrbitNetworkInterface(name: "en0", isUp: true, isRunning: true).isTunnel)
        XCTAssertFalse(OrbitNetworkInterface(name: "lo0", isUp: true, isRunning: true, isLoopback: true).isActive)
        XCTAssertFalse(OrbitNetworkInterface(name: "en1", isUp: true, isRunning: false).isActive)
    }
    func testPerInterfaceRateHandlesResetNewInactiveAndVPNWithoutCombining() {
        func sample(_ name: String, _ rx: UInt64, _ tx: UInt64, active: Bool = true) -> OrbitNetworkInterface {
            .init(name: name, isUp: active, isRunning: active, bytes: .init(received: rx, sent: tx))
        }
        let before = [sample("en0", 100, 200), sample("utun0", 20, 30), sample("en1", 500, 600)]
        let after = [sample("en0", 300, 300), sample("utun0", 40, 90), sample("en1", 1, 1), sample("en2", 20, 30)]
        let rates = OrbitSystemDeltas.interfaceRates(current: after, previous: before, elapsed: 2)
        XCTAssertEqual(rates["en0"], .init(received: 100, sent: 50))
        XCTAssertEqual(rates["utun0"], .init(received: 10, sent: 30))
        XCTAssertNil(rates["en1"]); XCTAssertNil(rates["en2"])
        XCTAssertTrue(OrbitSystemDeltas.interfaceRates(current: after, previous: before, elapsed: .nan).isEmpty)
        XCTAssertTrue(OrbitSystemDeltas.interfaceRates(current: after, previous: before, elapsed: Double.leastNonzeroMagnitude).isEmpty)
        XCTAssertTrue(OrbitSystemDeltas.interfaceRates(current: [sample("en0", 300, 300, active: false)], previous: before, elapsed: 2).isEmpty)
    }
}
