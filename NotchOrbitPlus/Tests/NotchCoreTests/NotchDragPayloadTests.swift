import Foundation
import XCTest
@testable import NotchCore

final class NotchDragPayloadTests: XCTestCase {
    func testEquivalentBatchMayArriveInDifferentOrder() {
        let a = URL(fileURLWithPath: "/fixtures/a.jpg")
        let b = URL(fileURLWithPath: "/fixtures/b.png")
        XCTAssertTrue(NotchDragPayload.matches(observed: [a, b], dropped: [b, a]))
        let normalized = URL(fileURLWithPath: "/fixtures/../fixtures/a.jpg")
        XCTAssertTrue(NotchDragPayload.matches(observed: [a], dropped: [normalized]))
    }

    func testChangedCountChangedFileDuplicatesAndEmptyPayloadAreRejected() {
        let a = URL(fileURLWithPath: "/fixtures/a.jpg")
        let b = URL(fileURLWithPath: "/fixtures/b.png")
        XCTAssertFalse(NotchDragPayload.matches(observed: [], dropped: []))
        XCTAssertFalse(NotchDragPayload.matches(observed: [a], dropped: [b]))
        XCTAssertFalse(NotchDragPayload.matches(observed: [a], dropped: [a, b]))
        XCTAssertFalse(NotchDragPayload.matches(observed: [a, a], dropped: [a, a]))
        XCTAssertFalse(NotchDragPayload.matches(observed: [a, b], dropped: [a, a]))
    }

    func testRemoteURLsForeignFileHostsAndURLDecorationsAreRejected() throws {
        for text in ["https://example.com/photo.jpg", "file://foreign-host/fixtures/a.jpg",
                     "file:///fixtures/a.jpg?bad=yes", "file:///fixtures/a.jpg#fragment"] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertFalse(NotchDragPayload.matches(observed: [url], dropped: [url]), text)
        }
    }

    func testLocalhostFileHostIsEquivalentToLocalFilePath() throws {
        let hosted = try XCTUnwrap(URL(string: "file://localhost/fixtures/a.jpg"))
        let local = URL(fileURLWithPath: "/fixtures/a.jpg")
        XCTAssertTrue(NotchDragPayload.matches(observed: [hosted], dropped: [local]))
    }
}
