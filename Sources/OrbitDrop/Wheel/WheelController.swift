#if os(macOS)
import AppKit
import OrbitCore
import SwiftUI

/// A nonactivating, public-API-only window that participates in a real Finder drag.
@MainActor
public final class OrbitWheelPanel: NSPanel {
    fileprivate var keyHandler: ((NSEvent) -> Void)?
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public override func keyDown(with event: NSEvent) { keyHandler?(event) }
}

@MainActor
public final class WheelController {
    private var panel: OrbitWheelPanel?
    private var destination: WheelDropView?
    private var model: WheelModel?
    private var onSelect: (@MainActor (ActionDescriptor, [URL]) -> Void)?
    private var onCancel: (@MainActor () -> Void)?

    public init() {}

    public func show(items: [FileItem], actions: [ActionDescriptor], at position: NSPoint,
                     preferredCategory: String? = nil,
                     onSelect: @escaping @MainActor (ActionDescriptor, [URL]) -> Void,
                     onCancel: @escaping @MainActor () -> Void) {
        dismiss()
        guard !items.isEmpty, !actions.isEmpty else { onCancel(); return }
        self.onSelect = onSelect
        self.onCancel = onCancel

        let screen = NSScreen.screens.first { $0.frame.contains(position) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: position.x - 216, y: position.y - 216, width: 432, height: 432)
        let side = min(432, min(visible.width, visible.height) - 24)
        let frame = RadialGeometry.clampedFrame(
            center: RadialPoint(x: position.x, y: position.y),
            size: RadialSize(width: max(120, side), height: max(120, side)),
            visibleFrame: RadialRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height))
        let window = OrbitWheelPanel(contentRect: NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        window.setAccessibilityLabel("OrbitDrop file actions")

        let state = WheelModel(items: items, actions: actions, side: frame.width)
        if let preferredCategory, let group = state.groups.first(where: { $0.name.caseInsensitiveCompare(preferredCategory) == .orderedSame }) {
            state.activate(group)
        }
        let view = WheelDropView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height), model: state,
                                 expectedURLs: items.map(\.url))
        view.onDrop = { [weak self] action, urls in self?.complete(action: action, urls: urls) }
        view.onCancel = { [weak self] in self?.cancel() }
        let hosting = NSHostingView(rootView: RadialWheelView(model: state))
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        view.addSubview(hosting)
        window.contentView = view
        window.keyHandler = { [weak self, weak state] event in
            if event.keyCode == 53 { self?.cancel() } else { state?.navigate(event) }
        }
        self.model = state
        self.destination = view
        self.panel = window
        window.orderFrontRegardless()
        state.visible = true
    }

    /// Dismissal itself never executes an action or changes the source files.
    public func dismiss() {
        model?.stopObservingAccessibility()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        destination = nil
        model = nil
        onSelect = nil
        onCancel = nil
    }

    private func complete(action: ActionDescriptor, urls: [URL]) {
        let callback = onSelect
        dismiss()
        callback?(action, urls)
    }

    private func cancel() {
        let callback = onCancel
        dismiss()
        callback?()
    }
}

@MainActor
private final class WheelDropView: NSView {
    let model: WheelModel
    private let expectedURLs: [URL]
    private var tracking: NSTrackingArea?
    private var completed = false
    var onDrop: ((ActionDescriptor, [URL]) -> Void)?
    var onCancel: (() -> Void)?
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, model: WheelModel, expectedURLs: [URL]) {
        self.model = model
        self.expectedURLs = expectedURLs
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel("OrbitDrop action wheel")
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:model:expectedURLs:)") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        model.updatePointer(relativePoint(convert(event.locationInWindow, from: nil)))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { model.clearSelection() }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        validatedURLs(from: sender.draggingPasteboard) != nil && action(for: sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // A preview/monitor pasteboard is never authority to run a transformation.
        guard let urls = validatedURLs(from: sender.draggingPasteboard),
              let selected = action(for: sender) else {
            onCancel?()
            return false
        }
        completed = true
        onDrop?(selected, urls)
        return true
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        if !completed { onCancel?() }
    }

    private func updateDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard validatedURLs(from: sender.draggingPasteboard) != nil else {
            model.clearSelection()
            model.payloadValid = false
            return []
        }
        model.payloadValid = true
        model.updatePointer(relativePoint(convert(sender.draggingLocation, from: nil)))
        return action(for: sender) == nil ? [] : .copy
    }

    private func action(for sender: any NSDraggingInfo) -> ActionDescriptor? {
        model.action(at: relativePoint(convert(sender.draggingLocation, from: nil)))
    }

    private func relativePoint(_ point: NSPoint) -> RadialPoint {
        RadialPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
    }

    private func validatedURLs(from pasteboard: NSPasteboard) -> [URL]? {
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              !objects.isEmpty else { return nil }
        let urls = objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
        guard urls.count == objects.count else { return nil }
        return DropPayloadValidator.matchingDroppedURLs(urls, expected: expectedURLs)
    }
}

