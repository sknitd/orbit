#if os(macOS)
import AppKit
import SwiftUI
import NotchCore

public enum DashboardOpenMode: String, CaseIterable, Identifiable, Sendable {
    case hoverAndClick, clickOnly
    public var id: String { rawValue }
    public var title: String { self == .hoverAndClick ? "Hover or click" : "Click only" }
}

public struct DashboardToolMetadata: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public init(id: String, title: String, symbol: String) { self.id = id; self.title = title; self.symbol = symbol }
}

@MainActor
public final class DashboardPreferences: ObservableObject {
    // The widest embedded tool needs 500 points, plus the shell's side padding.
    public static let widthRange = 560.0...800.0
    @Published public var hiddenToolIDs: Set<String> { didSet { defaults.set(Array(hiddenToolIDs).sorted(), forKey: key("hidden")) } }
    @Published public var toolOrder: [String] { didSet { defaults.set(toolOrder, forKey: key("order")) } }
    @Published public var openMode: DashboardOpenMode { didSet { defaults.set(openMode.rawValue, forKey: key("mode")) } }
    @Published public var hoverDelay: Double {
        didSet {
            let value = Self.delay(hoverDelay)
            if hoverDelay != value { hoverDelay = value }
            defaults.set(hoverDelay, forKey: key("delay"))
        }
    }
    @Published public var width: Double {
        didSet {
            let value = Self.panelWidth(width)
            if width != value { width = value }
            defaults.set(width, forKey: key("width"))
        }
    }
    @Published public var displaySelection: String { didSet { defaults.set(displaySelection, forKey: key("display")) } }
    @Published public var keyboardShortcutEnabled: Bool { didSet { defaults.set(keyboardShortcutEnabled, forKey: key("shortcut")) } }
    @Published public var spaceBehavior: DashboardSpaceBehavior { didSet { defaults.set(spaceBehavior.rawValue, forKey: key("spaces")) } }
    @Published public var hideInFullscreen: Bool { didSet { defaults.set(hideInFullscreen, forKey: key("fullscreen")) } }
    @Published public var displayRules: [String: DashboardDisplayRule] {
        didSet {
            guard (try? DashboardBehavior.validate(displayRules)) != nil,
                  let data = try? JSONEncoder().encode(displayRules) else { return }
            defaults.set(data, forKey: key("displays"))
        }
    }
    @Published public private(set) var behaviorError: String?
    @Published public private(set) var registeredTools: [DashboardToolMetadata] = []
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "dashboard.") {
        self.defaults = defaults; self.prefix = prefix
        hiddenToolIDs = Set(defaults.stringArray(forKey: prefix + "hidden") ?? [])
        toolOrder = defaults.stringArray(forKey: prefix + "order") ?? []
        openMode = DashboardOpenMode(rawValue: defaults.string(forKey: prefix + "mode") ?? "") ?? .hoverAndClick
        hoverDelay = Self.delay(defaults.object(forKey: prefix + "delay") as? Double ?? 0.2)
        width = Self.panelWidth(defaults.object(forKey: prefix + "width") as? Double ?? 620)
        displaySelection = defaults.string(forKey: prefix + "display") ?? "primary"
        keyboardShortcutEnabled = defaults.object(forKey: prefix + "shortcut") as? Bool ?? true
        spaceBehavior = DashboardSpaceBehavior(rawValue: defaults.string(forKey: prefix + "spaces") ?? "") ?? .allSpaces
        hideInFullscreen = defaults.bool(forKey: prefix + "fullscreen")
        displayRules = [:]
        if let data = defaults.data(forKey: prefix + "displays") {
            do {
                guard data.count <= 32_000 else { throw DashboardBehaviorFailure.invalid("Saved display settings are too large.") }
                let decoded = try JSONDecoder().decode([String: DashboardDisplayRule].self, from: data)
                try DashboardBehavior.validate(decoded); displayRules = decoded
            } catch { behaviorError = "Saved display settings could not be read. Their stored bytes were retained: \(error.localizedDescription)" }
        }
    }
    private func key(_ suffix: String) -> String { prefix + suffix }
    private static func delay(_ value: Double) -> Double { value.isFinite ? min(1.5, max(0, value)) : 0.2 }
    private static func panelWidth(_ value: Double) -> Double {
        value.isFinite ? min(widthRange.upperBound, max(widthRange.lowerBound, value)) : 620
    }

    /// Sync can restore both the visible settings and their exact stored
    /// representation if another participating store fails to commit.
    func prepareSyncRollback() -> @MainActor () throws -> Void {
        let previous = (hiddenToolIDs, toolOrder, openMode, hoverDelay)
        let raw = Dictionary(uniqueKeysWithValues: ["hidden", "order", "mode", "delay"].map {
            let name = key($0)
            return (name, defaults.object(forKey: name))
        })
        return { [self] in
            hiddenToolIDs = previous.0; toolOrder = previous.1
            openMode = previous.2; hoverDelay = previous.3
            for (name, value) in raw {
                if let value { defaults.set(value, forKey: name) }
                else { defaults.removeObject(forKey: name) }
            }
        }
    }

    func register(_ tools: [DashboardToolMetadata]) {
        registeredTools = tools
        let known = Set(tools.map(\.id))
        var seen = Set<String>()
        let surviving = toolOrder.filter { known.contains($0) && seen.insert($0).inserted }
        let appended = tools.map(\.id).filter { !seen.contains($0) }
        let order = surviving + appended
        if order != toolOrder { toolOrder = order }
    }
    public var orderedTools: [DashboardToolMetadata] {
        let ranks = Dictionary(toolOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return registeredTools.sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
    }
    public func setVisible(_ visible: Bool, toolID: String) {
        if visible { hiddenToolIDs.remove(toolID) } else { hiddenToolIDs.insert(toolID) }
    }
    public func move(_ toolID: String, by offset: Int) {
        guard let index = toolOrder.firstIndex(of: toolID), toolOrder.indices.contains(index + offset) else { return }
        toolOrder.swapAt(index, index + offset)
    }
    func displayRule(_ id: UInt32?) -> DashboardDisplayRule {
        id.flatMap { displayRules[String($0)] } ?? .init()
    }
    func setDisplayRule(_ value: DashboardDisplayRule, id: UInt32) {
        do {
            _ = try value.validated()
            var next = displayRules; next[String(id)] = value
            try DashboardBehavior.validate(next)
            if behaviorError != nil, let original = defaults.data(forKey: key("displays")) {
                defaults.set(original, forKey: key("displays.preserved-invalid"))
            }
            displayRules = next; behaviorError = nil
        } catch { behaviorError = error.localizedDescription }
    }
}

