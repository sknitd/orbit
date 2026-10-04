import AppKit
import SwiftUI
import CornerCore

@MainActor
struct CornerSettingsView: View {
    @ObservedObject var store: CornerAppStore
    @ObservedObject private var monitor: CornerGestureMonitor
    @State private var editedGesture: CornerGesture?
    init(store: CornerAppStore) { self.store = store; self.monitor = store.monitor }
    var body: some View {
        NavigationSplitView {
            List(CornerSettingsPage.allCases, selection: $store.page) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }.navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 210)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                Group {
                    switch store.page {
                    case .corners: corners
                    case .behavior: CornerBehaviorView(store: store)
                    case .history: CornerWebsitesSettingsView(store: store)
                    case .about: gettingStarted
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: store.errorMessage == nil ? "info.circle" : "exclamationmark.triangle")
                    Text(store.errorMessage ?? store.lastAction).font(.caption).textSelection(.enabled).lineLimit(3)
                    Spacer(minLength: 0)
                    if store.isRunningAction { ProgressView().controlSize(.small).accessibilityLabel("Running action") }
                }.foregroundStyle(store.errorMessage == nil ? Color.secondary : Color.orange)
                    .padding(12).frame(minHeight: 44).accessibilityElement(children: .combine)
            }
        }.frame(minWidth: 820, minHeight: 640)
            .sheet(isPresented: Binding(get: { editedGesture != nil }, set: { if !$0 { editedGesture = nil } })) {
                if let gesture = editedGesture { CornerBindingEditorView(store: store, corner: store.selectedCorner, gesture: gesture) }
            }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "viewfinder").font(.system(size: 26)).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("CornerOrbit").font(.title2.weight(.semibold))
                Text(monitor.diagnostic).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isPreview { Text("Preview").font(.caption).foregroundStyle(.secondary) }
            Toggle("Enable gestures", isOn: Binding(get: { monitor.isEnabled }, set: { store.setMonitoring($0) }))
                .toggleStyle(.switch).disabled(store.isPreview || store.settingsNeedRecovery)
                .accessibilityIdentifier("CornerOrbit.enableGestures")
        }.padding(20)
    }
    private var corners: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Make every corner yours").font(.title3.weight(.semibold))
                        Text("Choose a corner, then assign an action to each gesture.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use Starter Bindings") { store.applyPreset() }.disabled(store.settingsNeedRecovery)
                        .accessibilityIdentifier("CornerOrbit.applyPreset")
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(Corner.allCases, id: \.self) { corner in cornerCard(corner) }
                }
                HStack {
                    Text(store.selectedCorner.title).font(.headline)
                    Spacer()
                    Toggle("Use this corner", isOn: Binding(
                        get: { store.preferences.settings.corners[store.selectedCorner]?.enabled ?? true },
                        set: { value in store.updateSettings { $0.corners[store.selectedCorner, default: .init()].enabled = value } }))
                        .toggleStyle(.switch).controlSize(.small)
                }
                VStack(spacing: 0) {
                    ForEach(CornerGesture.allCases, id: \.self) { gesture in
                        bindingRow(gesture)
                        if gesture != CornerGesture.allCases.last { Divider().padding(.leading, 12) }
                    }
                }.background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                Text("Single and double clicks wait for the multi-click interval. A drag runs when you release the mouse; dragging from one corner into another uses the starting corner’s Drag Out action.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.disabled(store.settingsNeedRecovery)
    }
    private func cornerCard(_ corner: Corner) -> some View {
        let chosen = store.selectedCorner == corner
        let count = CornerGesture.allCases.filter { store.action(corner: corner, gesture: $0).kind != .none }.count
        return Button { store.selectedCorner = corner } label: {
            HStack(spacing: 12) {
                Image(systemName: corner.symbol).font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(corner.title).font(.headline)
                    Text("\(count) of 5 gestures configured").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }.padding(14).frame(maxWidth: .infinity, minHeight: 50)
                .background(chosen ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(chosen ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("\(corner.title), \(count) gestures configured")
            .accessibilityAddTraits(chosen ? .isSelected : [])
            .accessibilityIdentifier("CornerOrbit.corner.\(corner.rawValue)")
    }
    private func bindingRow(_ gesture: CornerGesture) -> some View {
        let action = store.action(corner: store.selectedCorner, gesture: gesture)
        return HStack(spacing: 12) {
            Image(systemName: gesture.symbol).frame(width: 24).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(gesture.title).frame(width: 130, alignment: .leading)
            Button { editedGesture = gesture } label: {
                HStack {
                    Image(systemName: action.kind.systemImage)
                    Text(action.kind.title).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }.frame(maxWidth: .infinity)
            }.accessibilityLabel("\(store.selectedCorner.title) \(gesture.title): \(action.kind.title)")
                .accessibilityIdentifier("CornerOrbit.binding.\(store.selectedCorner.rawValue).\(gesture.rawValue)")
            Button { store.perform(action) } label: { Image(systemName: "play.fill") }
                .help("Run \(action.kind.title)").accessibilityLabel("Run \(gesture.title) action")
                .disabled(action.kind == .none || store.isPreview || store.isRunningAction)
        }.padding(12)
    }
    private var gettingStarted: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your shortcuts, at every corner").font(.title2.weight(.semibold))
                instruction("1", "Assign your actions", "Select any of the four corners. Single, double, triple and both drag directions have separate actions.")
                instruction("2", "Enable mouse observation", "Enable gestures when ready. macOS may ask for Input Monitoring; CornerOrbit observes mouse events and lets clicks continue to the app underneath.")
                instruction("3", "Connect only what you use", "New browser tabs and blank Office/TextEdit documents use Automation after you allow it in Behavior. Chrome history needs an explicit local connection in Websites.")
                instruction("4", "Tune the feel", "Adjust corner size, click timing, drag distance and an optional modifier key. You can limit gestures to chosen displays.")
                Text("The menu bar icon opens these settings and pauses gestures. CornerOrbit runs locally; it has no telemetry, cloud service or account system.")
                    .foregroundStyle(.secondary)
                if store.settingsNeedRecovery {
                    GroupBox("Saved settings need attention") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("The unreadable configuration was preserved. Reset creates a new configuration and retains the old file beside it.")
                            Button("Preserve Old Settings and Reset") { store.resetPreservingSettings() }
                        }.padding(6)
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func instruction(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.headline).frame(width: 30, height: 30).background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).foregroundStyle(.secondary) }
        }
    }
}

extension Corner {
    var symbol: String {
        switch self { case .topLeft: "arrow.up.left"; case .topRight: "arrow.up.right"; case .bottomLeft: "arrow.down.left"; case .bottomRight: "arrow.down.right" }
    }
}
extension CornerGesture {
    var symbol: String {
        switch self { case .singleClick: "cursorarrow.click"; case .doubleClick: "2.circle"; case .tripleClick: "3.circle"; case .dragIntoCorner: "arrow.down.forward.and.arrow.up.backward"; case .dragOutOfCorner: "arrow.up.backward.and.arrow.down.forward" }
    }
}
