import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import OrbitCore
import NotchCore
@testable import NotchOrbitPlus

final class WorkflowRunnerTests: NativeImageFixtureCase, @unchecked Sendable {
    @MainActor
    func testEditingAfterRejectedSavedPresetsPreservesTheirExactPriorBytes() throws {
        let duplicate = WorkflowPreset(name: "Duplicate", steps: [.zip])
        let rejected = [
            [WorkflowPreset(name: "../invalid", steps: [.zip])],
            [WorkflowPreset(name: "Invalid order", steps: [.zip, .convert(format: .jpeg)])],
            [duplicate, duplicate]
        ]
        for values in rejected {
            let suite = "NotchOrbitPlus.WorkflowStoreTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let prior = try JSONEncoder().encode(values)
            defaults.set(prior, forKey: "workflows.presets")
            let store = WorkflowStore(defaults: defaults)
            XCTAssertTrue(store.presets.isEmpty)
            XCTAssertNotNil(store.error)
            let valid = WorkflowPreset(name: "New delivery", steps: [.convert(format: .webp)])
            XCTAssertTrue(store.save(valid))
            XCTAssertEqual(defaults.data(forKey: "workflows.preserved-invalid"), prior)
            let restored = WorkflowStore(defaults: defaults)
            XCTAssertEqual(restored.presets, [valid])
            XCTAssertEqual(restored.selectedPresetID, valid.id)
        }
    }

