import Foundation

/// The fixed catalog keeps wheel positions and learned action identifiers stable.
public enum ActionRegistry {
    public static let all: [ActionDescriptor] = [
        .init(.jpeg, "JPEG", "photo", category: "Convert", detail: "JPEG · quality from Settings"),
        .init(.png, "PNG", "photo", category: "Convert", detail: "PNG · lossless"),
        .init(.heic, "HEIC", "photo", category: "Convert", detail: "HEIC · compact"),
        .init(.webp, "WebP", "photo", category: "Convert", detail: "WebP · quality from Settings"),
        .init(.compressImage, "Compress Image", "arrow.down.right.and.arrow.up.left", category: "Compress", detail: "Save a smaller copy"),
        .init(.resize1600, "Resize to 1600 px", "arrow.up.left.and.arrow.down.right", category: "Resize", detail: "Longest edge · never upscale"),
        .init(.removeMetadata, "Remove Metadata", "shield", category: "Privacy", detail: "Keep display color and orientation"),
        .init(.removeGPS, "Remove GPS", "location.slash", category: "Privacy", detail: "Remove location metadata"),
        .init(.imagesToPDF, "Images to PDF", "doc.richtext", category: "PDF", detail: "One page per image"),
        .init(.mergePDF, "Merge PDFs", "doc.on.doc", category: "PDF", detail: "Combine in selection order"),
        .init(.splitPDF, "Split PDF", "rectangle.split.2x1", category: "PDF", detail: "One file per page"),
        .init(.pdfToPNG, "PDF to PNG", "photo.on.rectangle", category: "Convert", detail: "Render each page"),
        .init(.videoMP4, "Convert to MP4", "film", category: "Convert", detail: "Native H.264-compatible export"),
        .init(.compressVideo, "Compress Video", "arrow.down.right.and.arrow.up.left", category: "Compress", detail: "Smaller native preset"),
        .init(.extractAudio, "Extract Audio", "waveform", category: "Audio", detail: "M4A · requires an audio track"),
        .init(.audioM4A, "Convert to M4A", "waveform", category: "Convert", detail: "Native AAC audio"),
        .init(.zip, "Create ZIP", "archivebox", category: "Files", detail: "Archive files and folders"),
        .init(.unzip, "Extract ZIP", "archivebox", category: "Files", detail: "Validated, bounded extraction"),
        .init(.checksum, "SHA-256 Checksum", "number", category: "Files", detail: "Write a checksum text file"),
        .init(.duplicate, "Duplicate", "doc.on.doc", category: "Files", detail: "Create a separate copy"),
        .init(.formatJSON, "Format JSON", "curlybraces", category: "Text", detail: "Readable indentation"),
        .init(.minifyJSON, "Minify JSON", "curlybraces", category: "Text", detail: "Compact valid JSON"),
        .init(.ocr, "Extract Text", "text.viewfinder", category: "Text", detail: "Local Apple Vision OCR")
    ]

    public static func descriptor(for id: ActionID) -> ActionDescriptor? {
        all.first { $0.id == id }
    }
}

public enum ActionResolver {
    public static func actions(for items: [FileItem], webPAvailable: Bool = true) -> [ActionDescriptor] {
        guard let first = items.first else { return [] }
        let homogeneous = items.allSatisfy { $0.kind == first.kind }
        var ids: [ActionID] = []
        if homogeneous {
            switch first.kind {
            case .image:
                ids = [.jpeg, .png, .heic]
                if webPAvailable { ids.append(.webp) }
                if items.allSatisfy({ sourceImageFormat($0) != nil && sourceImageFormat($0) != "tiff" }) {
                    ids.append(.compressImage)
                }
                if items.allSatisfy({ sourceImageFormat($0) != nil }) {
                    ids += [.resize1600, .removeMetadata]
                    if items.allSatisfy({ sourceImageFormat($0) != "webp" }) { ids.append(.removeGPS) }
                }
                ids += [.imagesToPDF, .ocr]
            case .pdf:
                if items.count > 1 { ids.append(.mergePDF) }
                ids += [.splitPDF, .pdfToPNG, .ocr]
            case .video:
                if items.allSatisfy(isNativeVideo) { ids = [.videoMP4, .compressVideo, .extractAudio] }
            case .audio:
                if items.allSatisfy(isNativeAudio) { ids = [.audioM4A] }
            case .archive:
                if items.count == 1, isZIP(first) { ids = [.unzip] }
            case .json:
                ids = [.formatJSON, .minifyJSON]
            case .text, .folder, .other:
                break
            }
        }
        ids.append(.zip)
        if items.allSatisfy({ $0.kind != .folder }) {
            ids += [.checksum, .duplicate]
        }
        return ids.compactMap(ActionRegistry.descriptor(for:))
    }

    private static func isZIP(_ item: FileItem) -> Bool {
        item.url.pathExtension.lowercased() == "zip" || item.typeIdentifier == "com.pkware.zip-archive"
    }

    private static func sourceImageFormat(_ item: FileItem) -> String? {
        switch item.typeIdentifier {
        case "public.jpeg": return "jpeg"
        case "public.png": return "png"
        case "public.heic", "public.heif": return "heic"
        case "org.webmproject.webp": return "webp"
        case "public.tiff": return "tiff"
        default:
            switch item.url.pathExtension.lowercased() {
            case "jpg", "jpeg": return "jpeg"
            case "png": return "png"
            case "heic", "heif": return "heic"
            case "webp": return "webp"
            case "tif", "tiff": return "tiff"
            default: return nil
            }
        }
    }

    private static func isNativeVideo(_ item: FileItem) -> Bool {
        ["mov", "mp4", "m4v"].contains(item.url.pathExtension.lowercased()) ||
        ["com.apple.quicktime-movie", "public.mpeg-4", "com.apple.m4v-video"].contains(item.typeIdentifier)
    }

    private static func isNativeAudio(_ item: FileItem) -> Bool {
        ["mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac"].contains(item.url.pathExtension.lowercased()) ||
        ["public.mp3", "public.mpeg-4-audio", "com.apple.m4a-audio", "public.aac-audio",
         "com.microsoft.waveform-audio", "public.aiff-audio", "com.apple.coreaudio-format", "org.xiph.flac"].contains(item.typeIdentifier)
    }
}
