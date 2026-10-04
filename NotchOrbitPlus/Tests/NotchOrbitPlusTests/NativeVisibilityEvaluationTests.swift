import AppKit
import SwiftUI
import XCTest
@testable import NotchOrbitPlus

final class NativeVisibilityEvaluationTests: XCTestCase {
    @MainActor
    func testActualHostingWindowStopsAndResumesThenTeardownCannotRepublishVisible() async throws {
        let model = VisibilityLifecycleFixture()
        let window = fixtureWindow()
        let host = NSHostingView(rootView: VisibilityLifecycleView(model: model))
        window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await NativeFeatureEvaluation.waitUntil("The mounted native tool becomes visible") { model.running }
        XCTAssertTrue(model.deliveries.contains(true))

        window.orderOut(nil)
        try await NativeFeatureEvaluation.waitUntil("A retained hosted tool stops when its window is hidden") { !model.running }
        window.makeKeyAndOrderFront(nil)
        try await NativeFeatureEvaluation.waitUntil("Reopening the same hosted tool resumes visibility") { model.running }

        model.includesTool = false
        try await NativeFeatureEvaluation.waitUntil("Dismantling the native tool publishes a final hidden state") { !model.running }
        let visibleDeliveries = model.deliveries.filter { $0 }.count
        // Exercise old window notifications after SwiftUI removed the representable.
        window.orderOut(nil); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.deliveries.last, false)
        XCTAssertEqual(model.deliveries.filter { $0 }.count, visibleDeliveries,
                       "A dismantled tool must not receive a stale visible callback")
    }

    @MainActor
    func testObservedPublicationsDuringRepeatedActualSwiftUITeardownFinishHidden() async throws {
        let model = VisibilityLifecycleFixture()
        let window = fixtureWindow()
        let host = NSHostingView(rootView: VisibilityLifecycleView(model: model))
        window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await NativeFeatureEvaluation.waitUntil("Initial native hosting visibility") { model.running }
        for index in 0..<4 {
            model.includesTool = false
            try await NativeFeatureEvaluation.waitUntil("Actual SwiftUI child teardown \(index)") { !model.running }
            XCTAssertEqual(model.deliveries.last, false)
            model.includesTool = true
            try await NativeFeatureEvaluation.waitUntil("Actual SwiftUI child remount \(index)") { model.running }
        }
        // Send a visible-window notification, then remove the hosting tree in
        // the same actor turn. Any deferred delivery must honor invalidation.
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        window.contentView = nil
        host.rootView = VisibilityLifecycleView(model: model, forcesNoTool: true)
        try await NativeFeatureEvaluation.waitUntil("Final hosting teardown stops the observed model") { !model.running }
        let count = model.deliveries.filter { $0 }.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.deliveries.last, false)
        XCTAssertEqual(model.deliveries.filter { $0 }.count, count)
        XCTAssertGreaterThanOrEqual(model.deliveries.filter { $0 }.count, 5)
        XCTAssertGreaterThanOrEqual(model.deliveries.filter { !$0 }.count, 5)
    }

    @MainActor
    private func fixtureWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

@MainActor
private final class VisibilityLifecycleFixture: ObservableObject {
    @Published var includesTool = true
    @Published private(set) var running = false
    @Published private(set) var deliveryCount = 0
    private(set) var deliveries: [Bool] = []
    func deliver(_ visible: Bool) {
        deliveries.append(visible)
        running = visible
        deliveryCount += 1
    }
}

@MainActor
private struct VisibilityLifecycleView: View {
    @ObservedObject var model: VisibilityLifecycleFixture
    var forcesNoTool = false
    var body: some View {
        VStack {
            Text(model.running ? "Visible fixture" : "Hidden fixture")
            Text("Lifecycle publications: \(model.deliveryCount)")
            if model.includesTool && !forcesNoTool {
                Color.clear.frame(width: 12, height: 12)
                    .background(OrbitNativeToolVisibility(onVisible: { model.deliver(true) },
                                                         onHidden: { model.deliver(false) }))
            }
        }.frame(width: 320, height: 160)
    }
}
