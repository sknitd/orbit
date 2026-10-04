#if os(macOS)
import AppKit
import SwiftUI
import NotchCore

@MainActor
public struct NotchDashboardModule: Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    let content: @MainActor () -> AnyView
    public init(id: String, title: String, symbol: String, content: @escaping @MainActor () -> AnyView) {
        self.id = id; self.title = title; self.symbol = symbol; self.content = content
    }
}

@MainActor
final class DashboardPresentation: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var selectedToolID: String?
    @Published var width = 240.0
    @Published var height = 36.0
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    var openedManually = false
}

@MainActor
struct NotchDashboardView: View {
    @ObservedObject var presentation: DashboardPresentation
    @ObservedObject var preferences: DashboardPreferences
    let modules: [NotchDashboardModule]
    let compactContent: @MainActor () -> AnyView
    let toggleExpanded: @MainActor () -> Void
    let collapse: @MainActor () -> Void
    let openSettings: @MainActor () -> Void
    @FocusState private var focusedToolID: String?
    @ObservedObject private var appearance = PlusAppearanceStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private var visibleModules: [NotchDashboardModule] {
        let order = preferences.orderedTools.map(\.id)
        return order.compactMap { id in modules.first { $0.id == id && !preferences.hiddenToolIDs.contains(id) } }
    }
    private var dashboardSpring: Animation? {
        presentation.reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.12)
    }
    private var dashboardTransition: AnyTransition {
        presentation.reduceMotion ? .identity : .opacity.combined(with: .offset(y: -3))
    }
    var body: some View {
        ZStack {
            DashboardMaterial()
            if colorScheme == .light { Color.white.opacity(presentation.increaseContrast ? 0.95 : 0.84) }
            else { Color.black.opacity(presentation.increaseContrast ? 0.9 : 0.63) }
            Group {
                if presentation.expanded { expandedContent.transition(dashboardTransition) }
                else { compact.transition(dashboardTransition) }
            }
            .animation(dashboardSpring, value: presentation.expanded)
        }
        .frame(width: presentation.width, height: presentation.height)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 22,
                                          bottomTrailingRadius: 22, topTrailingRadius: 7))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 22,
                                        bottomTrailingRadius: 22, topTrailingRadius: 7)
            .strokeBorder((colorScheme == .light ? Color.black : Color.white)
                .opacity(presentation.increaseContrast ? 0.6 : 0.11), lineWidth: 0.7))
        .preferredColorScheme(appearance.preferredColorScheme).tint(appearance.accentColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchOrbitPlus dashboard")
        .accessibilityHint("Tab moves between controls. Control-Tab changes tools. Escape closes the dashboard.")
    }

    private var compact: some View {
        Button(action: toggleExpanded) {
            HStack(spacing: 10) {
                compactContent().lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("Open NotchOrbitPlus dashboard")
            .help(preferences.openMode == .hoverAndClick ? "Hover or click to open" : "Click to open")
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 13)).foregroundStyle(.secondary)
                Text("NotchOrbitPlus").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { presentation.pinned.toggle() } label: {
                    Image(systemName: presentation.pinned ? "pin.fill" : "pin").font(.system(size: 12))
                }.help(presentation.pinned ? "Unpin dashboard" : "Keep dashboard open")
                    .accessibilityLabel(presentation.pinned ? "Unpin dashboard" : "Pin dashboard")
                Button(action: openSettings) { Image(systemName: "gearshape").font(.system(size: 12)) }
                    .help("Dashboard settings").accessibilityLabel("Dashboard settings")
                Button(action: collapse) { Image(systemName: "chevron.up").font(.system(size: 12)) }
                    .help("Collapse dashboard").accessibilityLabel("Collapse dashboard")
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 13)
            Divider().overlay(.white.opacity(0.05))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(visibleModules) { module in
                            Button { presentation.selectedToolID = module.id } label: {
                                Label(module.title, systemImage: module.symbol)
                                    .font(.system(size: 11, weight: presentation.selectedToolID == module.id ? .semibold : .regular))
                                    .padding(.horizontal, 11).padding(.vertical, 8)
                                    .background(presentation.selectedToolID == module.id ? Color.white.opacity(0.11) : .clear,
                                                in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).foregroundStyle(presentation.selectedToolID == module.id ? .primary : .secondary)
                                .id(module.id).accessibilityLabel(module.title)
                                .focused($focusedToolID, equals: module.id)
                                .accessibilityAddTraits(presentation.selectedToolID == module.id ? .isSelected : [])
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                        .onMoveCommand { direction in
                            guard focusedToolID != nil else { return }
                            let step: Int
                            switch direction { case .left, .up: step = -1; case .right, .down: step = 1; default: return }
                            if let id = DashboardBehavior.neighboringTool(current: focusedToolID,
                                orderedVisibleIDs: visibleModules.map(\.id), offset: step) {
                                focusedToolID = id; presentation.selectedToolID = id
                            }
                        }
                        .animation(dashboardSpring, value: presentation.selectedToolID)
                }
                .onAppear {
                    if let id = presentation.selectedToolID { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: presentation.selectedToolID) { _, id in
                    if let id {
                        withAnimation(dashboardSpring) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }.frame(height: 47)
            Divider().overlay(.white.opacity(0.05))
            Group {
                if let module = visibleModules.first(where: { $0.id == presentation.selectedToolID }) ?? visibleModules.first {
                    ScrollView {
                        module.content().frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(18)
                    }.id(module.id).transition(dashboardTransition)
                } else {
                    ContentUnavailableView {
                        Label("No visible tools", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Choose which tools appear in dashboard settings.")
                    } actions: {
                        Button("Open Settings", action: openSettings)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(dashboardTransition)
                }
            }
            // Only dashboard navigation drives these transitions; live tool
            // readings do not become triggers for the shell's spring animation.
            .animation(dashboardSpring, value: presentation.selectedToolID)
        }
    }
}

@MainActor
private struct DashboardMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#endif
