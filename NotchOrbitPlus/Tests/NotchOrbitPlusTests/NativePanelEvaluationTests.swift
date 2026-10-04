import AppKit
import Foundation
import XCTest
import OrbitCore
import NotchCore
@testable import NotchOrbitPlus

final class NativePanelEvaluationTests: NativeImageFixtureCase, @unchecked Sendable {
    @MainActor
    func testActualNativePanelRendersConvertOptionsWithoutExecutingAnAction() async throws {
        let source = try rasterFile(named: "panel-fixture.jpg", width: 96, height: 64)
        let original = try Data(contentsOf: source)
        let items = try FileInspector.inspect([source])
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let layout = NotchScreenLayout.layout(for: screen)
        let controller = NotchPanelController()
        var selections = 0
        controller.show(items: items, actions: ActionResolver.actions(for: items), layout: layout,
                        onSelect: { _, _ in selections += 1 }, onCancel: {})
        defer { controller.dismiss() }
        try await Task.sleep(for: .milliseconds(300))
        let frame = try XCTUnwrap(controller.frame)
        XCTAssertEqual(frame.minX, layout.frame.minX, accuracy: 0.01)
        XCTAssertEqual(frame.minY, layout.frame.minY, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(frame.minX, screen.visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.visibleFrame.minY)
        XCTAssertLessThanOrEqual(frame.maxX, screen.visibleFrame.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, screen.visibleFrame.maxY)
        if let notch = layout.notchRect {
            XCTAssertLessThanOrEqual(frame.maxY, notch.minY)
        }
        _ = try XCTUnwrap(controller.evaluationPNG(selectingCategory: "Convert"))
        try await Task.sleep(for: .milliseconds(100))
        let png = try XCTUnwrap(controller.evaluationPNG())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        XCTAssertEqual(selections, 0, "Rendering and category selection must never run a transformation")
        XCTAssertEqual(try Data(contentsOf: source), original)

        let outputDirectory: URL
        if let outputPath = ProcessInfo.processInfo.environment["NOTCHORBITPLUS_EVAL_DIR"] {
            XCTAssertTrue(outputPath.hasPrefix("/"), "Evaluation evidence needs an absolute output directory")
            outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        } else {
            outputDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/evaluation", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try png.write(to: outputDirectory.appendingPathComponent("NotchOrbitPlus-Convert.png"), options: .atomic)
    }
}