    func testFourRealStagesProduceOneCollisionSafeZIPWithResizedJPEGs() async throws {
        let first = try rasterFile(named: "photo-one.jpg", width: 640, height: 320)
        let second = try rasterFile(named: "photo-two.png", width: 800, height: 800)
        let originals = try [first, second].map { try Data(contentsOf: $0) }
        let output = try outputDirectory()
        let collision = output.appendingPathComponent("Delivery.zip")
        let existing = Data("existing output must survive".utf8)
        try existing.write(to: collision)
        let preset = WorkflowPreset(name: "Delivery", steps: [
            .resize(maxDimension: 320), .convert(format: .jpeg), .compress(quality: 0.25), .zip
        ])
        let ledger = WorkflowProgressLedger()
        let result = try await WorkflowRunner.perform(preset: preset, urls: [first, second],
                                                      outputDirectory: output) { value, message in
            _ = ledger.record(value, message)
        }
        let zip = try XCTUnwrap(result.outputs.first)
        XCTAssertEqual(result.outputs.count, 1)
        XCTAssertEqual(zip.lastPathComponent, "Delivery (2).zip")
        XCTAssertEqual(try Data(contentsOf: collision), existing)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)),
                       Set(["Delivery.zip", "Delivery (2).zip"]))
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: $0) }, originals)
        XCTAssertEqual(result.inputBytes, Int64(originals.reduce(0) { $0 + $1.count }))
        XCTAssertEqual(result.outputBytes, Int64(try Data(contentsOf: zip).count))
        let inventory = try ZIPInspector.inspect(zip)
        XCTAssertGreaterThanOrEqual(inventory.entryCount, 2)

        let extraction = fixtureDirectory.appendingPathComponent("extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
        let unpacked = try await ArchiveEngine().perform(.unzip, items: FileInspector.inspect([zip]),
                                                         context: .init(outputDirectory: extraction))
        let folder = try XCTUnwrap(unpacked.outputs.first)
        let files = try regularFiles(in: folder)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(["photo-one-Delivery.jpg", "photo-two-Delivery.jpg"]))
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(inventory.expandedBytes, Int64(try files.reduce(0) { $0 + (try Data(contentsOf: $1)).count }))
        for file in files {
            XCTAssertTrue(file.pathComponents.contains("Delivery"))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
            let decoded = try ImageEngine.loadUpright(file)
            XCTAssertEqual(decoded.width, 320)
            XCTAssertEqual(decoded.height, file.lastPathComponent.hasPrefix("photo-one") ? 160 : 320)
        }
        let progress = ledger.snapshot().values
        XCTAssertFalse(progress.isEmpty)
        XCTAssertEqual(progress.last, 1)
        XCTAssertTrue(progress.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertTrue(zipAdjacent(progress).allSatisfy { $0 <= $1 })
    }

    func testCustomResizeAndWebPConversionPublishOnlyTheFinalDecodableFile() async throws {
        let source = try rasterFile(named: "input.jpg", width: 640, height: 320)
        let original = try Data(contentsOf: source)
        let output = try outputDirectory()
        let preset = WorkflowPreset(name: "Small web", steps: [.resize(maxDimension: 192), .convert(format: .webp)])
        let result = try await WorkflowRunner.perform(preset: preset, urls: [source], outputDirectory: output)
        let file = try XCTUnwrap(result.outputs.first)
        XCTAssertEqual(result.outputs.count, 1)
        XCTAssertEqual(file.lastPathComponent, "input-Small web.webp")
        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(String(data: bytes.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: bytes[8..<12], encoding: .ascii), "WEBP")
        let decoded = try ImageEngine.loadUpright(file)
        XCTAssertEqual(decoded.width, 192)
        XCTAssertEqual(decoded.height, 96)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [file.lastPathComponent])
    }

    func testInvalidSecondInputAndSymbolicSourceRejectWithoutPublishingOrChangingData() async throws {
        let source = try rasterFile(named: "original.jpg", width: 96, height: 64)
        let original = try Data(contentsOf: source)
        let invalid = fixtureDirectory.appendingPathComponent("invalid.jpg")
        let invalidBytes = Data("not an image".utf8)
        try invalidBytes.write(to: invalid)
        let link = fixtureDirectory.appendingPathComponent("linked.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let output = try outputDirectory()
        let preset = WorkflowPreset(name: "Convert", steps: [.convert(format: .webp)])
        for inputs in [[source, invalid], [link]] {
            do {
                _ = try await WorkflowRunner.perform(preset: preset, urls: inputs, outputDirectory: output)
                XCTFail("Invalid or symbolic inputs must not run a saved workflow")
            } catch {
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
                XCTAssertEqual(try Data(contentsOf: source), original)
                XCTAssertEqual(try Data(contentsOf: invalid), invalidBytes)
            }
        }
    }

    func testUnsupportedSecondImageRemovesTheFirstImagesCompletedPrivateStage() async throws {
        let source = try rasterFile(named: "first.jpg", width: 320, height: 160)
        let frame = try rasterFile(named: "frame.jpg", width: 96, height: 64)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(frame as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let animation = fixtureDirectory.appendingPathComponent("animation.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(animation as CFURL,
                                                                        UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let animationSource = try XCTUnwrap(CGImageSourceCreateWithURL(animation as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(animationSource), 2)
        let original = try Data(contentsOf: source)
        let animatedBytes = try Data(contentsOf: animation)
        XCTAssertEqual(try FileInspector.inspect([source, animation]).map(\.kind), [.image, .image])
        let output = try outputDirectory()
        let ledger = WorkflowProgressLedger(trigger: "Resizing 2 of 2…")
        do {
            _ = try await WorkflowRunner.perform(preset: .init(name: "Resize", steps: [.resize(maxDimension: 160)]),
                                                  urls: [source, animation], outputDirectory: output) { value, message in
                _ = ledger.record(value, message)
            }
            XCTFail("A multi-frame image must fail after the first still image stage")
        } catch {
            XCTAssertTrue(ledger.snapshot().triggered)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try Data(contentsOf: animation), animatedBytes)
        }
    }

    func testLatePublicationFailurePreservesTheBlockingFileAndOriginal() async throws {
        let source = try rasterFile(named: "original.jpg", width: 320, height: 160)
        let original = try Data(contentsOf: source)
        let blocked = fixtureDirectory.appendingPathComponent("output-is-a-file")
        let existing = Data("must not be replaced by a directory or image".utf8)
        try existing.write(to: blocked)
        let ledger = WorkflowProgressLedger(trigger: "Step 2 complete")
        do {
            _ = try await WorkflowRunner.perform(preset: .init(name: "Delivery", steps: [
                .resize(maxDimension: 160), .convert(format: .webp)
            ]), urls: [source], outputDirectory: blocked) { value, message in
                _ = ledger.record(value, message)
            }
            XCTFail("A regular file cannot be used as an output directory")
        } catch {
            XCTAssertTrue(ledger.snapshot().triggered, "Both real image stages should finish before publication fails")
            XCTAssertEqual(try Data(contentsOf: blocked), existing)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path)),
                           Set([source.lastPathComponent, blocked.lastPathComponent]))
        }
    }

    func testCancellationAfterARealStageLeavesExistingOutputAndSourceIntact() async throws {
        let source = try rasterFile(named: "original.jpg", width: 320, height: 160)
        let original = try Data(contentsOf: source)
        let output = try outputDirectory()
        let existingURL = output.appendingPathComponent("original-Delivery.webp")
        let existing = Data("pre-existing collision".utf8)
        try existing.write(to: existingURL)
        let ledger = WorkflowProgressLedger(trigger: "Step 1 complete")
        do {
            _ = try await WorkflowRunner.perform(preset: .init(name: "Delivery", steps: [
                .resize(maxDimension: 160), .convert(format: .webp)
            ]), urls: [source], outputDirectory: output) { value, message in
                if ledger.record(value, message) { withUnsafeCurrentTask { $0?.cancel() } }
            }
            XCTFail("A cancelled pipeline must not publish a final result")
        } catch is CancellationError {
            XCTAssertTrue(ledger.snapshot().triggered)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try Data(contentsOf: existingURL), existing)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [existingURL.lastPathComponent])
        } catch { XCTFail("Expected cancellation, got \(error.localizedDescription)") }
    }

    func testExternalSourceReplacementAfterAStageRejectsStaleOutputAndRetainsReplacement() async throws {
        let source = try rasterFile(named: "original.jpg", width: 320, height: 160)
        let replacement = Data("an external writer replaced the original".utf8)
        let output = try outputDirectory()
        let ledger = WorkflowProgressLedger(trigger: "Step 1 complete")
        do {
            _ = try await WorkflowRunner.perform(preset: .init(name: "Delivery", steps: [
                .resize(maxDimension: 160), .convert(format: .webp)
            ]), urls: [source], outputDirectory: output) { value, message in
                if ledger.record(value, message) {
                    do { try replacement.write(to: source, options: .atomic) }
                    catch { ledger.recordMutationError(error) }
                }
            }
            XCTFail("A workflow must reject a source changed since its snapshot")
        } catch {
            XCTAssertTrue(error is WorkflowError)
            XCTAssertTrue(ledger.snapshot().triggered)
            XCTAssertNil(ledger.snapshot().mutationError)
            XCTAssertEqual(try Data(contentsOf: source), replacement)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        }
    }

    func testTwoPathsThroughASymbolicParentCannotDuplicateOnePhysicalInput() async throws {
        let source = try rasterFile(named: "original.jpg", width: 96, height: 64)
        let original = try Data(contentsOf: source)
        let alias = fixtureDirectory.appendingPathComponent("parent-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixtureDirectory)
        let aliasedSource = alias.appendingPathComponent(source.lastPathComponent)
        let output = try outputDirectory()
        do {
            _ = try await WorkflowRunner.perform(preset: .init(name: "Delivery", steps: [.convert(format: .webp)]),
                                                  urls: [source, aliasedSource], outputDirectory: output)
            XCTFail("Two aliases for one physical input must be rejected as duplicates")
        } catch {
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        }
    }

    private func outputDirectory() throws -> URL {
        let output = fixtureDirectory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        return output
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: directory,
                                       includingPropertiesForKeys: [.isRegularFileKey]))
        return try iterator.compactMap { value in
            guard let url = value as? URL else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        }
    }

    private func zipAdjacent(_ values: [Double]) -> [(Double, Double)] {
        Array(zip(values, values.dropFirst()))
    }
}

private final class WorkflowProgressLedger: @unchecked Sendable {
    private let lock = NSLock()
    private let trigger: String?
    private var values: [Double] = []
    private var triggered = false
    private var mutationError: String?
    init(trigger: String? = nil) { self.trigger = trigger }
    func record(_ value: Double, _ message: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
        guard !triggered, message == trigger else { return false }
        triggered = true
        return true
    }
    func recordMutationError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        mutationError = error.localizedDescription
    }
    func snapshot() -> (values: [Double], triggered: Bool, mutationError: String?) {
        lock.lock(); defer { lock.unlock() }
        return (values, triggered, mutationError)
    }
}
