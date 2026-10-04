#if os(macOS)
import AppKit
import NotchCore
import OrbitCore
import SwiftUI

@MainActor
private final class NotchPanel: NSPanel {
    var escape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape?() }
    }
}

@MainActor
public final class NotchPanelController {
    private var panel: NotchPanel?
    private var model: NotchPanelModel?
    private var layout: NotchLayout?
    private var screenObserver: NSObjectProtocol?
    private var onSelect: (@MainActor (ActionDescriptor, [URL]) -> Void)?
    private var onCancel: (@MainActor () -> Void)?
    private var items: [FileItem] = []
    private var actions: [ActionDescriptor] = []
    private var presentationID: UUID?
    public var frame: NSRect? { panel?.frame }
    public var activeRegion: NSRect? { layout.map { Self.rect($0.activeRegion) } }

    public init() {}

    public func show(items: [FileItem], actions: [ActionDescriptor], layout: NotchLayout,
                     onSelect: @escaping @MainActor (ActionDescriptor, [URL]) -> Void,
                     onCancel: @escaping @MainActor () -> Void) {
        dismiss()
        guard !items.isEmpty, !actions.isEmpty, layout.scale > 0.2 else { onCancel(); return }
        self.items = items; self.actions = actions; self.layout = layout
        self.onSelect = onSelect; self.onCancel = onCancel
        let identifier = UUID()
        presentationID = identifier
        let window = NotchPanel(contentRect: Self.rect(layout.frame), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        window.setAccessibilityLabel("NotchOrbitPlus file actions")
        window.escape = { [weak self] in self?.cancel() }

        let state = NotchPanelModel(items: items, actions: actions, layout: layout)
        let destination = NotchDropView(frame: NSRect(origin: .zero, size: window.frame.size), model: state,
                                        expectedURLs: items.map(\.url))
        destination.onDrop = { [weak self] action, urls in
            guard self?.presentationID == identifier else { return }
            self?.complete(action, urls: urls)
        }
        destination.onCancel = { [weak self] in
            guard self?.presentationID == identifier else { return }
            self?.cancel()
        }
        let hosting = NSHostingView(rootView: NotchArcView(model: state))
        hosting.frame = destination.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        destination.addSubview(hosting)
        window.contentView = destination
        model = state; panel = window
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshScreenLayout() }
            }
        window.orderFrontRegardless()
        state.visible = true
    }

    public func dismiss() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        model?.stopObservingAccessibility()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil; model = nil; layout = nil; presentationID = nil
        items = []; actions = []; onSelect = nil; onCancel = nil
    }

    /// Captures this application's real view hierarchy for native evaluation.
    /// The caller allows its appearance animation to settle before capture.
    func evaluationPNG(selectingCategory category: String? = nil) -> Data? {
        guard let panel, let model, let view = panel.contentView else { return nil }
        if let category, let group = model.groups.first(where: { $0.title.caseInsensitiveCompare(category) == .orderedSame }) {
            model.activate(group)
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private func refreshScreenLayout() {
        guard let id = layout?.screenID, let screen = NotchScreenLayout.screen(id: id),
              let onSelect, let onCancel else { cancel(); return }
        let refreshed = NotchScreenLayout.layout(for: screen)
        guard refreshed != layout else { return }
        show(items: items, actions: actions, layout: refreshed, onSelect: onSelect, onCancel: onCancel)
    }

    private func complete(_ action: ActionDescriptor, urls: [URL]) {
        let callback = onSelect
        dismiss()
        callback?(action, urls)
    }
    private func cancel() {
        let callback = onCancel
        dismiss()
        callback?()
    }
    private static func rect(_ value: NotchRect) -> NSRect {
        NSRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }
}

@MainActor
private final class NotchDropView: NSView {
    private let model: NotchPanelModel
    private let expectedURLs: [URL]
    private var completed = false
    private var tracking: NSTrackingArea?
    var onDrop: ((ActionDescriptor, [URL]) -> Void)?
    var onCancel: (() -> Void)?
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, model: NotchPanelModel, expectedURLs: [URL]) {
        self.model = model; self.expectedURLs = expectedURLs
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:model:expectedURLs:)") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        model.updatePointer(relative(convert(event.locationInWindow, from: nil)))
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        // Keep the group open while the source crosses the transport corridor.
        // Global observation owns outside-region cancellation, not this boundary.
        model.highlight(nil)
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        droppedURLs(sender) != nil && action(sender) != nil
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = droppedURLs(sender), let action = action(sender) else { onCancel?(); return false }
        completed = true
        onDrop?(action, urls)
        return true
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        if !completed { onCancel?() }
    }
    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard droppedURLs(sender) != nil else { model.payloadValid = false; model.highlight(nil); return [] }
        model.payloadValid = true
        model.updatePointer(relative(convert(sender.draggingLocation, from: nil)))
        return action(sender) == nil ? [] : .copy
    }
    private func action(_ sender: any NSDraggingInfo) -> ActionDescriptor? {
        model.action(at: relative(convert(sender.draggingLocation, from: nil)))
    }
    private func relative(_ point: NSPoint) -> NotchPoint {
        NotchPoint(x: point.x - bounds.midX, y: point.y - bounds.maxY)
    }
    private func droppedURLs(_ sender: any NSDraggingInfo) -> [URL]? {
        guard let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                 options: [.urlReadingFileURLsOnly: true]) else { return nil }
        let urls = objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
        guard urls.count == objects.count else { return nil }
        return DropPayloadValidator.matchingDroppedURLs(urls, expected: expectedURLs)
    }
}

