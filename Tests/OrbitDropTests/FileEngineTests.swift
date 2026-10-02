import Foundation
import XCTest
import OrbitCore
@testable import OrbitDrop

final class FileEngineTests: EngineTestCase, @unchecked Sendable {
    func testSHA256UsesActualContentsAndPortableManifest() async throws {
        let source = directory.appendingPathComponent("source.txt")
        try Data("abc".utf8).write(to: source)
        let result = try await FileEngine().perform(.checksum, items: inspect([source]), context: .init())
        let manifest = try String(contentsOf: XCTUnwrap(result.outputs.first), encoding: .utf8)
        XCTAssertEqual(manifest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  source.txt\n")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "abc")
    }

    func testDuplicateIsByteIdenticalAndAvoidsExistingResult() async throws {
        let source = directory.appendingPathComponent("source.bin")
        let content = Data((0..<255).map(UInt8.init))
        try content.write(to: source)
        let existing = directory.appendingPathComponent("source copy.bin")
        try Data("existing user file".utf8).write(to: existing)
        let result = try await FileEngine().perform(.duplicate, items: inspect([source]), context: .init())
        let output = try XCTUnwrap(result.outputs.first)
        XCTAssertEqual(output.lastPathComponent, "source copy (2).bin")
        XCTAssertEqual(try Data(contentsOf: output), content)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing user file")
        XCTAssertEqual(try Data(contentsOf: source), content)
    }

    func testJSONFormatAndMinifyPreserveSemantics() async throws {
        let source = directory.appendingPathComponent("data.json")
        let original = Data("{\"z\":[1,true,null],\"a\":{\"text\":\"a b\",\"value\":1.5}}".utf8)
        try original.write(to: source)
        let formatted = try await FileEngine().perform(.formatJSON, items: inspect([source]), context: .init())
        let minified = try await FileEngine().perform(.minifyJSON, items: inspect(formatted.outputs), context: .init())
        let expected = try JSONSerialization.jsonObject(with: original) as? NSDictionary
        for output in formatted.outputs + minified.outputs {
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? NSDictionary, expected)
        }
        let formattedText = try String(contentsOf: XCTUnwrap(formatted.outputs.first), encoding: .utf8)
        XCTAssertTrue(formattedText.contains("\n"))
        let minifiedText = try String(contentsOf: XCTUnwrap(minified.outputs.first), encoding: .utf8)
        XCTAssertFalse(minifiedText.contains("\n"))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testInvalidJSONFailsWithoutPublishingOrChangingSource() async throws {
        let source = directory.appendingPathComponent("broken.json")
        let original = Data("{broken".utf8)
        try original.write(to: source)
        do {
            _ = try await FileEngine().perform(.formatJSON, items: inspect([source]), context: .init())
            XCTFail("Invalid JSON cannot be formatted")
        } catch {
            try assertDirectoryContainsExactly([source.lastPathComponent])
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testChecksumBatchFailureRollsBackEarlierPublishedOutputs() async throws {
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("bad\nname.txt")
        for url in [first, second] { try Data("abc".utf8).write(to: url) }
        do {
            _ = try await FileEngine().perform(.checksum, items: inspect([first, second]), context: .init())
            XCTFail("Unsafe manifest filenames must fail")
        } catch {
            try assertDirectoryContainsExactly([first.lastPathComponent, second.lastPathComponent])
            for source in [first, second] {
                XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "abc")
            }
        }
    }
}