@MainActor
public struct DashboardSettingsView: View {
    @ObservedObject private var preferences: DashboardPreferences
    @State private var displayRevision = 0
    public init(preferences: DashboardPreferences) { self.preferences = preferences }
    public var body: some View {
        Form {
            Section("Notch dashboard") {
                Picker("Open with", selection: $preferences.openMode) {
                    ForEach(DashboardOpenMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                LabeledContent("Hover delay") {
                    Slider(value: $preferences.hoverDelay, in: 0...1.5, step: 0.05).frame(width: 160)
                    Text(preferences.hoverDelay, format: .number.precision(.fractionLength(2))).monospacedDigit()
                    Text("s").foregroundStyle(.secondary)
                }.disabled(preferences.openMode == .clickOnly)
                LabeledContent("Dashboard width") {
                    Slider(value: $preferences.width, in: DashboardPreferences.widthRange, step: 10).frame(width: 160)
                    Text("\(Int(preferences.width)) pt").monospacedDigit()
                }
                Picker("Display", selection: $preferences.displaySelection) {
                    Text("Primary display").tag("primary")
                    Text("Display under pointer when opened").tag("pointer")
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                        if let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                            Text(screen.localizedName).tag("id:\(number)")
                        }
                    }
                }.id(displayRevision)
                Toggle("Keyboard shortcut: ⌘⌃N", isOn: $preferences.keyboardShortcutEnabled)
                Picker("Spaces", selection: $preferences.spaceBehavior) {
                    ForEach(DashboardSpaceBehavior.allCases) { behavior in Text(behavior.title).tag(behavior) }
                }
                Toggle("Hide on the display of a fullscreen app", isOn: $preferences.hideInFullscreen)
                if preferences.hideInFullscreen {
                    Text("Fullscreen detection reads the focused window only when Accessibility access is available. Other displays stay visible.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Connect Accessibility for Fullscreen Detection") { PlusFullscreenDetection.requestAccess() }
                }
                Text("Hover and clicks do not need Input Monitoring. A global keyboard shortcut may require macOS permission. File actions temporarily hide the dashboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Per-display behaviour") {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                    if let id = NotchScreenLayout.screenID(for: screen) {
                        Toggle(screen.localizedName, isOn: Binding(
                            get: { preferences.displayRule(id).enabled },
                            set: { enabled in
                                var rule = preferences.displayRule(id); rule.enabled = enabled
                                preferences.setDisplayRule(rule, id: id)
                            }))
                        LabeledContent("\(screen.localizedName) width") {
                            Slider(value: Binding(get: { preferences.displayRule(id).width ?? preferences.width },
                                set: { width in
                                    var rule = preferences.displayRule(id); rule.width = width
                                    preferences.setDisplayRule(rule, id: id)
                                }), in: DashboardPreferences.widthRange, step: 10).frame(width: 160)
                        }
                    }
                }
                if let error = preferences.behaviorError { Text(error).foregroundStyle(.red).font(.caption) }
                Text("Display rules and Space placement stay on this Mac. A disabled display keeps its dashboard hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Visible tools and tab order") {
                ForEach(preferences.orderedTools) { tool in
                    HStack {
                        Toggle(isOn: Binding(get: { !preferences.hiddenToolIDs.contains(tool.id) },
                                             set: { preferences.setVisible($0, toolID: tool.id) })) {
                            Label(tool.title, systemImage: tool.symbol)
                        }
                        Spacer()
                        Button { preferences.move(tool.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .accessibilityLabel("Move \(tool.title) earlier")
                            .disabled(preferences.toolOrder.first == tool.id).help("Move \(tool.title) earlier")
                        Button { preferences.move(tool.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .accessibilityLabel("Move \(tool.title) later")
                            .disabled(preferences.toolOrder.last == tool.id).help("Move \(tool.title) later")
                    }
                }
            }
        }.formStyle(.grouped)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                displayRevision += 1
            }
    }
}
#endif
