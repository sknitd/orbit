import SwiftUI
import UniformTypeIdentifiers
import NotchCore

@MainActor
struct AssistantFilesToolView: View {
    @ObservedObject var store: AssistantFilesStore
    init(store: AssistantFilesStore = .shared) { self.store = store }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ask Orbit · Files", systemImage: "doc.text.magnifyingglass").font(.headline)
            Text(store.availability).font(.caption).foregroundStyle(.secondary)
            if store.available {
                Picker("File action", selection: Binding(get: { store.action }, set: { store.selectAction($0) })) {
                    ForEach(AssistantFileAction.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).disabled(store.isWorking)
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.title2)
                    Text(store.inputs.isEmpty ? "Drop text, PDFs or screenshots here" : store.inputs.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.caption).lineLimit(3)
                    Button("Choose Files…") { store.chooseFiles() }.disabled(store.isWorking)
                }.frame(maxWidth: .infinity).padding(14)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    .onDrop(of: [UTType.fileURL], isTargeted: nil) { store.receive($0) }
                HStack {
                    Button("Generate Preview") { store.generate() }.disabled(store.inputs.isEmpty || store.isWorking)
                    if store.isWorking { ProgressView().controlSize(.small); Button("Cancel") { store.cancel() } }
                    if !store.copies.isEmpty { Button("Undo Named Copies") { store.undoCopies() }.disabled(store.isWorking) }
                }
                ForEach(Array(store.proposals.enumerated()), id: \.element.id) { index, proposal in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(proposal.document.source.lastPathComponent).font(.caption.weight(.semibold))
                        if store.action.createsCopies {
                            TextField("New filename stem", text: Binding(get: {
                                store.proposals.indices.contains(index) ? store.proposals[index].response : ""
                            }, set: { value in
                                if store.proposals.indices.contains(index) { store.proposals[index].response = value }
                            })).textFieldStyle(.roundedBorder).disabled(store.isWorking)
                            Text("A new copy will keep its original extension. Name collisions receive a number.")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            ScrollView { Text(proposal.response).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxHeight: 180)
                            HStack {
                                Button("Copy") { store.copyPreview(proposal) }
                                if store.action == .extractCSV { Button("Export CSV…") { store.exportCSV(proposal) } }
                            }
                        }
                    }.padding(10).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                }
                if store.action.createsCopies && !store.proposals.isEmpty {
                    Button("Confirm Named Copies") { store.confirmNamedCopies() }.buttonStyle(.borderedProminent).disabled(store.isWorking)
                }
                Text("Text/PDF/Markdown actions use the first 8,000 readable characters. Screenshot naming uses local OCR. Model output is a proposal; verify it before confirming.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else { Button("Check On-Device Availability") { store.checkAvailability() } }
            Text(store.status).font(.caption).foregroundStyle(.secondary)
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.background(CaptureToolVisibility(onVisible: { store.checkAvailability() }, onHidden: { store.cancel() }).frame(width: 0, height: 0))
    }
}
