import AppKit
import SwiftUI
import XCTest

/// Captures the actual hosted production view; never asks for screen-capture access.
@MainActor
enum NativeFeatureEvaluation {
    static func render(_ view: AnyView, named name: String, size: NSSize = NSSize(width: 560, height: 440),
                       appearance: NSAppearance? = nil, beforeCapture: (@MainActor () throws -> Void)? = nil) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: window.backgroundColor)))
        window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        try beforeCapture?()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        XCTAssertGreaterThan(png.count, 300)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.99)
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["NOTCHORBITPLUS_EVAL_DIR"] ?? environment["TEST_RUNNER_NOTCHORBITPLUS_EVAL_DIR"]
        let directory: URL
        if let configured, configured.hasPrefix("/") {
            directory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/evaluation", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    static func waitUntil(_ description: String, timeout: Duration = .seconds(3),
                          condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), description)
    }
}
