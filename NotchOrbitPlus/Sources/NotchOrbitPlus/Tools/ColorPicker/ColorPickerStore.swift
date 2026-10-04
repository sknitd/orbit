import AppKit
import Combine
import Foundation
import NotchCore

extension CoreColorRGBA {
    static func fromNSColor(_ color: NSColor) throws -> Self {
        guard let rgb = color.usingColorSpace(.sRGB) else { throw CoreColorPaletteError.invalidComponent }
        return try Self(red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                        blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
    }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

@MainActor
final class ColorPickerStore: ObservableObject {
    static let shared = ColorPickerStore()
    static let defaultColor = try! CoreColorRGBA(red: 0, green: 0.478431, blue: 1)
    typealias Sampling = @MainActor (@escaping @Sendable (CoreColorRGBA?) -> Void) -> Void
    @Published private(set) var state: CoreColorPickerState
    @Published private(set) var selectedColor: CoreColorRGBA
    @Published private(set) var isPicking = false
    @Published private(set) var error: String?
    @Published var format: CoreColorFormat = .hex
    @Published var selectedPaletteID: UUID?
    private let saveState: @MainActor (CoreColorPickerState) throws -> Void
    private let persistsState: Bool
    private let sampling: Sampling?
    private var sampler: NSColorSampler?
    private var pickGeneration = UUID()
    var history: [CoreColorRGBA] { state.history }
    var palettes: [CoreColorPalette] { state.library.palettes }
    var formattedColor: String { selectedColor.formatted(format) }
    var selectedPalette: CoreColorPalette? { palettes.first { $0.id == selectedPaletteID } }

    init(persistHistory: Bool = true, initialState: CoreColorPickerState? = nil,
         sampling: Sampling? = nil, save: (@MainActor (CoreColorPickerState) throws -> Void)? = nil) {
        let empty = try! CoreColorPickerState(library: CoreColorPaletteLibrary())
        var loaded = initialState ?? empty
        var loadError: String?
        if persistHistory && initialState == nil {
            do { loaded = try LocalToolStorage.load(CoreColorPickerState.self, file: "color-picker-v1.json", fallback: empty) }
            catch { loadError = error.localizedDescription }
        }
        state = loaded; selectedColor = loaded.history.first ?? Self.defaultColor
        selectedPaletteID = loaded.library.palettes.first?.id
        error = loadError; self.sampling = sampling; persistsState = persistHistory
        saveState = save ?? { value in
            if persistHistory { try LocalToolStorage.save(value, file: "color-picker-v1.json") }
        }
    }

    func start() { }
    /// Invalidate late sampler completions whenever the tool is hidden or the app stops.
    func shutdown() {
        pickGeneration = UUID(); isPicking = false; sampler = nil
    }
    func pick() {
        guard !isPicking else { return }
        let generation = UUID(); pickGeneration = generation; isPicking = true; error = nil
        let completion: @Sendable (CoreColorRGBA?) -> Void = { [weak self] color in
            Task { @MainActor [weak self] in
                guard let self, self.pickGeneration == generation else { return }
                self.isPicking = false; self.sampler = nil
                guard let color else { return }
                do { try self.record(color) } catch { self.error = error.localizedDescription }
            }
        }
        if let sampling { sampling(completion) }
        else {
            let sampler = NSColorSampler(); self.sampler = sampler
            sampler.show { color in completion(color.flatMap { try? CoreColorRGBA.fromNSColor($0) }) }
        }
    }
    func select(_ color: CoreColorRGBA) { selectedColor = color }
    func record(_ color: CoreColorRGBA) throws {
        var history = state.history.filter { $0 != color }; history.insert(color, at: 0)
        try commit(history: Array(history.prefix(CoreColorPickerState.maximumHistory)), library: state.library)
        selectedColor = color
    }
    func clearHistory() { perform { try commit(history: [], library: state.library) } }
    func createPalette(name: String) {
        perform {
            let palette = try CoreColorPalette(name: name)
            let library = try CoreColorPaletteLibrary(palettes: palettes + [palette])
            try commit(history: history, library: library); selectedPaletteID = palette.id
            PlusSyncService.shared.portableDidChange()
        }
    }
    func addCurrentToPalette() {
        guard let palette = selectedPalette else { return }
        guard !palette.colors.contains(selectedColor) else { return }
        perform {
            let updated = try CoreColorPalette(id: palette.id, name: palette.name, colors: palette.colors + [selectedColor])
            try replace(updated)
        }
    }
    func removeColor(at index: Int, from palette: CoreColorPalette) {
        guard let actual = palettes.first(where: { $0.id == palette.id }), actual.colors.indices.contains(index) else { return }
        perform {
            var colors = actual.colors; colors.remove(at: index)
            try replace(CoreColorPalette(id: actual.id, name: actual.name, colors: colors))
        }
    }
    func deleteSelectedPalette() {
        guard let id = selectedPaletteID else { return }
        perform {
            let library = try CoreColorPaletteLibrary(palettes: palettes.filter { $0.id != id })
            try commit(history: history, library: library); selectedPaletteID = library.palettes.first?.id
            PlusSyncService.shared.portableDidChange()
        }
    }
    func renameSelectedPalette(_ name: String) {
        guard let palette = selectedPalette else { return }
        perform { try replace(CoreColorPalette(id: palette.id, name: name, colors: palette.colors)) }
    }
    func copySelected(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        if pasteboard.setString(formattedColor, forType: .string) { error = nil }
        else { error = "macOS could not copy this color." }
    }
    /// Stable sync contract: export saved palettes only, retaining local history on import.
    func exportData() throws -> Data {
        try validateLocalPersistedState()
        return try state.library.encoded()
    }
    func validateSyncImport(_ data: Data) throws {
        _ = try CoreColorPaletteLibrary.decode(data)
        try validateLocalPersistedState()
    }
    func applySyncedData(_ data: Data) throws {
        let library = try CoreColorPaletteLibrary.decode(data)
        try validateLocalPersistedState()
        try commit(history: history, library: library)
        if !library.palettes.contains(where: { $0.id == selectedPaletteID }) { selectedPaletteID = library.palettes.first?.id }
    }
    func exportPalettes() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Orbit-Color-Palettes.json"
        panel.title = "Export Color Palettes"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try exportData().write(to: url, options: .atomic) }
    }
    func importPalettes() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Import Color Palettes"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= CoreColorPaletteLibrary.maximumBytes else { throw CoreColorPaletteError.tooLarge }
            try applySyncedData(Data(contentsOf: url))
            PlusSyncService.shared.portableDidChange()
        }
    }
    private func replace(_ palette: CoreColorPalette) throws {
        try commit(history: history, library: CoreColorPaletteLibrary(palettes: palettes.map { $0.id == palette.id ? palette : $0 }))
        PlusSyncService.shared.portableDidChange()
    }
    private func validateLocalPersistedState() throws {
        guard persistsState else { return }
        let url = try LocalToolStorage.directory().appendingPathComponent("color-picker-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        guard (metadata.fileSize ?? 0) <= CoreColorPaletteLibrary.maximumBytes else { throw CoreColorPaletteError.tooLarge }
        _ = try JSONDecoder().decode(CoreColorPickerState.self, from: Data(contentsOf: url))
    }
    private func commit(history: [CoreColorRGBA], library: CoreColorPaletteLibrary) throws {
        let next = try CoreColorPickerState(history: history, library: library)
        try saveState(next)
        state = next; error = nil
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}
