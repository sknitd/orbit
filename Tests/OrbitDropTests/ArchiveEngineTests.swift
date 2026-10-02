import Foundation
import XCTest
import OrbitCore
@testable import OrbitDrop

final class ArchiveEngineTests: EngineTestCase, @unchecked Sendable {
    func testZIPRoundTripRetainsFileBytesAndOriginals() async throws {
        let source = directory.appendingPathComponent("original.txt")
        let content = Data("Actual archive round-trip fixture.\n".utf8)
        try content.write(to: source)
        let zipped = try await ArchiveEngine().perform(.zip, items: inspect([source]), context: .init())
        let zip = try XCTUnwrap(zipped.outputs.first)
        XCTAssertEqual(try ZIPInspector.inspect(zip).entryCount, 1)
        let extracted = try await ArchiveEngine().perform(.unzip, items: inspect([zip]), context: .init())
        let folder = try XCTUnwrap(extracted.outputs.first)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(source.lastPathComponent)), content)
        XCTAssertEqual(try Data(contentsOf: source), content)
    }

    func testFolderArchiveIncludesNestedRealFiles() async throws {
        let source = directory.appendingPathComponent("folder", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let original = nested.appendingPathComponent("file.txt")
        try Data("nested content".utf8).write(to: original)
        let zipped = try await ArchiveEngine().perform(.zip, items: inspect([source]), context: .init())
        let extracted = try await ArchiveEngine().perform(.unzip, items: inspect(zipped.outputs), context: .init())
        let result = try XCTUnwrap(extracted.outputs.first).appendingPathComponent("folder/nested/file.txt")
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "nested content")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "nested content")
    }

    func testFolderContainingSymlinkIsRejectedBeforeLaunchingArchiver() async throws {
        let source = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape"),
                                                 withDestinationURL: directory)
        do {
            _ = try await ArchiveEngine().perform(.zip, items: inspect([source]), context: .init())
            XCTFail("Symlinks must never be archived")
        } catch {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil), [source])
        }
    }

    func testMalformedArchiveFailsWithoutPublishingDirectory() async throws {
        let source = directory.appendingPathComponent("malformed.zip")
        let content = Data([0x50, 0x4b, 0x03, 0x04, 0, 0])
        try content.write(to: source)
        do {
            _ = try await ArchiveEngine().perform(.unzip, items: inspect([source]), context: .init())
            XCTFail("Truncated ZIP must fail")
        } catch {
            XCTAssertEqual(try Data(contentsOf: source), content)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil), [source])
        }
    }

    func testBatchFailureRollsBackEarlierZIPOutputs() async throws {
        let first = directory.appendingPathComponent("first.txt")
        try Data("first content".utf8).write(to: first)
        let folder = directory.appendingPathComponent("unsafe-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: first)
        do {
            _ = try await ArchiveEngine().perform(.zip, items: inspect([first, folder]), context: .init())
            XCTFail("The unsafe second item must fail the batch")
        } catch {
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)), Set([first, folder]))
        }
    }
}
