import Foundation
import XCTest
@testable import OrbitCore

final class ActionResolverTests: XCTestCase {
    private func item(_ filename: String, _ kind: FileKind) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/fixtures/\(filename)"), kind: kind)
    }

    private func ids(_ items: [FileItem], webPAvailable: Bool = true) -> [ActionID] {
        ActionResolver.actions(for: items, webPAvailable: webPAvailable).map(\.id)
    }

    func testEmptySelectionHasNoActions() {
        XCTAssertEqual(ids([]), [])
    }

    func testImageBatchSupportsConversionsAndPrivacy() {
        let result = ids([item("one.jpg", .image), item("two.png", .image)])
        for action: ActionID in [.jpeg, .png, .heic, .webp, .compressImage, .resize1600,
                                .removeMetadata, .removeGPS, .imagesToPDF, .ocr] {
            XCTAssertTrue(result.contains(action), "Missing \(action)")
        }
        XCTAssertFalse(result.contains(.mergePDF))
        XCTAssertFalse(result.contains(.videoMP4))
        XCTAssertEqual(Set(result).count, result.count)
    }

    func testUnavailableCodecIsNeverOffered() {
        let selection = [item("photo.jpg", .image)]
        XCTAssertFalse(ids(selection, webPAvailable: false).contains(.webp))
        XCTAssertTrue(ids(selection).contains(.webp))
    }

    func testSelectiveWebPPrivacyAndUnsupportedSourceCompressionAreHidden() {
        let webp = ids([item("photo.webp", .image)])
        XCTAssertFalse(webp.contains(.removeGPS))
        XCTAssertTrue(webp.contains(.removeMetadata))
        let tiff = ids([item("photo.tiff", .image)])
        XCTAssertFalse(tiff.contains(.compressImage))
        XCTAssertTrue(tiff.contains(.resize1600))
        XCTAssertTrue(tiff.contains(.removeGPS))
        let gif = ids([item("still.gif", .image)])
        XCTAssertFalse(gif.contains(.compressImage))
        XCTAssertFalse(gif.contains(.resize1600))
        XCTAssertTrue(gif.contains(.png))
    }

    func testMergeRequiresAtLeastTwoPDFs() {
        let one = item("one.pdf", .pdf)
        XCTAssertFalse(ids([one]).contains(.mergePDF))
        let many = ids([one, item("two.pdf", .pdf)])
        XCTAssertTrue(many.contains(.mergePDF))
        XCTAssertTrue(many.contains(.splitPDF))
        XCTAssertTrue(many.contains(.pdfToPNG))
        XCTAssertFalse(many.contains(.imagesToPDF))
    }

    func testMixedTypesOfferOnlyUniversalFileOperations() {
        XCTAssertEqual(ids([item("photo.jpg", .image), item("document.pdf", .pdf)]),
                       [.zip, .checksum, .duplicate])
    }

    func testDirectoriesCannotReachRegularFileEngines() {
        XCTAssertEqual(ids([item("folder", .folder)]), [.zip])
        XCTAssertEqual(ids([item("folder", .folder), item("photo.jpg", .image)]), [.zip])
    }

    func testExtractionIsLimitedToOneZIP() {
        XCTAssertTrue(ids([item("one.ZIP", .archive)]).contains(.unzip))
        XCTAssertFalse(ids([item("one.tar", .archive)]).contains(.unzip))
        XCTAssertFalse(ids([item("one.zip", .archive), item("two.zip", .archive)]).contains(.unzip))
        let typed = FileItem(url: URL(fileURLWithPath: "/fixtures/no-extension"), kind: .archive,
                             typeIdentifier: "com.pkware.zip-archive")
        XCTAssertTrue(ids([typed]).contains(.unzip))
    }

    func testMediaAndJSONCapabilitiesDoNotCrossTypes() {
        let video = ids([item("clip.mov", .video)])
        XCTAssertTrue(video.contains(.videoMP4))
        XCTAssertTrue(video.contains(.compressVideo))
        XCTAssertTrue(video.contains(.extractAudio))
        XCTAssertFalse(video.contains(.audioM4A))
        let audio = ids([item("sound.wav", .audio)])
        XCTAssertTrue(audio.contains(.audioM4A))
        XCTAssertFalse(audio.contains(.extractAudio))
        let json = ids([item("data.json", .json)])
        XCTAssertTrue(json.contains(.formatJSON))
        XCTAssertTrue(json.contains(.minifyJSON))
        XCTAssertFalse(ids([item("note.txt", .text)]).contains(.formatJSON))
    }

    func testContainersWithoutNativeDecoderAreNotOfferedMediaActions() {
        for filename in ["clip.mkv", "clip.webm", "clip.avi"] {
            XCTAssertEqual(ids([item(filename, .video)]), [.zip, .checksum, .duplicate])
        }
        for filename in ["sound.ogg", "sound.opus"] {
            XCTAssertEqual(ids([item(filename, .audio)]), [.zip, .checksum, .duplicate])
        }
    }

    func testRegistryCoversEveryImplementedIdentifierExactlyOnce() {
        XCTAssertEqual(Set(ActionRegistry.all.map(\.id)), Set(ActionID.allCases))
        XCTAssertEqual(ActionRegistry.all.count, ActionID.allCases.count)
        for descriptor in ActionRegistry.all {
            XCTAssertFalse(descriptor.title.isEmpty)
            XCTAssertFalse(descriptor.symbol.isEmpty)
            XCTAssertEqual(ActionRegistry.descriptor(for: descriptor.id), descriptor)
        }
    }

    func testResolutionOrderIsStableAcrossEquivalentBatches() {
        XCTAssertEqual(ids([item("a.jpg", .image)]),
                       ids([item("z.heic", .image), item("b.png", .image)]))
    }
}