private struct WheelGroup: Identifiable {
    var id: Int { slot }
    let slot: Int
    let name: String
    let symbol: String
    let actions: [ActionDescriptor]
}

@MainActor
private final class WheelModel: ObservableObject {
    @Published var activeSlot: Int?
    @Published var highlightedID: ActionID?
    @Published var visible = false
    @Published var payloadValid = true
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    let groups: [WheelGroup]
    let fileCount: Int
    let fileName: String
    let summary: String?
    let side: Double
    let geometry: RadialGeometry
    private var keyboardIndex = 0
    private var accessibilityObserver: NSObjectProtocol?

    init(items: [FileItem], actions: [ActionDescriptor], side: Double) {
        self.side = side
        fileCount = items.count
        fileName = items.count == 1 ? items[0].url.lastPathComponent : "\(items.count) files"
        let images = items.filter { $0.kind == .image }
        if images.count == 1 { summary = images[0].privacySummary }
        else if !images.isEmpty {
            let counted = Dictionary(grouping: images, by: { $0.privacySummary ?? "Metadata uninspected" })
            summary = counted.keys.sorted().map { "\(counted[$0]?.count ?? 0)× \($0)" }.joined(separator: "\n")
        } else { summary = nil }
        let scale = side / 432
        geometry = RadialGeometry(primaryInnerRadius: 62 * scale, primaryOuterRadius: 113 * scale,
                                  optionInnerRadius: 123 * scale, optionOuterRadius: 187 * scale)
        // Missing categories leave their slot empty; other categories never shift around.
        let categorySlots = ["convert": 0, "resize": 1, "compress": 2, "media": 3, "audio": 3,
                             "privacy": 4, "pdf": 5, "tools": 6, "text": 6, "files": 7]
        let symbols = ["convert": "arrow.triangle.2.circlepath", "resize": "arrow.up.left.and.arrow.down.right",
                       "compress": "arrow.down.right.and.arrow.up.left", "media": "play.rectangle",
                       "privacy": "hand.raised", "pdf": "doc.richtext", "tools": "wrench.and.screwdriver",
                       "text": "curlybraces", "audio": "waveform", "files": "folder"]
        var byCategory: [String: [ActionDescriptor]] = [:]
        for action in actions { byCategory[action.category.lowercased(), default: []].append(action) }
        var used = Set(byCategory.keys.compactMap { categorySlots[$0] })
        var built: [WheelGroup] = []
        for category in byCategory.keys.sorted() {
            guard let descriptors = byCategory[category], let first = descriptors.first else { continue }
            let slot: Int
            if let fixed = categorySlots[category] { slot = fixed }
            else if let free = (0..<8).first(where: { !used.contains($0) }) { slot = free; used.insert(free) }
            else { slot = 6 }
            if let existingIndex = built.firstIndex(where: { $0.slot == slot }) {
                let existing = built[existingIndex]
                let mergedName = slot == 3 ? "Media" : "Tools"
                built[existingIndex] = WheelGroup(slot: slot, name: mergedName, symbol: existing.symbol,
                                                actions: existing.actions + descriptors)
            } else {
                built.append(WheelGroup(slot: slot, name: first.category, symbol: symbols[category] ?? first.symbol, actions: descriptors))
            }
        }
        groups = built.sorted { $0.slot < $1.slot }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    self?.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                }
            }
    }

    func stopObservingAccessibility() {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        accessibilityObserver = nil
    }

    var activeGroup: WheelGroup? { groups.first { $0.slot == activeSlot } }
    var highlightedAction: ActionDescriptor? { activeGroup?.actions.first { $0.id == highlightedID } }
    var scale: Double { side / 432 }

    func activate(_ group: WheelGroup) {
        if activeSlot != group.slot {
            activeSlot = group.slot
            keyboardIndex = 0
        }
        setHighlight(group.actions.count == 1 ? group.actions.first?.id : nil)
    }

    func clearSelection() { setHighlight(nil) }

    func updatePointer(_ point: RadialPoint) {
        if let slot = geometry.primarySlot(at: point) {
            if let group = groups.first(where: { $0.slot == slot }) { activate(group) }
            else {
                if activeSlot != nil { activeSlot = nil }
                setHighlight(nil)
            }
        } else {
            setHighlight(action(at: point)?.id)
        }
    }

    func action(at point: RadialPoint) -> ActionDescriptor? {
        guard payloadValid else { return nil }
        if let slot = geometry.primarySlot(at: point), let group = groups.first(where: { $0.slot == slot }) {
            return group.actions.count == 1 ? group.actions.first : nil
        }
        guard let group = activeGroup,
              let index = geometry.optionIndex(at: point, count: group.actions.count, anchorSlot: group.slot) else { return nil }
        return group.actions[index]
    }

    func navigate(_ event: NSEvent) {
        if let characters = event.charactersIgnoringModifiers, let number = Int(characters), (1...8).contains(number),
           let group = groups.first(where: { $0.slot == number - 1 }) { activate(group); return }
        switch event.keyCode {
        case 123, 126: moveSelection(delta: -1)
        case 124, 125: moveSelection(delta: 1)
        case 36, 76:
            if let group = activeGroup { setHighlight(group.actions.first?.id) }
        default: break
        }
    }

    private func moveSelection(delta: Int) {
        if let group = activeGroup, !group.actions.isEmpty {
            keyboardIndex = (keyboardIndex + delta + group.actions.count) % group.actions.count
            setHighlight(group.actions[keyboardIndex].id)
        } else if let first = groups.first { activate(first) }
    }

    func setHighlight(_ id: ActionID?) {
        guard highlightedID != id else { return }
        highlightedID = id
        if id != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }
}