private struct NotchGroup: Identifiable {
    var id: Int { slot }
    let slot: Int
    let title: String
    let symbol: String
    let actions: [ActionDescriptor]
}

@MainActor
private final class NotchPanelModel: ObservableObject {
    @Published var visible = false
    @Published var selectedSlot: Int?
    @Published var highlightedID: ActionID?
    @Published var payloadValid = true
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    let groups: [NotchGroup]
    let layout: NotchLayout
    let fileName: String
    let count: Int
    private var observer: NSObjectProtocol?

    init(items: [FileItem], actions: [ActionDescriptor], layout: NotchLayout) {
        self.layout = layout
        count = items.count
        fileName = items.count == 1 ? items[0].url.lastPathComponent : "\(items.count) files"
        let slots = ["convert": 0, "compress": 1, "resize": 2, "pdf": 3, "privacy": 4,
                     "audio": 5, "media": 5, "files": 6, "text": 7, "tools": 7]
        let symbols = ["convert": "arrow.triangle.2.circlepath", "compress": "arrow.down.right.and.arrow.up.left",
                       "resize": "arrow.up.left.and.arrow.down.right", "pdf": "doc.richtext", "privacy": "hand.raised",
                       "audio": "waveform", "media": "play.rectangle", "files": "folder", "text": "curlybraces", "tools": "wrench.and.screwdriver"]
        let grouped = Dictionary(grouping: actions, by: { $0.category.lowercased() })
        var used = Set(grouped.keys.compactMap { slots[$0] })
        var result: [NotchGroup] = []
        for category in grouped.keys.sorted() {
            guard let descriptors = grouped[category], let first = descriptors.first else { continue }
            let slot: Int
            if let fixed = slots[category] { slot = fixed }
            else if let free = (0..<8).first(where: { !used.contains($0) }) { slot = free; used.insert(free) }
            else { slot = 7 }
            if let index = result.firstIndex(where: { $0.slot == slot }) {
                let old = result[index]
                result[index] = NotchGroup(slot: slot, title: slot == 5 ? "Media" : "Tools", symbol: old.symbol,
                                           actions: old.actions + descriptors)
            } else {
                result.append(NotchGroup(slot: slot, title: first.category, symbol: symbols[category] ?? first.symbol, actions: descriptors))
            }
        }
        groups = result.sorted { $0.slot < $1.slot }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    self?.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                }
            }
    }
    func stopObservingAccessibility() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
    var group: NotchGroup? { groups.first { $0.slot == selectedSlot } }
    var highlightedAction: ActionDescriptor? { group?.actions.first { $0.id == highlightedID } }
    func activate(_ group: NotchGroup) {
        if selectedSlot != group.slot { selectedSlot = group.slot }
        highlight(group.actions.count == 1 ? group.actions.first?.id : nil)
    }
    func highlight(_ id: ActionID?) {
        guard id != highlightedID else { return }
        highlightedID = id
        if id != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }
    func updatePointer(_ point: NotchPoint) {
        if let slot = layout.geometry.primarySlot(at: point) {
            if let group = groups.first(where: { $0.slot == slot }) { activate(group) }
            else { selectedSlot = nil; highlight(nil) }
        } else { highlight(action(at: point)?.id) }
    }
    func action(at point: NotchPoint) -> ActionDescriptor? {
        guard payloadValid else { return nil }
        if let slot = layout.geometry.primarySlot(at: point), let group = groups.first(where: { $0.slot == slot }) {
            return group.actions.count == 1 ? group.actions.first : nil
        }
        guard let group, let index = layout.geometry.optionIndex(at: point, count: group.actions.count) else { return nil }
        return group.actions[index]
    }
}

@MainActor
private struct NotchMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct LowerArc: Shape {
    let inner: Double
    let outer: Double
    let centerAngle: Double
    let span: Double
    func path(in rect: CGRect) -> Path {
        let start = centerAngle - span / 2
        let steps = max(24, Int(span * 48))
        func point(_ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(x: rect.midX - cos(angle) * radius, y: sin(angle) * radius)
        }
        var path = Path()
        path.move(to: point(inner, start))
        for index in 0...steps { path.addLine(to: point(outer, start + span * Double(index) / Double(steps))) }
        for index in (0...steps).reversed() { path.addLine(to: point(inner, start + span * Double(index) / Double(steps))) }
        path.closeSubpath()
        return path
    }
}

