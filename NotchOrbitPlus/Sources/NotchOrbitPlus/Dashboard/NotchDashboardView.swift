#if os(macOS)
import AppKit
import SwiftUI

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

    private var visibleModules: [NotchDashboardModule] {
        let order = preferences.orderedTools.map(\.id)
        return order.compactMap { id in modules.first { $0.id == id && !preferences.hiddenToolIDs.contains(id) } }
    }
    var body: some View {
        ZStack {
            DashboardMaterial()
            Color.black.opacity(presentation.increaseContrast ? 0.9 : 0.63)
            if presentation.expanded { expandedContent } else { compact }
        }
        .frame(width: presentation.width, height: presentation.height)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 22,
                                          bottomTrailingRadius: 22, topTrailingRadius: 7))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 22,
                                        bottomTrailingRadius: 22, topTrailingRadius: 7)
            .strokeBorder(.white.opacity(presentation.increaseContrast ? 0.6 : 0.11), lineWidth: 0.7))
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchOrbitPlus dashboard")
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
                                .accessibilityAddTraits(presentation.selectedToolID == module.id ? .isSelected : [])
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                }
                .onAppear {
                    if let id = presentation.selectedToolID { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: presentation.selectedToolID) { _, id in
                    if let id {
                        withAnimation(presentation.reduceMotion ? nil : .easeOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }.frame(height: 47)
            Divider().overlay(.white.opacity(0.05))
            if let module = visibleModules.first(where: { $0.id == presentation.selectedToolID }) ?? visibleModules.first {
                ScrollView {
                    module.content().frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(18)
                }.id(module.id)
            } else {
                ContentUnavailableView {
                    Label("No visible tools", systemImage: "square.grid.2x2")
                } description: {
                    Text("Choose which tools appear in dashboard settings.")
                } actions: {
                    Button("Open Settings", action: openSettings)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
