import Foundation
import XCTest
@testable import NotchCore

final class CoreColorPaletteTests: XCTestCase {
    func testComponentsRejectNonfiniteAndOutOfRangeValuesIncludingDecodedInput() throws {
        for value in [Double.nan, .infinity, -.infinity, -0.0001, 1.0001] {
            XCTAssertThrowsError(try CoreColorRGBA(red: value, green: 0, blue: 0))
            XCTAssertThrowsError(try CoreColorRGBA(red: 0, green: value, blue: 0))
            XCTAssertThrowsError(try CoreColorRGBA(red: 0, green: 0, blue: value))
            XCTAssertThrowsError(try CoreColorRGBA(red: 0, green: 0, blue: 0, alpha: value))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(CoreColorRGBA.self,
            from: Data(#"{"red":1.1,"green":0,"blue":0,"alpha":1}"#.utf8)))
        XCTAssertEqual(try CoreColorRGBA(red: -0.0, green: 0, blue: 0).red.sign, .plus)
    }
    func testPrimaryColorsAndTransparencyFormatDeterministically() throws {
        let red = try CoreColorRGBA(red: 1, green: 0, blue: 0)
        XCTAssertEqual(red.formatted(.hex), "#FF0000")
        XCTAssertEqual(red.formatted(.rgb), "rgb(255, 0, 0)")
        XCTAssertEqual(red.formatted(.hsl), "hsl(0, 100%, 50%)")
        XCTAssertEqual(red.formatted(.swiftUI), "Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)")
        XCTAssertEqual(red.formatted(.nsColor), "NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)")
        let alpha = try CoreColorRGBA(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.5)
        XCTAssertEqual(alpha.hex, "#1A334D80")
        XCTAssertEqual(alpha.formatted(.rgb), "rgba(26, 51, 77, 0.5)")
        XCTAssertEqual(alpha.formatted(.hsl), "hsla(210, 50%, 20%, 0.5)")
        let fractional = try CoreColorRGBA(red: 1 / 3, green: 0, blue: 0, alpha: 0)
        XCTAssertTrue(fractional.formatted(.swiftUI).contains("red: 0.333333"))
    }
    func testHSLHueSectorsAndAchromaticEndpoints() throws {
        for (r, g, b, hue) in [(1.0, 1.0, 0.0, 60), (0, 1, 0, 120), (0, 1, 1, 180),
                                (0, 0, 1, 240), (1, 0, 1, 300)] {
            XCTAssertEqual(try CoreColorRGBA(red: r, green: g, blue: b).formatted(.hsl), "hsl(\(hue), 100%, 50%)")
        }
        XCTAssertEqual(try CoreColorRGBA(red: 0, green: 0, blue: 0).formatted(.hsl), "hsl(0, 0%, 0%)")
        XCTAssertEqual(try CoreColorRGBA(red: 1, green: 1, blue: 1).formatted(.hsl), "hsl(0, 0%, 100%)")
        XCTAssertEqual(try CoreColorRGBA(red: 0.5, green: 0.5, blue: 0.5).formatted(.hsl), "hsl(0, 0%, 50%)")
    }
    func testPaletteExportRoundTripsAndRejectsUnsupportedOrOversizedData() throws {
        let color = try CoreColorRGBA(red: 0.2, green: 0.4, blue: 0.6)
        let palette = try CoreColorPalette(name: "  Product Blues  ", colors: [color])
        XCTAssertEqual(palette.name, "Product Blues")
        let library = try CoreColorPaletteLibrary(palettes: [palette])
        let data = try library.encoded()
        XCTAssertEqual(try CoreColorPaletteLibrary.decode(data), library)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("history"))
        XCTAssertThrowsError(try CoreColorPaletteLibrary.decode(Data(#"{"schemaVersion":2,"palettes":[]}"#.utf8)))
        XCTAssertThrowsError(try CoreColorPaletteLibrary.decode(Data(repeating: 32, count: CoreColorPaletteLibrary.maximumBytes + 1)))
        XCTAssertThrowsError(try CoreColorPaletteLibrary(palettes: [palette, palette]))
    }
    func testNamesAndCollectionBoundsPreventUnboundedPayloads() throws {
        for name in ["", " \n ", "bad\u{0000}name", "line\nname", String(repeating: "x", count: 81)] {
            XCTAssertThrowsError(try CoreColorPalette(name: name))
        }
        let color = try CoreColorRGBA(red: 0, green: 1, blue: 1)
        XCTAssertNoThrow(try CoreColorPalette(name: "Limit", colors: Array(repeating: color, count: 64)))
        XCTAssertThrowsError(try CoreColorPalette(name: "Over", colors: Array(repeating: color, count: 65)))
        let palettes = try (0..<33).map { try CoreColorPalette(name: "Palette \($0)") }
        XCTAssertNoThrow(try CoreColorPaletteLibrary(palettes: Array(palettes.prefix(32))))
        XCTAssertThrowsError(try CoreColorPaletteLibrary(palettes: palettes))
        XCTAssertNoThrow(try CoreColorPickerState(history: Array(repeating: color, count: 80), library: CoreColorPaletteLibrary()))
        XCTAssertThrowsError(try CoreColorPickerState(history: Array(repeating: color, count: 81), library: CoreColorPaletteLibrary()))
    }
}
