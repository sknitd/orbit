import XCTest
@testable import NotchCore

final class OrbitSystemDeltasTests: XCTestCase {
    func testCPUDeltaAndCounterRollover() throws {
        XCTAssertEqual(try XCTUnwrap(OrbitSystemDeltas.cpuPercent(current: [30, 10, 70, 20], previous: [10, 0, 0, 0])), 41.666666, accuracy: 0.001)
        XCTAssertNil(OrbitSystemDeltas.cpuPercent(current: [0, 0, 0, 0], previous: [0, 0, 0, 0]))
        XCTAssertEqual(OrbitSystemDeltas.cpuPercent(current: [1, 0, 2, 0], previous: [UInt32.max, 0, 0, 0]), 50)
    }
    func testNetworkIgnoresResetAndNewInterfaces() throws {
        let old = ["en0": OrbitNetworkBytes(received: 100, sent: 50), "utun0": OrbitNetworkBytes(received: 99, sent: 99)]
        let current = ["en0": OrbitNetworkBytes(received: 300, sent: 150), "utun0": OrbitNetworkBytes(received: 1, sent: 1), "en1": OrbitNetworkBytes(received: 9999, sent: 9999)]
        let rate = try XCTUnwrap(OrbitSystemDeltas.networkRate(current: current, previous: old, elapsed: 2))
        XCTAssertEqual(rate.received, 100); XCTAssertEqual(rate.sent, 50)
        XCTAssertNil(OrbitSystemDeltas.networkRate(current: current, previous: old, elapsed: 0))
        XCTAssertNil(OrbitSystemDeltas.networkRate(current: ["new": current["en1"]!], previous: old, elapsed: 1))
    }
}
