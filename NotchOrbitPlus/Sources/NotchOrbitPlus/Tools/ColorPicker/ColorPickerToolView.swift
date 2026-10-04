import AppKit
import SwiftUI
import NotchCore

@MainActor
struct ColorPickerToolView: View {
    @ObservedObject private var store: ColorPickerStore
    @State private var paletteName = ""
    init(store: ColorPickerStore = .shared) { self.store = store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    swatch(store.selectedColor, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.selectedColor.hex).font(.title2.monospaced())
                        Text("Current color · sRGB").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: store.pick) {
                        Label(store.isPicking ? "Picking…" : "Pick Color", systemImage: "eyedropper")
                    }.disabled(store.isPicking)
                }
                Picker("Color format", selection: $store.format) {
                    ForEach(CoreColorFormat.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                HStack(alignment: .center, spacing: 8) {
                    ScrollView(.horizontal) {
                        Text(store.formattedColor).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                    }
                    Button("Copy") { store.copySelected() }.accessibilityLabel("Copy formatted color")
                }.padding(9).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text("Recent Picks").font(.headline)
                    Spacer()
                    if !store.history.isEmpty { Button("Clear", action: store.clearHistory).font(.caption) }
                }
                if store.history.isEmpty {
                    Text("Pick a color from your screen to start your local history.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            ForEach(store.history, id: \.self) { color in
                                Button { store.select(color) } label: { swatch(color, size: 28) }
                                    .buttonStyle(.plain).help(color.hex).accessibilityLabel("Select \(color.hex)")
                            }
                        }.padding(.vertical, 2)
                    }
                }
                Divider()
                HStack {
                    Text("Saved Palettes").font(.headline)
                    Spacer()
                    Menu {
                        Button("Import Palettes…", action: store.importPalettes)
                        Button("Export Palettes…", action: store.exportPalettes).disabled(store.palettes.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton)
                        .fixedSize().accessibilityLabel("Palette file actions")
                }
                HStack {
                    TextField("New palette name", text: $paletteName).textFieldStyle(.roundedBorder)
                        .onSubmit(createPalette)
                    Button("Create", action: createPalette)
                        .disabled(paletteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if store.palettes.isEmpty {
                    Text("Create a palette, then save the current color to it.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Picker("Palette", selection: $store.selectedPaletteID) {
                            ForEach(store.palettes) { Text($0.name).tag(Optional($0.id)) }
                        }.labelsHidden()
                        Button("Add Color", action: store.addCurrentToPalette)
                            .disabled(store.selectedPalette == nil || (store.selectedPalette?.colors.count ?? 0) >= CoreColorPalette.maximumColors)
                        Menu {
                            Button("Rename to Entered Name") { store.renameSelectedPalette(paletteName) }
                                .disabled(paletteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Delete Palette", role: .destructive, action: store.deleteSelectedPalette)
                        } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel("Manage selected palette")
                    }
                    if let palette = store.selectedPalette {
                        if palette.colors.isEmpty {
                            Text("This palette has no colors yet.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 50))], alignment: .leading, spacing: 8) {
                                ForEach(palette.colors.indices, id: \.self) { index in
                                    let color = palette.colors[index]
                                    Button { store.select(color) } label: {
                                        VStack(spacing: 4) {
                                            swatch(color, size: 28)
                                            Text(color.hex).font(.system(size: 8, design: .monospaced)).lineLimit(1)
                                        }
                                    }.buttonStyle(.plain).help(color.hex).accessibilityLabel("Select palette color \(color.hex)")
                                        .contextMenu { Button("Remove Color", role: .destructive) { store.removeColor(at: index, from: palette) } }
                                }
                            }
                        }
                    }
                }
                LocalToolError(message: store.error)
                Text("History stays on this Mac. Saved palettes can be exported or synced.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(16)
        }.background(CaptureToolVisibility(onVisible: {}, onHidden: { store.shutdown() })
            .frame(width: 0, height: 0)).onDisappear { store.shutdown() }
    }
    private func createPalette() {
        store.createPalette(name: paletteName)
        if store.error == nil { paletteName = "" }
    }
    private func swatch(_ color: CoreColorRGBA, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color(nsColor: color.nsColor))
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.secondary.opacity(0.35)))
            .frame(width: size, height: size)
    }
}
