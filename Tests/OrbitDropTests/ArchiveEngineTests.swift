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

    func testFolderUnderSymbolicParentAliasRoundTripsExactContents() async throws {
        let physicalParent = directory.appendingPathComponent("physical-parent", isDirectory: true)
        let physicalSource = physicalParent.appendingPathComponent("source-folder", isDirectory: true)
        let nested = physicalSource.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let original = nested.appendingPathComponent("content.bin")
        let bytes = Data([0, 1, 2, 127, 128, 254, 255]) + Data("Archive parent-alias fixture\n".utf8)
        try bytes.write(to: original)
        let aliasParent = directory.appendingPathComponent("parent-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: physicalParent)
        let aliasedSource = aliasParent.appendingPathComponent("source-folder", isDirectory: true)
        XCTAssertNotEqual(aliasedSource.standardizedFileURL, aliasedSource.resolvingSymlinksInPath())
        let selection = try inspect([aliasedSource])
        XCTAssertEqual(selection.first?.kind, .folder)

        let context = ActionContext(outputDirectory: directory)
        let zipped = try await ArchiveEngine().perform(.zip, items: selection, context: context)
        let extracted = try await ArchiveEngine().perform(.unzip, items: inspect(zipped.outputs), context: context)
        let result = try XCTUnwrap(extracted.outputs.first).appendingPathComponent("source-folder/nested/content.bin")
        XCTAssertEqual(try Data(contentsOf: result), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: aliasedSource.appendingPathComponent("nested/content.bin")), bytes)
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
            try assertDirectoryContainsExactly([source.lastPathComponent])
            XCTAssertEqual(try source.appendingPathComponent("escape").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
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
            try assertDirectoryContainsExactly([source.lastPathComponent])
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
            try assertDirectoryContainsExactly([first.lastPathComponent, folder.lastPathComponent])
            XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first content")
            XCTAssertEqual(try folder.appendingPathComponent("link").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        }
    }
}
