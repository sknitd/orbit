import AppKit
import SwiftUI
import CornerCore

@MainActor
struct CornerBehaviorView: View {
    @ObservedObject private var store: CornerAppStore
    @State private var displays: [CornerDisplayChoice] = []
    @State private var displayError: String?
    init(store: CornerAppStore) { self.store = store }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Tune corner behavior").font(.title3.weight(.semibold))
                GroupBox("Options") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Allow document and tab Automation", isOn: Binding(
                            get: { store.preferences.automationEnabled }, set: { store.setAutomation($0) }))
                            .accessibilityIdentifier("CornerOrbit.behavior.automation")
                        Text("Enabling this option does not request permission. macOS asks for the target app only when you explicitly run a browser-tab, Finder-window or blank document action. Supported document apps include Word, Excel, PowerPoint, TextEdit, Pages, Numbers and Keynote.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Show corner hints", isOn: Binding(
                            get: { store.preferences.showHints }, set: { store.setHints($0) }))
                            .accessibilityIdentifier("CornerOrbit.behavior.hints")
                        Text("Hints appear while gesture observation is enabled and do not intercept clicks.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Gesture timing and size") {
                    VStack(spacing: 14) {
                        slider("Corner size", value: setting(\.cornerSize), range: 4...128, step: 1, unit: "pt", decimals: 0, id: "cornerSize")
                        slider("Multi-click interval", value: setting(\.clickInterval), range: 0.15...1, step: 0.01, unit: "s", decimals: 2, id: "clickInterval")
                        slider("Minimum drag distance", value: setting(\.dragThreshold), range: 2...100, step: 1, unit: "pt", decimals: 0, id: "dragThreshold")
                        slider("Action cooldown", value: setting(\.cooldown), range: 0...5, step: 0.05, unit: "s", decimals: 2, id: "cooldown")
                    }.padding(8)
                }
                GroupBox("Required modifier keys") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 16) {
                            modifier("Shift ⇧", .shift, id: "shift")
                            modifier("Control ⌃", .control, id: "control")
                            modifier("Option ⌥", .option, id: "option")
                            modifier("Command ⌘", .command, id: "command")
                        }
                        Text("Hold every selected key while clicking or dragging. Leave all keys off to use gestures without modifiers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Displays") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Use all displays, including newly connected ones", isOn: Binding(
                            get: { store.preferences.settings.enabledDisplayIDs.isEmpty }, set: { setAllDisplays($0) }))
                            .disabled(displays.isEmpty && store.preferences.settings.enabledDisplayIDs.isEmpty)
                            .accessibilityIdentifier("CornerOrbit.behavior.allDisplays")
                        ForEach(displays) { display in
                            displayToggle(id: display.id, name: display.name)
                        }
                        ForEach(unavailableDisplayIDs, id: \.self) { id in
                            displayToggle(id: id, name: "Unavailable display (\(id.prefix(12)))")
                        }
                        if let displayError { Text(displayError).font(.caption).foregroundStyle(.orange) }
                        Text("Choose at least one display when limiting gestures. Disconnected display selections are retained so they work when reconnected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Button("Open Input Monitoring Settings") { openInputMonitoring() }.disabled(store.isPreview)
                        .accessibilityIdentifier("CornerOrbit.behavior.inputMonitoring")
                    Text("Enable gestures at the top of Settings to request mouse observation. If macOS requires it, allow CornerOrbit under Privacy & Security → Input Monitoring, then enable again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Clicks continue to the app underneath. CornerOrbit and macOS Hot Corners can both react to the same corner; adjust Desktop & Dock → Hot Corners to avoid overlapping actions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20).disabled(store.settingsNeedRecovery)
        }.onAppear { displays = CornerScreenGeometry.availableDisplays() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                displays = CornerScreenGeometry.availableDisplays()
            }
    }
    private func setting(_ keyPath: WritableKeyPath<CornerSettings, Double>) -> Binding<Double> {
        Binding(get: { store.preferences.settings[keyPath: keyPath] }, set: { value in
            store.updateSettings { $0[keyPath: keyPath] = value }
        })
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        unit: String, decimals: Int, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title); Spacer(); Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(decimals)))) \(unit)").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
                .accessibilityIdentifier("CornerOrbit.behavior.\(id)")
        }
    }
    private func modifier(_ title: String, _ mask: CornerModifiers, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { store.preferences.settings.modifierRequirement.contains(mask) }, set: { enabled in
            store.updateSettings {
                if enabled { $0.modifierRequirement.insert(mask) } else { $0.modifierRequirement.remove(mask) }
            }
        })).accessibilityIdentifier("CornerOrbit.behavior.modifier.\(id)")
    }
    private var unavailableDisplayIDs: [String] {
        store.preferences.settings.enabledDisplayIDs.subtracting(Set(displays.map(\.id))).sorted()
    }
    private func setAllDisplays(_ enabled: Bool) {
        if enabled { store.updateSettings { $0.enabledDisplayIDs = [] }; displayError = nil; return }
        let selected = Set(displays.prefix(32).map(\.id))
        guard !selected.isEmpty else { displayError = "No available display can be selected right now."; return }
        store.updateSettings { $0.enabledDisplayIDs = selected }; displayError = nil
    }
    private func displayToggle(id: String, name: String) -> some View {
        let selected = store.preferences.settings.enabledDisplayIDs
        return Toggle(name, isOn: Binding(get: { selected.isEmpty || selected.contains(id) }, set: { enabled in
            store.updateSettings {
                if enabled { $0.enabledDisplayIDs.insert(id) } else { $0.enabledDisplayIDs.remove(id) }
            }
        })).disabled(selected.isEmpty || (selected.count == 1 && selected.contains(id)))
            .accessibilityIdentifier("CornerOrbit.behavior.display.\(id)")
    }
    private func openInputMonitoring() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }
}
