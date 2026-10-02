import Foundation
import XCTest
@testable import OrbitCore

final class ArchiveSecurityTests: XCTestCase {
    private struct Entry {
        var name: String
        var content = Data("hello".utf8)
        var localName: String?
        var mode: UInt16 = 0o100644
        var flags: UInt16 = 0
        var method: UInt16 = 0
        var unpackedSize: UInt32?
        var extra = Data()
    }

    private func archive(_ entries: [Entry]) -> Data {
        var local = Data()
        var central = Data()
        for entry in entries {
            let offset = UInt32(local.count)
            let name = Data(entry.name.utf8)
            let localName = Data((entry.localName ?? entry.name).utf8)
            let crc = checksum(entry.content)
            let packed = UInt32(entry.content.count)
            let unpacked = entry.unpackedSize ?? packed
            local.le32(0x04034b50); local.le16(20); local.le16(entry.flags); local.le16(entry.method)
            local.le16(0); local.le16(0); local.le32(crc); local.le32(packed); local.le32(unpacked)
            local.le16(UInt16(localName.count)); local.le16(UInt16(entry.extra.count))
            local.append(localName); local.append(entry.extra); local.append(entry.content)
            central.le32(0x02014b50); central.le16(0x0314); central.le16(20)
            central.le16(entry.flags); central.le16(entry.method); central.le16(0); central.le16(0)
            central.le32(crc); central.le32(packed); central.le32(unpacked)
            central.le16(UInt16(name.count)); central.le16(UInt16(entry.extra.count)); central.le16(0)
            central.le16(0); central.le16(0); central.le32(UInt32(entry.mode) << 16); central.le32(offset)
            central.append(name); central.append(entry.extra)
        }
        var result = local
        result.append(central)
        result.le32(0x06054b50); result.le16(0); result.le16(0)
        result.le16(UInt16(entries.count)); result.le16(UInt16(entries.count))
        result.le32(UInt32(central.count)); result.le32(UInt32(local.count)); result.le16(0)
        return result
    }

    private func checksum(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? crc >> 1 ^ 0xedb88320 : crc >> 1 }
        }
        return crc ^ 0xffffffff
    }

    private func inspect(_ bytes: Data) throws -> ZIPInspector.Inventory {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Orbit-ZIP-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: file) }
        try bytes.write(to: file)
        return try ZIPInspector.inspect(file)
    }

    func testRegularStoredZIPHasAccurateInventory() throws {
        let inventory = try inspect(archive([Entry(name: "folder/a.txt"), Entry(name: "folder/b.txt", content: Data([1, 2, 3]))]))
        XCTAssertEqual(inventory.entryCount, 2)
        XCTAssertEqual(inventory.expandedBytes, 8)
    }

    func testUnsafeExtractionPathsAreRejected() {
        for path in ["../escape", "/absolute", "a/../../escape", "C:/windows", "a\\b", "a//b", "a/./b", "bad\nname", "a/\0b"] {
            XCTAssertThrowsError(try ZIPInspector.safePath(path), "Accepted \(path)")
            XCTAssertThrowsError(try inspect(archive([Entry(name: path)])))
        }
        XCTAssertEqual(try ZIPInspector.safePath("folder/file.txt"), "folder/file.txt")
        XCTAssertEqual(try ZIPInspector.safePath("folder/"), "folder")
    }

    func testSymbolicLinksSpecialFilesAndPrivilegedModesAreRejected() {
        for mode: UInt16 in [0o120777, 0o020666, 0o010644, 0o104755, 0o102755] {
            XCTAssertThrowsError(try inspect(archive([Entry(name: "entry", mode: mode)])))
        }
    }

    func testEncryptedAndUnsupportedCompressionAreRejected() {
        XCTAssertThrowsError(try inspect(archive([Entry(name: "secret", flags: 1)])))
        XCTAssertThrowsError(try inspect(archive([Entry(name: "unknown", method: 99)])))
    }

    func testCentralAndLocalNamesMustAgree() {
        XCTAssertThrowsError(try inspect(archive([Entry(name: "safe.txt", localName: "evil.txt")])))
    }

    func testFilenameAliasesAndFileDirectoryConflictsAreRejected() {
        XCTAssertThrowsError(try inspect(archive([Entry(name: "File.txt"), Entry(name: "file.txt")])))
        XCTAssertThrowsError(try inspect(archive([Entry(name: "folder"), Entry(name: "folder/file.txt")])))
        XCTAssertThrowsError(try inspect(archive([Entry(name: "caf\u{00e9}.txt", flags: 0x0800),
                                                  Entry(name: "cafe\u{0301}.txt", flags: 0x0800)])))
    }

    func testExpansionBombAndZIP64ClaimsAreRejected() {
        XCTAssertThrowsError(try inspect(archive([Entry(name: "bomb", content: Data([0]), method: 8, unpackedSize: 100_000_000)])))
        XCTAssertThrowsError(try inspect(archive([Entry(name: "zip64", unpackedSize: UInt32.max)])))
    }

    func testEveryTruncatedPrefixFailsWithoutReadingOutsideBuffer() {
        let complete = archive([Entry(name: "good.txt")])
        for count in 0..<complete.count {
            XCTAssertThrowsError(try inspect(Data(complete.prefix(count))), "Accepted truncated archive of \(count) bytes")
        }
    }

    func testHiddenPrefixAndTrailingPayloadAreRejected() {
        let valid = archive([Entry(name: "good.txt")])
        XCTAssertThrowsError(try inspect(Data([0]) + valid))
        XCTAssertThrowsError(try inspect(valid + Data("hidden data".utf8)))
    }

    func testPKWAREUnixMetadataCannotContainLinkTarget() throws {
        var permitted = Data(); permitted.le16(0x000d); permitted.le16(12)
        permitted.append(Data(repeating: 0, count: 12))
        XCTAssertEqual(try inspect(archive([Entry(name: "safe.txt", extra: permitted)])).entryCount, 1)
        var linkMetadata = Data(); linkMetadata.le16(0x000d); linkMetadata.le16(16)
        linkMetadata.append(Data(repeating: 0, count: 16))
        XCTAssertThrowsError(try inspect(archive([Entry(name: "link.txt", extra: linkMetadata)])))
    }

    func testEmptyZIPIsValid() throws {
        XCTAssertEqual(try inspect(archive([])).entryCount, 0)
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func le32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16)); append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
