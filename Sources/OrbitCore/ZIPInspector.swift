import Foundation

/// Validates classic ZIP metadata before extraction by a native backend.
public enum ZIPInspector {
    public struct Inventory { public let expandedBytes: Int64; public let entryCount: Int }
    private struct Entry { let start: Int; let end: Int; let path: String; let directory: Bool }
    public static let maximumEntries = 10_000
    public static let maximumExpandedBytes: Int64 = 2_147_483_648
    public static let maximumEntryBytes: UInt32 = 536_870_912
    public static let maximumRatio: UInt64 = 200

    public static func inspect(_ url: URL) throws -> Inventory {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 else { throw invalid("This is not a complete ZIP file.") }
        var endOffset: Int?
        let lower = max(0, data.count - 22 - 65_535)
        for offset in stride(from: data.count - 22, through: lower, by: -1) {
            if try u32(data, offset) == 0x06054b50,
               offset + 22 + Int(try u16(data, offset + 20)) == data.count {
                endOffset = offset
                break
            }
        }
        guard let endOffset else { throw invalid("The ZIP directory is missing or damaged.") }
        let disk = try u16(data, endOffset + 4)
        let directoryDisk = try u16(data, endOffset + 6)
        let diskCount = try u16(data, endOffset + 8)
        let count = try u16(data, endOffset + 10)
        let directorySize = try u32(data, endOffset + 12)
        let directoryOffset = try u32(data, endOffset + 16)
        guard disk == 0, directoryDisk == 0, diskCount == count,
              count != UInt16.max, directorySize != UInt32.max, directoryOffset != UInt32.max else {
            throw invalid("Split and ZIP64 archives are not supported.")
        }
        guard Int(count) <= maximumEntries else { throw invalid("This ZIP contains too many entries.") }
        let centralStart = Int(directoryOffset)
        let centralEnd = centralStart + Int(directorySize)
        guard centralStart <= endOffset, centralEnd == endOffset else {
            throw invalid("The ZIP directory has inconsistent offsets.")
        }
        var cursor = centralStart
        var entries: [Entry] = []
        var paths: [String: Bool] = [:]
        var expanded: Int64 = 0
        var compressed: UInt64 = 0
        for _ in 0..<Int(count) {
            guard cursor + 46 <= centralEnd, try u32(data, cursor) == 0x02014b50 else {
                throw invalid("The ZIP directory is damaged.")
            }
            let flags = try u16(data, cursor + 8)
            let method = try u16(data, cursor + 10)
            let crc = try u32(data, cursor + 16)
            let packed = try u32(data, cursor + 20)
            let unpacked = try u32(data, cursor + 24)
            let nameLength = Int(try u16(data, cursor + 28))
            let extraLength = Int(try u16(data, cursor + 30))
            let commentLength = Int(try u16(data, cursor + 32))
            let startDisk = try u16(data, cursor + 34)
            let external = try u32(data, cursor + 38)
            let localOffset = try u32(data, cursor + 42)
            guard startDisk == 0, packed != UInt32.max, unpacked != UInt32.max, localOffset != UInt32.max,
                  flags & ~UInt16(0x080e) == 0, method == 0 || method == 8 else {
                throw invalid("Encrypted, split, or unsupported ZIP entries cannot be extracted.")
            }
            guard unpacked <= maximumEntryBytes,
                  UInt64(unpacked) <= max(1, UInt64(packed)) * maximumRatio,
                  method != 0 || packed == unpacked else {
                throw invalid("This ZIP exceeds safe extraction size or compression limits.")
            }
            expanded += Int64(unpacked)
            compressed += UInt64(packed)
            guard expanded <= maximumExpandedBytes else { throw invalid("This ZIP expands beyond the 2 GB safety limit.") }
            let recordEnd = cursor + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, recordEnd <= centralEnd else { throw invalid("The ZIP entry name is damaged.") }
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let name = String(data: nameData, encoding: .utf8),
                  flags & 0x0800 != 0 || nameData.allSatisfy({ $0 < 0x80 }) else {
                throw invalid("This ZIP uses an ambiguous filename encoding.")
            }
            let isDirectory = name.hasSuffix("/")
            let path = try safePath(name)
            let key = collisionKey(path)
            guard paths[key] == nil else { throw invalid("This ZIP contains conflicting filenames.") }
            paths[key] = isDirectory
            let unixMode = UInt16(external >> 16)
            let fileType = unixMode & 0xf000
            guard fileType == 0 || fileType == 0x8000 || fileType == 0x4000,
                  unixMode & 0x0e00 == 0,
                  fileType != 0x4000 || isDirectory,
                  fileType != 0x8000 || !isDirectory,
                  external & 0x10 == 0 || isDirectory,
                  !isDirectory || unpacked == 0 else {
                throw invalid("Links, special files, or privileged permissions are not allowed in ZIP archives.")
            }
            try validateExtra(data, start: cursor + 46 + nameLength, length: extraLength)
            let local = Int(localOffset)
            guard local + 30 <= centralStart, try u32(data, local) == 0x04034b50,
                  try u16(data, local + 6) == flags, try u16(data, local + 8) == method else {
                throw invalid("The ZIP entry headers disagree.")
            }
            let localNameLength = Int(try u16(data, local + 26))
            let localExtraLength = Int(try u16(data, local + 28))
            let body = local + 30 + localNameLength + localExtraLength
            guard localNameLength == nameLength, body <= centralStart,
                  data.subdata(in: local + 30..<local + 30 + localNameLength) == nameData else {
                throw invalid("The ZIP entry paths disagree.")
            }
            try validateExtra(data, start: local + 30 + localNameLength, length: localExtraLength)
            let localCRC = try u32(data, local + 14)
            let localPacked = try u32(data, local + 18)
            let localUnpacked = try u32(data, local + 22)
            let hasDescriptor = flags & 0x0008 != 0
            guard (localCRC == crc || hasDescriptor && localCRC == 0),
                  (localPacked == packed || hasDescriptor && localPacked == 0),
                  (localUnpacked == unpacked || hasDescriptor && localUnpacked == 0) else {
                throw invalid("The ZIP entry sizes disagree.")
            }
            var memberEnd = body + Int(packed)
            guard memberEnd <= centralStart else { throw invalid("The ZIP entry extends outside its data area.") }
            if hasDescriptor {
                var descriptor = memberEnd
                if try u32(data, descriptor) == 0x08074b50 { descriptor += 4 }
                guard descriptor + 12 <= centralStart, try u32(data, descriptor) == crc,
                      try u32(data, descriptor + 4) == packed, try u32(data, descriptor + 8) == unpacked else {
                    throw invalid("The ZIP data descriptor is inconsistent.")
                }
                memberEnd = descriptor + 12
            }
            entries.append(Entry(start: local, end: memberEnd, path: path, directory: isDirectory))
            cursor = recordEnd
        }
        guard cursor == centralEnd, UInt64(expanded) <= max(1, compressed) * maximumRatio else {
            throw invalid("This ZIP exceeds safe extraction limits or has unexpected records.")
        }
        var expectedOffset = 0
        for entry in entries.sorted(by: { $0.start < $1.start }) {
            guard entry.start == expectedOffset else { throw invalid("This ZIP contains overlapping or hidden data records.") }
            expectedOffset = entry.end
            var components = entry.path.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                if paths[collisionKey(components.joined(separator: "/"))] == false {
                    throw invalid("A ZIP file conflicts with an extraction folder.")
                }
            }
        }
        guard expectedOffset == centralStart else { throw invalid("This ZIP contains unexpected data before its directory.") }
        return Inventory(expandedBytes: expanded, entryCount: Int(count))
    }

    public static func safePath(_ name: String) throws -> String {
        let path = name.hasSuffix("/") ? String(name.dropLast()) : name
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              path.utf8.count <= 1_024, components.count <= 32,
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw invalid("This ZIP contains an unsafe extraction path.")
        }
        return path.precomposedStringWithCanonicalMapping
    }

    private static func collisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func validateExtra(_ data: Data, start: Int, length: Int) throws {
        let end = start + length
        guard end <= data.count else { throw invalid("The ZIP metadata is truncated.") }
        var cursor = start
        while cursor < end {
            guard cursor + 4 <= end else { throw invalid("The ZIP metadata is malformed.") }
            let kind = try u16(data, cursor)
            let size = Int(try u16(data, cursor + 2))
            guard cursor + 4 + size <= end else { throw invalid("The ZIP metadata is truncated.") }
            // Unicode path overrides, ZIP64, Unix link metadata, and unknown
            // extensions can change extractor behavior; fail closed.
            guard kind == 0x5455 || kind == 0x7875 || kind == 0x5855 || kind == 0x000d else {
                throw invalid("This ZIP contains unsupported or unsafe extra metadata.")
            }
            if kind == 0x5855, size != 8, size != 12 {
                throw invalid("This ZIP contains unsupported Unix metadata.")
            }
            // PKWARE Unix records are timestamps/UID/GID only at exactly 12
            // bytes; additional data may encode a symbolic or hard-link target.
            if kind == 0x000d, size != 12 { throw invalid("ZIP link metadata is not allowed.") }
            cursor += 4 + size
        }
    }

    private static func u16(_ data: Data, _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw invalid("The ZIP file is truncated.") }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private static func u32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw invalid("The ZIP file is truncated.") }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    private static func invalid(_ message: String) -> OrbitError { .invalidInput(message) }
}
