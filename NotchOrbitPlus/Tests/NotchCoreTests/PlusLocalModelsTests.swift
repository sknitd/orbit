import Foundation
import XCTest
@testable import NotchCore

final class PlusLocalModelsTests: XCTestCase {
    private func unit(_ id: String) throws -> ConversionUnit {
        try XCTUnwrap(UnitConversion.units.first { $0.id == id })
    }

    func testCatalogHasAllReferenceToolsAndRetainedFileActionsExactlyOnce() {
        XCTAssertEqual(PlusTool.defaultOrder.count, 20)
        XCTAssertEqual(Set(PlusTool.defaultOrder), Set(PlusTool.allCases))
        XCTAssertEqual(PlusTool.defaultOrder.last, .fileActions)
        for tool in PlusTool.allCases {
            XCTAssertFalse(tool.title.isEmpty)
            XCTAssertFalse(tool.symbol.isEmpty)
            XCTAssertFalse(tool.description.isEmpty)
        }
    }

    func testKnownImperialAndMetricLengthAndMass() throws {
        XCTAssertEqual(try UnitConversion.convert(1, from: unit("mi"), to: unit("km")), 1.609344, accuracy: 1e-10)
        XCTAssertEqual(try UnitConversion.convert(12, from: unit("in"), to: unit("ft")), 1, accuracy: 1e-12)
        XCTAssertEqual(try UnitConversion.convert(16, from: unit("oz"), to: unit("lb")), 1, accuracy: 1e-12)
        XCTAssertEqual(try UnitConversion.convert(1, from: unit("lb"), to: unit("g")), 453.59237, accuracy: 1e-8)
    }

    func testAffineTemperatureConversionAndAbsoluteZero() throws {
        XCTAssertEqual(try UnitConversion.convert(32, from: unit("F"), to: unit("C")), 0, accuracy: 1e-10)
        XCTAssertEqual(try UnitConversion.convert(100, from: unit("C"), to: unit("F")), 212, accuracy: 1e-10)
        XCTAssertEqual(try UnitConversion.convert(-273.15, from: unit("C"), to: unit("K")), 0, accuracy: 1e-10)
        XCTAssertThrowsError(try UnitConversion.convert(-1, from: unit("K"), to: unit("C"))) {
            XCTAssertEqual($0 as? UnitConversion.Failure, .belowAbsoluteZero)
        }
    }

    func testUSAndImperialVolumesAreDistinctAndNauticalSpeedIsExact() throws {
        XCTAssertEqual(try UnitConversion.convert(1, from: unit("galUS"), to: unit("L")), 3.785411784, accuracy: 1e-12)
        XCTAssertEqual(try UnitConversion.convert(1, from: unit("galUK"), to: unit("L")), 4.54609, accuracy: 1e-12)
        XCTAssertEqual(try UnitConversion.convert(1, from: unit("kn"), to: unit("kmh")), 1.852, accuracy: 1e-12)
        XCTAssertEqual(try UnitConversion.convert(60, from: unit("mph"), to: unit("kmh")), 96.56064, accuracy: 1e-9)
    }

    func testRoundTripsForEveryUnitFamily() throws {
        for family in UnitFamily.allCases {
            let source = try XCTUnwrap(family.units.first)
            for target in family.units {
                let converted = try UnitConversion.convert(17.25, from: source, to: target)
                let roundTrip = try UnitConversion.convert(converted, from: target, to: source)
                XCTAssertEqual(roundTrip, 17.25, accuracy: 1e-9, "\(source.id) → \(target.id)")
            }
        }
    }

    func testInvalidNumberCrossFamilyAndMalformedUnitAreRejected() throws {
        let metre = try unit("m")
        XCTAssertThrowsError(try UnitConversion.convert(.infinity, from: metre, to: metre))
        XCTAssertThrowsError(try UnitConversion.convert(.nan, from: metre, to: metre))
        XCTAssertThrowsError(try UnitConversion.convert(.greatestFiniteMagnitude, from: unit("km"), to: metre))
        XCTAssertThrowsError(try UnitConversion.convert(1, from: metre, to: unit("kg")))
        let invalid = ConversionUnit("broken", .length, "Broken", "?", scale: 0)
        XCTAssertThrowsError(try UnitConversion.convert(1, from: invalid, to: metre))
    }

    func testTaskPersistenceRetainsIdentityCompletionStarAndUnicodeTitle() throws {
        let task = ToDoItem(title: "Review café photos 📸", completed: true, starred: true,
                            createdAt: Date(timeIntervalSince1970: 1_000))
        let encoded = try JSONEncoder().encode([task])
        let restored = try JSONDecoder().decode([ToDoItem].self, from: encoded)
        XCTAssertEqual(restored, [task])
        XCTAssertEqual(restored.first?.id, task.id)
    }

    func testShelfRetentionInclusiveBoundaryAndFutureEntries() {
        let item = FileShelfItem(originalURL: URL(fileURLWithPath: "/originals/never-delete.txt"),
                                 addedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertFalse(item.expired(at: Date(timeIntervalSince1970: 4_599), retention: .hour))
        XCTAssertTrue(item.expired(at: Date(timeIntervalSince1970: 4_600), retention: .hour))
        XCTAssertFalse(item.expired(at: Date(timeIntervalSince1970: 0), retention: .day))
        XCTAssertFalse(item.expired(at: .distantFuture, retention: .forever))
    }

    func testShelfPersistencePreservesManagedAndOriginalLocationsAndExpirySelection() throws {
        let old = FileShelfItem(originalURL: URL(fileURLWithPath: "/source/a.txt"),
                                managedURL: URL(fileURLWithPath: "/support/copy/a.txt"), bookmark: Data([1, 2, 3]),
                                addedAt: Date(timeIntervalSince1970: 0))
        let recent = FileShelfItem(originalURL: URL(fileURLWithPath: "/source/b.txt"),
                                   addedAt: Date(timeIntervalSince1970: 10_000))
        let state = FileShelfState(items: [old, recent], autoSave: true, retention: .hour)
        let restored = try JSONDecoder().decode(FileShelfState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.expiredItems(at: Date(timeIntervalSince1970: 11_000)), [old])
        XCTAssertEqual(restored.items.map(\.originalURL.path), ["/source/a.txt", "/source/b.txt"])
    }
}
