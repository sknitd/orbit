import Foundation
import NotchCore
import XCTest
@testable import NotchOrbitPlus

final class SyncFolderIOTests: XCTestCase {
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("NotchSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }
    private func target(in folder: URL, device: UUID) throws -> URL {
        try PlusSyncFolderIO.directory(in: folder).appendingPathComponent("device-\(device.uuidString.lowercased()).json")
    }
    private func snapshot(_ device: UUID, text: String = "Original") throws -> SyncSnapshot {
        var value = SyncSnapshot(deviceID: device)
        try value.captureNote(text)
        return value
    }

    func testEmptyFolderAndTwoDeviceCoordinatedPublicationRoundTrip() throws {
        try withFolder { folder in
            XCTAssertTrue(try PlusSyncFolderIO.read(folder: folder).isEmpty)
            let a = UUID(), b = UUID()
            var first = try snapshot(a)
            let item = ToDoItem(title: "Shared task")
            try first.captureTasks([item])
            let published = try PlusSyncFolderIO.publish(first, folder: folder)
            XCTAssertEqual(published, first)
            let originalBytes = try Data(contentsOf: target(in: folder, device: a))
            var second = try SyncMerge.threeWay(base: SyncSnapshot(deviceID: b), local: SyncSnapshot(deviceID: b), remote: published)
            var edited = item; edited.starred = true
            try second.captureTasks([edited])
            _ = try PlusSyncFolderIO.publish(second, folder: folder)
            let peers = try PlusSyncFolderIO.read(folder: folder)
            XCTAssertEqual(Set(peers.map(\.deviceID)), [a, b])
            XCTAssertEqual(try Data(contentsOf: target(in: folder, device: a)), originalBytes, "A second Mac must never rewrite the first Mac’s file")
            let merged = try SyncMerge.threeWay(base: first, local: first, remote: second)
            XCTAssertEqual(merged.note.preferred(on: a), "Original")
            XCTAssertTrue(try XCTUnwrap(merged.visibleTasks().first).starred)
            let attributes = try FileManager.default.attributesOfItem(atPath: target(in: folder, device: b).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testCorruptSharedFileRejectsReadAndPublishWithoutReplacingOriginal() throws {
        try withFolder { folder in
            let device = UUID(), file = try target(in: folder, device: device)
            let original = Data("{broken-json".utf8)
            try original.write(to: file)
            XCTAssertThrowsError(try PlusSyncFolderIO.read(folder: folder))
            XCTAssertThrowsError(try PlusSyncFolderIO.publish(snapshot(device), folder: folder))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testOversizedSharedFileRejectsReadAndPublishWithoutReplacingOriginal() throws {
        try withFolder { folder in
            let device = UUID(), file = try target(in: folder, device: device)
            let original = Data(repeating: 65, count: SyncSnapshot.maximumBytes + 1)
            try original.write(to: file)
            XCTAssertThrowsError(try PlusSyncFolderIO.read(folder: folder))
            XCTAssertThrowsError(try PlusSyncFolderIO.publish(snapshot(device), folder: folder))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testFileIdentityMismatchRejectsReadAndPublishPreservingValidOtherDeviceData() throws {
        try withFolder { folder in
            let device = UUID(), file = try target(in: folder, device: device)
            let other = try snapshot(UUID(), text: "Other device’s original")
            let original = try other.encoded(); try original.write(to: file)
            XCTAssertThrowsError(try PlusSyncFolderIO.read(folder: folder))
            XCTAssertThrowsError(try PlusSyncFolderIO.publish(snapshot(device), folder: folder))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testRegularAndDanglingSnapshotSymlinksNeverReplaceTheirTargetsOrLinks() throws {
        for dangling in [false, true] {
            try withFolder { folder in
                let device = UUID(), file = try target(in: folder, device: device)
                let external = folder.appendingPathComponent("outside.json")
                let original = try snapshot(device, text: "Keep external original").encoded()
                if !dangling { try original.write(to: external) }
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
                XCTAssertThrowsError(try PlusSyncFolderIO.read(folder: folder))
                XCTAssertThrowsError(try PlusSyncFolderIO.publish(snapshot(device), folder: folder))
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), external.path)
                if !dangling { XCTAssertEqual(try Data(contentsOf: external), original) }
                else { XCTAssertFalse(FileManager.default.fileExists(atPath: external.path)) }
            }
        }
    }

    func testSymlinkDataDirectoryIsRejectedWithoutWritingThroughIt() throws {
        try withFolder { folder in
            let external = folder.appendingPathComponent("other-folder", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
            let link = folder.appendingPathComponent("NotchOrbitPlusSync", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
            XCTAssertThrowsError(try PlusSyncFolderIO.read(folder: folder))
            XCTAssertThrowsError(try PlusSyncFolderIO.publish(snapshot(UUID()), folder: folder))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), external.path)
        }
    }

    func testPublicationRereadsExistingOwnFileAndPreservesConcurrentProviderEdit() throws {
        try withFolder { folder in
            let device = UUID(), peer = UUID()
            let base = try snapshot(device, text: "Base")
            _ = try PlusSyncFolderIO.publish(base, folder: folder)
            var pending = base; try pending.captureNote("Pending local draft")
            var remote = try SyncMerge.threeWay(base: SyncSnapshot(deviceID: peer), local: SyncSnapshot(deviceID: peer), remote: base)
            try remote.captureNote("Concurrent provider draft")
            let providerCopy = try SyncMerge.threeWay(base: base, local: base, remote: remote)
            try providerCopy.encoded().write(to: target(in: folder, device: device), options: .atomic)
            let published = try PlusSyncFolderIO.publish(pending, folder: folder)
            XCTAssertEqual(Set(published.note.revisions.map(\.value)), ["Pending local draft", "Concurrent provider draft"])
            XCTAssertTrue(published.note.hasConflict)
            let stored = try SyncSnapshot.decode(Data(contentsOf: target(in: folder, device: device)))
            XCTAssertEqual(stored, published)
        }
    }

    @MainActor
    func testCorruptLocalLegacyFilePreventsAnyNoteTaskOrMetadataReplacement() throws {
        try withFolder { folder in
            let device = UUID(), base = try snapshot(device, text: "Keep local note")
            let note = folder.appendingPathComponent("quick-note.txt"), tasks = folder.appendingPathComponent("todos.json")
            let ledger = folder.appendingPathComponent("sync-state-v1.json")
            let noteBytes = Data("Keep local note".utf8), taskBytes = Data("{broken-tasks".utf8), ledgerBytes = try base.encoded()
            try noteBytes.write(to: note); try taskBytes.write(to: tasks); try ledgerBytes.write(to: ledger)
            var incoming = base; try incoming.captureNote("Incoming replacement")
            XCTAssertThrowsError(try LocalToolStorage.applySyncState(incoming, in: folder))
            XCTAssertEqual(try Data(contentsOf: note), noteBytes)
            XCTAssertEqual(try Data(contentsOf: tasks), taskBytes)
            XCTAssertEqual(try Data(contentsOf: ledger), ledgerBytes)
        }
    }
}