@MainActor
private struct WheelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct RingWedge: Shape {
    let inner: Double
    let outer: Double
    let centerAngle: Double
    let span: Double
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = centerAngle - span / 2
        let steps = max(20, Int(span * 36))
        func point(_ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius)
        }
        var path = Path()
        path.move(to: point(inner, start))
        for index in 0...steps { path.addLine(to: point(outer, start + span * Double(index) / Double(steps))) }
        for index in (0...steps).reversed() { path.addLine(to: point(inner, start + span * Double(index) / Double(steps))) }
        path.closeSubpath()
        return path
    }
}

@MainActor
private struct RadialWheelView: View {
    @ObservedObject var model: WheelModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            WheelMaterial().clipShape(Circle())
                .frame(width: 394 * model.scale, height: 394 * model.scale)
                .overlay(Circle().strokeBorder(.white.opacity(model.increaseContrast ? 0.7 : 0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 16, y: 4)
            ForEach(model.groups) { group in primary(group) }
            if let group = model.activeGroup {
                ForEach(Array(group.actions.enumerated()), id: \.element.id) { index, action in option(action, index: index, group: group) }
            }
            center
        }
        .frame(width: model.side, height: model.side)
        .scaleEffect(model.visible || model.reduceMotion ? 1 : 0.82)
        .opacity(model.visible ? 1 : 0)
        .animation(model.reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.85), value: model.visible)
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.10), value: model.activeSlot)
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.10), value: model.highlightedID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions for \(model.fileName)")
    }

    private func primary(_ group: WheelGroup) -> some View {
        let angle = RadialGeometry.sectorCenterAngle(index: group.slot, count: 8)
        let wedge = RingWedge(inner: model.geometry.primaryInnerRadius, outer: model.geometry.primaryOuterRadius,
                              centerAngle: angle, span: .pi / 4 - 0.045)
        let selected = model.activeSlot == group.slot
        return Button { model.activate(group) } label: {
            ZStack {
                wedge.fill(selected ? Color.accentColor.opacity(model.increaseContrast ? 0.36 : 0.22) : restingFill)
                wedge.strokeBorderCompat(selected ? .accentColor.opacity(0.7) : .primary.opacity(model.increaseContrast ? 0.5 : 0.10), lineWidth: 1)
                VStack(spacing: 3 * model.scale) {
                    Image(systemName: group.symbol).font(.system(size: 16 * model.scale, weight: .medium))
                    Text(group.name).font(.system(size: 10 * model.scale, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .position(labelPosition(radius: (selected ? 90 : 88) * model.scale, angle: angle))
            }.contentShape(wedge)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.name)
        .accessibilityValue(selected ? "Selected category" : "")
        .accessibilityHint(group.actions.count == 1 ? "Drop to \(group.actions[0].title)" : "Choose a format in the outer ring, then drop")
    }

    private func option(_ action: ActionDescriptor, index: Int, group: WheelGroup) -> some View {
        let anchor = RadialGeometry.sectorCenterAngle(index: group.slot, count: 8)
        let angle = RadialGeometry.sectorCenterAngle(index: index, count: group.actions.count, anchorAngle: anchor)
        let wedge = RingWedge(inner: model.geometry.optionInnerRadius, outer: model.geometry.optionOuterRadius,
                              centerAngle: angle, span: 2 * .pi / Double(group.actions.count) - 0.035)
        let selected = model.highlightedID == action.id
        return Button { model.setHighlight(action.id) } label: {
            ZStack {
                wedge.fill(selected ? Color.accentColor.opacity(model.increaseContrast ? 0.45 : 0.26) : restingFill)
                wedge.strokeBorderCompat(selected ? .accentColor : .primary.opacity(model.increaseContrast ? 0.5 : 0.12), lineWidth: selected ? 1.5 : 1)
                VStack(spacing: 4 * model.scale) {
                    Image(systemName: action.symbol).font(.system(size: 18 * model.scale, weight: .medium))
                    Text(action.title).font(.system(size: 10 * model.scale, weight: .semibold))
                        .multilineTextAlignment(.center).lineLimit(2).frame(width: 84 * model.scale)
                }
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .position(labelPosition(radius: (selected ? 156 : 154) * model.scale, angle: angle))
            }.contentShape(wedge)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
        .accessibilityValue(selected ? "Selected drop target" : "")
        .accessibilityHint("Drop the \(model.fileCount == 1 ? "file" : "files") here to run this action. \(action.detail)")
    }

    private var center: some View {
        ZStack {
            Circle().fill(colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.7))
            Circle().trim(from: 0.05, to: 0.68).stroke(.blue.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-95)).padding(7 * model.scale)
            VStack(spacing: 4 * model.scale) {
                Image(systemName: model.fileCount > 1 ? "doc.on.doc.fill" : "doc.fill")
                    .font(.system(size: 21 * model.scale, weight: .medium)).foregroundStyle(.blue)
                Text(model.highlightedAction?.title ?? model.fileName)
                    .font(.system(size: 9 * model.scale, weight: .semibold))
                    .multilineTextAlignment(.center).lineLimit(2).frame(width: 78 * model.scale)
                if model.activeGroup?.name.lowercased() == "privacy", let summary = model.summary {
                    Text(summary).font(.system(size: 8 * model.scale))
                        .multilineTextAlignment(.center).lineLimit(2).frame(width: 82 * model.scale)
                }
                Text(model.payloadValid ? (model.highlightedAction == nil ? "Drop on an action" : "Release to run") : "Different drag")
                    .font(.system(size: 8 * model.scale)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 105 * model.scale, height: 105 * model.scale)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.fileName). \(model.activeGroup?.name.lowercased() == "privacy" ? (model.summary ?? "") : "") Drop in the center or outside the wheel to cancel.")
        .allowsHitTesting(false)
    }

    private var restingFill: Color {
        model.increaseContrast ? (colorScheme == .dark ? .black.opacity(0.9) : .white.opacity(0.95)) : .primary.opacity(0.045)
    }

    private func labelPosition(radius: Double, angle: Double) -> CGPoint {
        CGPoint(x: model.side / 2 + sin(angle) * radius, y: model.side / 2 - cos(angle) * radius)
    }
}

private extension Shape {
    func strokeBorderCompat(_ color: Color, lineWidth: CGFloat) -> some View { stroke(color, lineWidth: lineWidth) }
}
#endif
