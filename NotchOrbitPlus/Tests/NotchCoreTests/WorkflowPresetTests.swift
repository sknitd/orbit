import Foundation
import XCTest
@testable import NotchCore

final class WorkflowPresetTests: XCTestCase {
    func testVideoPresetRoundTripsAndOnlyAllowsCompressionThenOptionalZIP() throws {
        for steps: [WorkflowStep] in [[.compressVideo], [.compressVideo, .zip]] {
            let preset = WorkflowPreset(name: "Recording", steps: steps)
            let restored = try JSONDecoder().decode(WorkflowPreset.self, from: JSONEncoder().encode(preset))
            XCTAssertEqual(try restored.validated(), preset)
            XCTAssertTrue(restored.isVideoWorkflow)
            XCTAssertTrue(restored.summary.contains("MP4"))
        }
        XCTAssertNoThrow(try WorkflowPreset.videoStarter.validated())
        XCTAssertFalse(WorkflowPreset.starter.isVideoWorkflow)
        let invalid: [[WorkflowStep]] = [
            [.resize(maxDimension: 1600), .compressVideo],
            [.convert(format: .jpeg), .compressVideo],
            [.compress(quality: 0.5), .compressVideo],
            [.compressVideo, .compressVideo], [.zip, .compressVideo],
            [.compressVideo, .zip, .zip]
        ]
        for steps in invalid { XCTAssertThrowsError(try WorkflowPreset(name: "Mixed", steps: steps).validated()) }
    }
    func testSavedFourStagePresetRoundTripsWithoutChangingItsIdentityOrParameters() throws {
        let id = UUID()
        let preset = WorkflowPreset(id: id, name: "Photo delivery", steps: [
            .resize(maxDimension: 1200), .convert(format: .webp), .compress(quality: 0.35), .zip
        ])
        let restored = try JSONDecoder().decode(WorkflowPreset.self,
                                               from: JSONEncoder().encode(preset))
        XCTAssertEqual(try restored.validated(), preset)
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.steps, preset.steps)
        XCTAssertTrue(restored.summary.contains("1200"))
        XCTAssertTrue(restored.summary.contains("WEBP"))
        XCTAssertTrue(restored.summary.contains("35%"))
    }

    func testValidationTrimsANameWithoutMutatingTheSavedValue() throws {
        let preset = WorkflowPreset(name: "  Holiday photos  ", steps: [.convert(format: .jpeg)])
        let validated = try preset.validated()
        XCTAssertEqual(validated.name, "Holiday photos")
        XCTAssertEqual(validated.id, preset.id)
        XCTAssertEqual(preset.name, "  Holiday photos  ")
        XCTAssertNoThrow(try WorkflowPreset.starter.validated())
    }

    func testRepeatedReorderedOrNonfinalArchiveStepsCannotRun() {
        let invalid: [[WorkflowStep]] = [
            [], [.resize(maxDimension: 100), .resize(maxDimension: 200)],
            [.convert(format: .jpeg), .resize(maxDimension: 100)],
            [.compress(quality: 0.4), .convert(format: .webp)],
            [.zip, .resize(maxDimension: 100)], [.zip, .zip]
        ]
        for steps in invalid {
            XCTAssertThrowsError(try WorkflowPreset(name: "Unsafe order", steps: steps).validated())
        }
        XCTAssertNoThrow(try WorkflowPreset(name: "Archive only", steps: [.zip]).validated())
        XCTAssertNoThrow(try WorkflowPreset(name: "Two steps", steps: [.resize(maxDimension: 100), .zip]).validated())
    }

    func testLosslessPNGDoesNotAdvertiseAnEffectiveQualityCompressionStep() {
        XCTAssertThrowsError(try WorkflowPreset(name: "PNG quality", steps: [
            .convert(format: .png), .compress(quality: 0.5)
        ]).validated())
        XCTAssertThrowsError(try WorkflowPreset(name: "Implicit PNG quality", steps: [
            .resize(maxDimension: 1600), .compress(quality: 0.5)
        ]).validated())
        for format in [WorkflowFormat.jpeg, .heic, .webp] {
            XCTAssertNoThrow(try WorkflowPreset(name: "Lossy delivery", steps: [
                .convert(format: format), .compress(quality: 0.5), .zip
            ]).validated())
        }
        XCTAssertNoThrow(try WorkflowPreset(name: "PNG delivery", steps: [.convert(format: .png), .zip]).validated())
    }

    func testDimensionLimitsAcceptEndpointsAndRejectInvalidImageBudgets() {
        for dimension in [64, 12_000] {
            XCTAssertNoThrow(try WorkflowPreset(name: "Resize", steps: [.resize(maxDimension: dimension)]).validated())
        }
        for dimension in [0, -1, 63, 12_001, Int.max] {
            XCTAssertThrowsError(try WorkflowPreset(name: "Resize", steps: [.resize(maxDimension: dimension)]).validated())
        }
    }

    func testCompressionQualityRejectsNonfiniteAndOutOfRangePersistence() {
        for quality in [0.1, 0.95] {
            XCTAssertNoThrow(try WorkflowPreset(name: "Compress", steps: [.compress(quality: quality)]).validated())
        }
        for quality in [0, 0.099, 0.951, 1, -.infinity, .infinity, .nan] {
            XCTAssertThrowsError(try WorkflowPreset(name: "Compress", steps: [.compress(quality: quality)]).validated())
        }
    }

    func testOutputNamesRejectSeparatorsControlCharactersAndOversizedUTF8() {
        for name in ["", "  ", ".", "..", "../photos", "photos/2026", "photos\\2026", "disk:photos", "two\nlines", "null\0byte"] {
            XCTAssertThrowsError(try WorkflowPreset(name: name, steps: [.zip]).validated(), name)
        }
        XCTAssertNoThrow(try WorkflowPreset(name: String(repeating: "é", count: 40), steps: [.zip]).validated())
        XCTAssertThrowsError(try WorkflowPreset(name: String(repeating: "é", count: 41), steps: [.zip]).validated())
    }
}
