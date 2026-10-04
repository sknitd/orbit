import SwiftUI
import CornerCore

@MainActor
struct CornerGestureOptionsView: View {
    @ObservedObject private var store: CornerAppStore
    @ObservedObject private var monitor: CornerGestureMonitor
    init(store: CornerAppStore) {
        self.store = store
        self.monitor = store.monitor
    }
    private var corner: Corner { store.selectedCorner }
    private var configuration: CornerConfiguration { store.preferences.settings.corners[corner] ?? .init() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Gestures & Practice").font(.title3.weight(.semibold))
                GroupBox("Safe practice") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Practice without running actions", isOn: Binding(
                            get: { monitor.practiceMode }, set: { enabled in store.setPractice(enabled) }))
                            .accessibilityIdentifier("CornerOrbit.gestures.practice")
                        Text("Practice recognizes all 13 gestures in enabled corners, including gestures with no assigned action. Mouse events still reach other apps and macOS Hot Corners.")
                            .font(.caption).foregroundStyle(.secondary)
                        if monitor.practiceMode {
                            Label(monitor.lastPractice ?? "Try a gesture at a screen corner.", systemImage: "hand.point.up.left")
                                .font(.callout).accessibilityIdentifier("CornerOrbit.gestures.practiceResult")
                            if !monitor.isEnabled {
                                Button("Enable Mouse Observation") { store.setMonitoring(true) }
                                    .disabled(store.isPreview)
                                    .accessibilityIdentifier("CornerOrbit.gestures.enablePractice")
                                Text("Practice uses the same explicit Input Monitoring permission as regular gestures.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Dwell and hold timing") {
                    VStack(alignment: .leading, spacing: 12) {
                        timing("Hover delay", keyPath: \.hoverDelay, range: 0.3...5, id: "hoverDelay")
                        timing("Press-and-hold delay", keyPath: \.holdDelay, range: 0.3...3, id: "holdDelay")
                        Text("Hover fires once per corner entry. Hold uses the left mouse button and suppresses the later click or drag after recognition. Right clicks wait for possible double or triple clicks; middle click fires on release.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Per-corner overrides") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Corner", selection: $store.selectedCorner) {
                            ForEach(Corner.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.accessibilityIdentifier("CornerOrbit.gestures.corner")
                        Toggle("Custom hot-zone size", isOn: Binding(
                            get: { configuration.cornerSize != nil }, set: { enabled in
                                store.updateSettings { value in
                                    value.corners[corner, default: .init()].cornerSize = enabled ? value.cornerSize : nil
                                }
                            })).accessibilityIdentifier("CornerOrbit.gestures.customSize")
                        if configuration.cornerSize != nil {
                            HStack {
                                Text("\(store.preferences.settings.size(for: corner).formatted(.number.precision(.fractionLength(0)))) pt")
                                    .monospacedDigit().frame(width: 55, alignment: .leading)
                                Slider(value: Binding(get: { store.preferences.settings.size(for: corner) }, set: { size in
                                    store.updateSettings { $0.corners[corner, default: .init()].cornerSize = size }
                                }), in: 4...128, step: 1).accessibilityLabel("\(corner.title) hot-zone size")
                                    .accessibilityIdentifier("CornerOrbit.gestures.cornerSize")
                            }
                        } else {
                            Text("Uses the global \(store.preferences.settings.cornerSize.formatted(.number.precision(.fractionLength(0)))) pt hot zone.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Custom required modifier keys", isOn: Binding(
                            get: { configuration.modifierRequirement != nil }, set: { enabled in
                                store.updateSettings { value in
                                    value.corners[corner, default: .init()].modifierRequirement = enabled ? value.modifierRequirement : nil
                                }
                            })).accessibilityIdentifier("CornerOrbit.gestures.customModifiers")
                        if configuration.modifierRequirement != nil {
                            HStack(spacing: 14) {
                                modifier("Shift ⇧", .shift, id: "shift")
                                modifier("Control ⌃", .control, id: "control")
                                modifier("Option ⌥", .option, id: "option")
                                modifier("Command ⌘", .command, id: "command")
                            }
                            Text("Hold every selected key for this corner. Leave all four off to require no modifiers here.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Uses the global modifier requirement in Behavior.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20).disabled(store.settingsNeedRecovery)
        }
    }
    private func timing(_ title: String, keyPath: WritableKeyPath<CornerSettings, Double>, range: ClosedRange<Double>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title); Spacer()
                Text("\(store.preferences.settings[keyPath: keyPath].formatted(.number.precision(.fractionLength(2)))) s")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { store.preferences.settings[keyPath: keyPath] }, set: { delay in
                store.updateSettings { $0[keyPath: keyPath] = delay }
            }), in: range, step: 0.05).accessibilityLabel(title).accessibilityIdentifier("CornerOrbit.gestures.\(id)")
        }
    }
    private func modifier(_ title: String, _ mask: CornerModifiers, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { configuration.modifierRequirement?.contains(mask) == true }, set: { enabled in
            store.updateSettings { value in
                var flags = value.corners[corner]?.modifierRequirement ?? value.modifierRequirement
                if enabled { flags.insert(mask) } else { flags.remove(mask) }
                value.corners[corner, default: .init()].modifierRequirement = flags
            }
        })).accessibilityIdentifier("CornerOrbit.gestures.modifier.\(id)")
    }
}
