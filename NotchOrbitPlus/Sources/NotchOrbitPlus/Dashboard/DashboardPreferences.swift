#if os(macOS)
import AppKit
import SwiftUI

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
    }
    private func key(_ suffix: String) -> String { prefix + suffix }
    private static func delay(_ value: Double) -> Double { value.isFinite ? min(1.5, max(0, value)) : 0.2 }
    private static func panelWidth(_ value: Double) -> Double { value.isFinite ? min(800, max(420, value)) : 620 }

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
                    Slider(value: $preferences.width, in: 420...800, step: 10).frame(width: 160)
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
                Text("Hover and clicks do not need Input Monitoring. A global keyboard shortcut may require macOS permission. File actions temporarily hide the dashboard.")
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
                            .disabled(preferences.toolOrder.first == tool.id).help("Move \(tool.title) earlier")
                        Button { preferences.move(tool.id, by: 1) } label: { Image(systemName: "chevron.down") }
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
