import Foundation
import ImageIO
import UniformTypeIdentifiers
import OrbitCore

/// Reads resource information and a small signature before presenting file-specific actions.
enum FileInspector {
    static func inspect(_ urls: [URL]) throws -> [FileItem] {
        try Task.checkCancellation()
        var seen = Set<URL>()
        return try urls.compactMap { original in
            try Task.checkCancellation()
            guard original.isFileURL else { throw OrbitError.invalidInput("Drop local files or folders into Orbit.") }
            let url = original.standardizedFileURL
            guard seen.insert(url).inserted else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey])
            guard values.isSymbolicLink != true else {
                throw OrbitError.invalidInput("Symbolic links are not processed. Drop the original file instead: \(url.lastPathComponent)")
            }
            if values.isDirectory == true { return FileItem(url: url, kind: .folder, typeIdentifier: UTType.folder.identifier) }
            guard values.isRegularFile == true else { throw OrbitError.invalidInput("This is not a regular file: \(url.lastPathComponent)") }
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw OrbitError.invalidInput("Orbit cannot read \(url.lastPathComponent).") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 4096) ?? Data()
            let size = Int64(values.fileSize ?? 0)
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
            let detection = detect(url: url, header: header, suggested: type)
            let summary = detection.0 == .image ? inspectPrivacy(url: url, typeIdentifier: detection.1) : nil
            try Task.checkCancellation()
            return FileItem(url: url, kind: detection.0, byteCount: size, typeIdentifier: detection.1, privacySummary: summary)
        }
    }

    /// Checks standard structured tags only. Values, coordinates, and private text never leave this scope.
    private static func inspectPrivacy(url: URL, typeIdentifier: String) -> String {
        guard typeIdentifier != "org.webmproject.webp" else { return "WebP metadata uninspected" }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return "Metadata inspection unavailable"
        }
        guard CGImageSourceGetCount(source) == 1 else { return "Multi-frame metadata uninspected" }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return "Metadata inspection unavailable" }
        var categories = [String]()
        if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any], !gps.isEmpty {
            categories.append("GPS tags")
        }
        let exifKeys = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
                        kCGImagePropertyExifUserComment, kCGImagePropertyExifMakerNote,
                        kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifBodySerialNumber,
                        kCGImagePropertyExifLensSerialNumber, kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel]
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
           exifKeys.contains(where: { exif[$0 as String] != nil }) {
            categories.append("EXIF details")
        }
        let tiffKeys = [kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFMake,
                        kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFDateTime,
                        kCGImagePropertyTIFFImageDescription]
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           tiffKeys.contains(where: { tiff[$0 as String] != nil }) {
            categories.append("TIFF details")
        }
        return categories.isEmpty ? "No GPS tag found" : categories.joined(separator: " · ")
    }

    private static func detect(url: URL, header: Data, suggested: UTType?) -> (FileKind, String) {
        let bytes = [UInt8](header)
        func begins(_ signature: [UInt8]) -> Bool { bytes.starts(with: signature) }
        func ascii(_ range: Range<Int>) -> String {
            guard range.upperBound <= bytes.count else { return "" }
            return String(bytes: bytes[range], encoding: .ascii) ?? ""
        }
        if header.prefix(1024).range(of: Data("%PDF-".utf8)) != nil { return (.pdf, UTType.pdf.identifier) }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WEBP" { return (.image, "org.webmproject.webp") }
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0, let identifier = CGImageSourceGetType(source) {
            return (.image, identifier as String)
        }
        if begins([0x50, 0x4b, 0x03, 0x04]) || begins([0x50, 0x4b, 0x05, 0x06]) || begins([0x50, 0x4b, 0x07, 0x08]) { return (.archive, UTType.zip.identifier) }
        if begins([0x1f, 0x8b]) { return (.archive, "org.gnu.gnu-zip-archive") }
        if begins([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) || begins([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07]) { return (.archive, suggested?.identifier ?? "public.archive") }
        if ascii(257..<262) == "ustar" { return (.archive, "public.tar-archive") }
        if ascii(0..<4) == "fLaC" || ascii(0..<3) == "ID3" || (ascii(0..<4) == "RIFF" && ascii(8..<12) == "WAVE") { return (.audio, suggested?.identifier ?? UTType.audio.identifier) }
        if ascii(4..<8) == "ftyp" || begins([0x1a, 0x45, 0xdf, 0xa3]) || (ascii(0..<4) == "RIFF" && ascii(8..<12) == "AVI ") {
            return (suggested?.conforms(to: .audio) == true ? .audio : .video, suggested?.identifier ?? UTType.movie.identifier)
        }
        if ascii(0..<4) == "OggS" { return (suggested?.conforms(to: .movie) == true ? .video : .audio, suggested?.identifier ?? UTType.audio.identifier) }
        // UTType supplies formats without a practical short magic number, such as MP3 and text.
        if suggested?.conforms(to: .audio) == true { return (.audio, suggested!.identifier) }
        if suggested?.conforms(to: .movie) == true { return (.video, suggested!.identifier) }
        if suggested?.conforms(to: .json) == true { return (.json, suggested!.identifier) }
        if suggested?.conforms(to: .text) == true { return (.text, suggested!.identifier) }
        return (.other, suggested?.identifier ?? UTType.data.identifier)
    }
}
