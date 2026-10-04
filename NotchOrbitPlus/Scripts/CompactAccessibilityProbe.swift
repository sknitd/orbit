import AppKit
import SwiftUI
import NotchCore
import Darwin

@main
enum CompactAccessibilityProbe {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        Task { @MainActor in
            await run()
            application.terminate(nil)
        }
        application.run()
    }

    @MainActor
    private static func run() async {
        let report = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let cases: [(LiveNotchStatus, String, String)] = [
            (.init(id: "verification:8472", kind: .verificationCode, title: "847291", detail: "Synthetic fixture only",
                   toolID: "verificationCodes", action: .copyVerificationCode), "Copy one-time code", "NotchOrbitPlus.compact.copyVerificationCode"),
            (.init(id: "download:fixture", kind: .downloads, title: "Fixture.zip", detail: "Synthetic completed file",
                   toolID: "downloads", action: .revealFile), "Reveal completed download", "NotchOrbitPlus.compact.revealFile")
        ]
        var results: [[String: Any]] = [], allPassed = true
        for (status, label, identifier) in cases {
            var routed: [LiveNotchStatus] = [], opens = 0
            let size = NSSize(width: 320, height: 48)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: LiveCompactContent(statuses: [status], openDashboard: { opens += 1 },
                onActivityAction: { routed.append($0) }).frame(width: size.width, height: size.height))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let unignored = NSAccessibility.unignoredDescendant(host)
            var item: [String: Any] = ["identifier": identifier, "synthetic_fixture": true,
                "host_tree": CompactAccessibilityFixture.tree(below: host),
                "window_tree": CompactAccessibilityFixture.tree(below: window),
                "unignored_host_tree": CompactAccessibilityFixture.tree(below: unignored)]
            let semantic = CompactAccessibilityFixture.action(identifier: identifier, below: host)
                ?? CompactAccessibilityFixture.action(identifier: identifier, below: window)
            let semanticLabel = semantic.flatMap { CompactAccessibilityFixture.label(of: $0) } == label
            let semanticPress = semantic.map { CompactAccessibilityFixture.press($0) } ?? false
            try? await Task.sleep(for: .milliseconds(50))
            let semanticRoute = routed == [status] && opens == 0
            item["semantic_found"] = semantic != nil
            item["semantic_role"] = semantic.flatMap { CompactAccessibilityFixture.role(of: $0) } ?? "(nil)"
            item["semantic_label"] = semantic.flatMap { CompactAccessibilityFixture.label(of: $0) } ?? "(nil)"
            item["semantic_press"] = semanticPress
            item["semantic_exact_route"] = semanticRoute
            routed.removeAll()
            let button = nativeButton(identifier: identifier, below: host)
            let nativeRole = button?.accessibilityRole() == .button
            let nativeLabel = button?.accessibilityLabel() == label
            let nativeElement = button?.isAccessibilityElement() == true
            let nativeIdentifier = button?.accessibilityIdentifier() == identifier
            let nativePress = button?.accessibilityPerformPress() == true
            try? await Task.sleep(for: .milliseconds(50))
            let nativeRoute = routed == [status] && opens == 0
            item["native_button_found"] = button != nil
            item["native_role"] = nativeRole; item["native_label"] = nativeLabel
            item["native_element"] = nativeElement; item["native_identifier"] = nativeIdentifier
            item["native_press"] = nativePress; item["native_exact_route"] = nativeRoute
            let passed = semantic != nil && semanticLabel && semanticPress && semanticRoute
                && nativeRole && nativeLabel && nativeElement && nativeIdentifier && nativePress && nativeRoute
            item["outcome"] = passed ? "passed" : "failed"
            allPassed = allPassed && passed; results.append(item)
            window.close()
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["outcome": allPassed ? "passed" : "failed", "checks": results], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: report.appendingPathComponent("status.json"))
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
        if !allPassed { exit(1) }
    }

    @MainActor
    private static func nativeButton(identifier: String, below view: NSView, depth: Int = 0) -> NSButton? {
        guard depth < 40 else { return nil }
        if let button = view as? NSButton, button.identifier?.rawValue == identifier { return button }
        for child in view.subviews {
            if let found = nativeButton(identifier: identifier, below: child, depth: depth + 1) { return found }
        }
        return nil
    }
}
