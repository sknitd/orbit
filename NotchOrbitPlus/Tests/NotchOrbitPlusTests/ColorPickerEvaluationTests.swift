import AppKit
import SwiftUI
import XCTest
import NotchCore
@testable import NotchOrbitPlus

final class ColorPickerEvaluationTests: NativeImageFixtureCase, @unchecked Sendable {
    @MainActor
    func testActualNSColorConvertsToSRGBAndCopiesEverySupportedFormat() throws {
        let native = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        let color = try CoreColorRGBA.fromNSColor(native)
        XCTAssertEqual(color.red, 0.2, accuracy: 0.000001)
        XCTAssertEqual(color.green, 0.4, accuracy: 0.000001)
        XCTAssertEqual(color.blue, 0.6, accuracy: 0.000001)
        XCTAssertEqual(color.alpha, 0.5, accuracy: 0.000001)
        XCTAssertEqual(color.hex, "#33669980")
        let store = ColorPickerStore(persistHistory: false)
        let board = NSPasteboard(name: .init("NotchOrbitPlus.ColorPicker.\(UUID().uuidString)"))
        defer { board.releaseGlobally(); store.shutdown() }
        try store.record(color)
        for format in CoreColorFormat.allCases {
            store.format = format; store.copySelected(to: board)
            XCTAssertEqual(board.string(forType: .string), color.formatted(format))
        }
        let p3 = NSColor(displayP3Red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        let expected = try XCTUnwrap(p3.usingColorSpace(.sRGB))
        let converted = try CoreColorRGBA.fromNSColor(p3)
        XCTAssertEqual(converted.red, Double(expected.redComponent), accuracy: 0.000001)
        XCTAssertEqual(converted.green, Double(expected.greenComponent), accuracy: 0.000001)
        XCTAssertEqual(converted.blue, Double(expected.blueComponent), accuracy: 0.000001)
    }

    @MainActor
    func testHiddenPickerIgnoresLateCompletionWithoutOpeningSystemSampler() async throws {
        var completion: (@Sendable (CoreColorRGBA?) -> Void)?
        let store = ColorPickerStore(persistHistory: false, sampling: { completion = $0 })
        XCTAssertNil(completion, "Construction must not sample the screen")
        store.start(); XCTAssertNil(completion)
        store.pick(); XCTAssertTrue(store.isPicking)
        let finish = try XCTUnwrap(completion)
        store.shutdown()
        finish(try CoreColorRGBA.fromNSColor(.red))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(store.isPicking)
        XCTAssertTrue(store.history.isEmpty)
    }

    @MainActor
    func testSyncPreservesHistoryAndFailedPersistenceLeavesExistingStateUntouched() throws {
        let color = try CoreColorRGBA.fromNSColor(.blue)
        let initial = try CoreColorPickerState(history: [color], library: CoreColorPaletteLibrary())
        let payload = try CoreColorPaletteLibrary(palettes: [CoreColorPalette(name: "Synced", colors: [color])]).encoded()
        let store = ColorPickerStore(persistHistory: false, initialState: initial)
        try store.applySyncedData(payload)
        XCTAssertEqual(store.history, [color])
        XCTAssertEqual(try CoreColorPaletteLibrary.decode(store.exportData()).palettes.first?.name, "Synced")
        let before = store.state
        XCTAssertThrowsError(try store.applySyncedData(Data("broken".utf8)))
        XCTAssertEqual(store.state, before)
        let failing = ColorPickerStore(persistHistory: false, initialState: initial,
                                      save: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try failing.applySyncedData(payload))
        XCTAssertEqual(failing.state, initial)
    }

    @MainActor
    func testActualColorPickerRendersWithoutSamplingOrPermissionRequests() async throws {
        var calls = 0
        let colors = try [NSColor.systemBlue, .systemTeal, .systemIndigo].map { try CoreColorRGBA.fromNSColor($0) }
        let library = try CoreColorPaletteLibrary(palettes: [CoreColorPalette(name: "Product Colors", colors: colors)])
        let store = ColorPickerStore(persistHistory: false, initialState: try CoreColorPickerState(history: colors, library: library),
                                     sampling: { _ in calls += 1 })
        defer { store.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ColorPickerToolView(store: store).frame(width: 560, height: 440)
            .background(Color(nsColor: window.backgroundColor)))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        XCTAssertEqual(calls, 0)
        let environment = ProcessInfo.processInfo.environment
        let path = environment["NOTCHORBITPLUS_EVAL_DIR"] ?? environment["TEST_RUNNER_NOTCHORBITPLUS_EVAL_DIR"]
        let output = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/evaluation", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent("NotchOrbitPlus-ColorPicker.png"), options: .atomic)
    }
}
