import AppKit
import SwiftUI
import NotchCore

@MainActor
struct QRToolView: View {
    @ObservedObject private var store: QRToolStore
    init(store: QRToolStore = .shared) { self.store = store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("QR Generator & Scanner", systemImage: "qrcode").font(.headline)
                Text("Encode text or a URL as a PNG. Scan local images or an explicitly selected screen region.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $store.payload).font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 90).padding(4)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("QR payload to encode")
                HStack {
                    Picker("Correction", selection: $store.correction) {
                        ForEach(QRCorrectionLevel.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Scale", selection: $store.scale) {
                        ForEach([4, 8, 12, 16], id: \.self) { Text("\($0)×").tag($0) }
                    }.frame(width: 110)
                    Button("Generate PNG", action: store.generate)
                        .disabled(store.isWorking || store.payload.isEmpty)
                }
                if let image = store.preview, let url = store.generatedPNG {
                    HStack(spacing: 14) {
                        Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 148, height: 148).background(.white)
                            .onDrag { NSItemProvider(object: url as NSURL) }
                            .accessibilityLabel("Generated QR PNG. Drag to export.")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.generatedSize).font(.caption.monospaced())
                            Text("Drag the preview to share the actual PNG.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Export…", action: store.exportPNG)
                                Button("Reveal", action: store.revealPNG)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Button(action: store.selectPNG) { Label("Scan PNG…", systemImage: "photo") }
                    Button(action: store.scanScreenRegion) { Label("Scan Screen Region", systemImage: "viewfinder") }
                }.disabled(store.isWorking)
                if store.isWorking {
                    HStack { ProgressView().controlSize(.small); Text(store.status).font(.caption); Spacer(); Button("Cancel", action: store.cancel) }
                } else { Text(store.status).font(.caption).foregroundStyle(.secondary) }
                ForEach(store.decodedPayloads.indices, id: \.self) { index in
                    HStack(alignment: .top) {
                        Text(store.decodedPayloads[index]).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Copy") { store.copyPayload(at: index) }
                            .accessibilityLabel("Copy QR payload \(index + 1)")
                    }.padding(9).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
                LocalToolError(message: store.error)
                Text("Screen Recording permission is requested only by Scan Screen Region. Captures are kept in File Shelf. Decoded links are shown as text; use Copy to share them.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(16)
        }.background(CaptureToolVisibility(onVisible: {}, onHidden: { store.shutdown() })
            .frame(width: 0, height: 0)).onDisappear { store.shutdown() }
    }
}
