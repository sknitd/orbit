import Foundation
import XCTest
@testable import NotchCore

final class CoreQRTests: XCTestCase {
    func testPayloadPreservesUnicodeWhitespaceAndCountsActualUTF8Bytes() throws {
        let text = "  Orbit 🌍\nhttps://example.com/?a=1&b=2  "
        let request = try QRGenerationRequest(payload: text)
        XCTAssertEqual(request.payload, text)
        XCTAssertEqual(request.utf8Data, Data(text.utf8))
        XCTAssertNoThrow(try QRGenerationRequest(payload: String(repeating: "🌍", count: 256)))
        XCTAssertThrowsError(try QRGenerationRequest(payload: String(repeating: "🌍", count: 257))) {
            XCTAssertEqual($0 as? QRValidationError, .payloadTooLarge)
        }
        XCTAssertThrowsError(try QRGenerationRequest(payload: "")) {
            XCTAssertEqual($0 as? QRValidationError, .emptyPayload)
        }
    }
    func testEveryCorrectionAndIntegerScaleRoundTripsWithFourModuleQuietZone() throws {
        for correction in QRCorrectionLevel.allCases {
            for scale in [4, 8, 16] {
                let request = try QRGenerationRequest(payload: "ORBIT", options: .init(correction: correction, scale: scale))
                XCTAssertEqual(try JSONDecoder().decode(QRGenerationRequest.self, from: JSONEncoder().encode(request)), request)
            }
        }
        XCTAssertEqual(QREncodingOptions.quietZoneModules, 4)
        for scale in [Int.min, 0, 3, 17, Int.max] {
            XCTAssertThrowsError(try QREncodingOptions(scale: scale))
        }
    }
    func testDecodedOptionsAndRequestsRejectTamperedInput() throws {
        for json in [#"{"correction":"M","scale":0}"#, #"{"correction":"unknown","scale":8}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(QREncodingOptions.self, from: Data(json.utf8)))
        }
        let empty = #"{"payload":"","options":{"correction":"H","scale":8}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(QRGenerationRequest.self, from: Data(empty.utf8)))
        let excessive = Data("{\"payload\":\"\(String(repeating: "x", count: 1_025))\",\"options\":{\"correction\":\"L\",\"scale\":8}}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(QRGenerationRequest.self, from: excessive))
    }
}