private struct NotchCap: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(12, rect.height / 2)
        path.move(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - radius), control: CGPoint(x: 0, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

@MainActor
private struct NotchArcView: View {
    @ObservedObject var model: NotchPanelModel
    @Environment(\.colorScheme) private var colorScheme
    private var scale: Double { model.layout.scale }
    private var width: Double { model.layout.frame.width }
    private var height: Double { model.layout.frame.height }

    var body: some View {
        ZStack(alignment: .top) {
            NotchMaterial()
                .frame(width: width, height: height)
                .mask(LowerArc(inner: 0, outer: 294 * scale, centerAngle: .pi / 2, span: .pi))
                .overlay(LowerArc(inner: 0, outer: 294 * scale, centerAngle: .pi / 2, span: .pi)
                    .stroke(.primary.opacity(model.increaseContrast ? 0.7 : 0.12), lineWidth: 0.7))
            ForEach(model.groups) { group in primary(group) }
            if let group = model.group {
                ForEach(Array(group.actions.enumerated()), id: \.element.id) { index, action in option(action, index: index, group: group) }
            }
            VStack(spacing: 8 * scale) {
                NotchCap().fill(.black).frame(width: min(190, max(110, model.layout.notchRect?.width ?? 140)) * scale,
                                            height: 21 * scale)
                Image(systemName: model.count == 1 ? "doc.fill" : "doc.on.doc.fill")
                    .font(.system(size: 18 * scale, weight: .medium)).foregroundStyle(.secondary)
                Text(model.highlightedAction?.title ?? model.fileName)
                    .font(.system(size: 10 * scale, weight: .medium)).lineLimit(1).frame(width: 160 * scale)
                Text(model.payloadValid ? (model.highlightedAction == nil ? "Drop on an action" : "Release to run") : "Different files")
                    .font(.system(size: 9 * scale)).foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(model.fileName). Center cancels. \(model.highlightedAction?.title ?? "Choose a category and drop on an action.")")
        }
        .frame(width: width, height: height)
        .opacity(model.visible ? 1 : 0)
        .offset(y: model.visible || model.reduceMotion ? 0 : -7 * scale)
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.18), value: model.visible)
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.10), value: model.highlightedID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchOrbitPlus actions for \(model.fileName)")
    }

    private func primary(_ group: NotchGroup) -> some View {
        let geometry = model.layout.geometry
        let angle = NotchGeometry.sectorCenterAngle(index: group.slot, count: geometry.slotCount)
        let wedge = LowerArc(inner: geometry.primaryInnerRadius, outer: geometry.primaryOuterRadius,
                             centerAngle: angle, span: .pi / Double(geometry.slotCount) - geometry.angularGap)
        let selected = model.selectedSlot == group.slot
        return Button { model.activate(group) } label: {
            ZStack {
                wedge.fill(selected ? Color.accentColor.opacity(model.increaseContrast ? 0.35 : 0.16) : restingFill)
                wedge.stroke(.primary.opacity(model.increaseContrast ? 0.6 : 0.10), lineWidth: 0.65)
                VStack(spacing: 4 * scale) {
                    Image(systemName: group.symbol).font(.system(size: 15 * scale, weight: .medium))
                    Text(group.title).font(.system(size: 9 * scale, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .position(position(radius: 139 * scale, angle: angle))
            }.contentShape(wedge)
        }
        .buttonStyle(.plain).frame(width: width, height: height)
        .accessibilityLabel(group.title)
        .accessibilityHint(group.actions.count == 1 ? "Drop to \(group.actions[0].title)" : "Select a concrete action in the outer band, then drop")
    }

    private func option(_ action: ActionDescriptor, index: Int, group: NotchGroup) -> some View {
        let geometry = model.layout.geometry
        let angle = NotchGeometry.sectorCenterAngle(index: index, count: group.actions.count)
        let wedge = LowerArc(inner: geometry.optionInnerRadius, outer: geometry.optionOuterRadius,
                             centerAngle: angle, span: .pi / Double(group.actions.count) - geometry.angularGap)
        let selected = model.highlightedID == action.id
        return Button { model.highlight(action.id) } label: {
            ZStack {
                wedge.fill(selected ? Color.accentColor.opacity(model.increaseContrast ? 0.42 : 0.20) : restingFill)
                wedge.stroke(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(model.increaseContrast ? 0.6 : 0.10), lineWidth: selected ? 1 : 0.65)
                VStack(spacing: 5 * scale) {
                    Image(systemName: action.symbol).font(.system(size: 20 * scale, weight: .medium))
                    Text(action.title).font(.system(size: 10 * scale, weight: .medium))
                        .lineLimit(2).multilineTextAlignment(.center).frame(width: 92 * scale)
                }
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .position(position(radius: (selected ? 232 : 230) * scale, angle: angle))
            }.contentShape(wedge)
        }
        .buttonStyle(.plain).frame(width: width, height: height)
        .accessibilityLabel(action.title).accessibilityHint("Drop to run. \(action.detail)")
    }
    private var restingFill: Color {
        model.increaseContrast ? (colorScheme == .dark ? .black.opacity(0.94) : .white.opacity(0.96)) : .primary.opacity(0.025)
    }
    private func position(radius: Double, angle: Double) -> CGPoint {
        CGPoint(x: width / 2 - cos(angle) * radius, y: sin(angle) * radius)
    }
}
#endif
